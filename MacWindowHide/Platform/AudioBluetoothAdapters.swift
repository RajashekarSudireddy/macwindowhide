import AppKit
import CoreAudio
import CoreBluetooth
import Foundation
import IOBluetooth

struct PairedHeadphone: Identifiable, Equatable, Sendable {
    let address: String
    let name: String
    let connected: Bool
    let battery: [String: Int]
    var id: String { address }
    var batteryDescription: String { battery.isEmpty ? "Battery unavailable" : battery.keys.sorted().map { "\($0) \(battery[$0]!)%" }.joined(separator: " · ") }
}

private enum AudioHardware {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func devices() -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var values = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }
    static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector), value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func uint(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func defaultOutputUID() -> String? {
        guard let device = uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
    static func setDefaultOutput(uid: String) throws {
        guard let device = devices().first(where: { string($0, kAudioDevicePropertyDeviceUID) == uid && channelCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 }) else { throw SwitchError.failed("The selected audio output is not available.") }
        var property = address(kAudioHardwarePropertyDefaultOutputDevice), value = device
        let code = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        guard code == noErr else { throw SwitchError.failed("macOS refused the audio output change (\(code)).") }
        guard defaultOutputUID() == uid else { throw SwitchError.failed("macOS did not switch to the selected audio output.") }
    }
}

@MainActor final class BluetoothAudioController {
    static let shared = BluetoothAudioController()
    private var central: CBCentralManager?
    var permission: SwitchCapability {
        switch CBManager.authorization {
        case .allowedAlways: .available
        case .denied, .restricted: .needsPermission("Allow Bluetooth in Privacy & Security → Bluetooth.")
        case .notDetermined: .needsPermission("Allow Bluetooth to list and connect paired headphones.")
        @unknown default: .unsupported("Bluetooth authorization is unavailable.")
        }
    }
    func requestPermission() { if central == nil { central = CBCentralManager(delegate: nil, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) } }
    /// Called by the device picker after the user requests Bluetooth access, never during initial UI setup.
    func pairedHeadphones() -> [PairedHeadphone] {
        guard permission.isAvailable else { return [] }
        return pairedDevices().filter { $0.deviceClassMajor == 4 || ($0.name ?? "").localizedCaseInsensitiveContains("AirPods") || ($0.name ?? "").localizedCaseInsensitiveContains("Beats") }.map { device in
            let raw = MWHBluetoothBattery(device)
            return PairedHeadphone(address: device.addressString ?? "", name: device.name ?? device.addressString ?? "Headphones", connected: device.isConnected(), battery: raw.mapValues(\.intValue))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    fileprivate func pairedDevices() -> [IOBluetoothDevice] { IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] }
    fileprivate func device(address: String) -> IOBluetoothDevice? { pairedDevices().first { Self.normalized($0.addressString ?? "") == Self.normalized(address) } }
    fileprivate static func normalized(_ value: String) -> String { value.lowercased().filter(\.isHexDigit) }
    fileprivate func outputUID(for device: IOBluetoothDevice) -> String? {
        let expected = Self.normalized(device.addressString ?? "")
        guard !expected.isEmpty else { return nil }
        return AudioHardware.devices().first { id in
            guard AudioHardware.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0, let uid = AudioHardware.string(id, kAudioDevicePropertyDeviceUID) else { return false }
            return Self.normalized(uid).contains(expected)
        }.flatMap { AudioHardware.string($0, kAudioDevicePropertyDeviceUID) }
    }
    fileprivate func connection(address: String, open: Bool) async -> IOReturn {
        await Task.detached(priority: .userInitiated) {
            guard let device = IOBluetoothDevice(addressString: address) else { return IOReturn(kIOReturnNotFound) }
            return open ? device.openConnection(nil, withPageTimeout: 0x1000, authenticationRequired: false) : device.closeConnection()
        }.value
    }
}

@MainActor final class AirPodsAdapter: SystemSwitchAdapter {
    let id: SwitchID = .airPods
    private let settings: SettingsStore
    private var priorOutputUID: String?
    private var connectedByApp: String?
    init(settings: SettingsStore) { self.settings = settings }
    private var controller: BluetoothAudioController { .shared }
    private func selected() throws -> IOBluetoothDevice {
        guard !settings.preferences.preferredAirPodsAddress.isEmpty else { throw SwitchError.unavailable("Choose paired headphones in Settings → AirPods.") }
        guard let device = controller.device(address: settings.preferences.preferredAirPodsAddress) else { throw SwitchError.unavailable("The preferred headphones are no longer paired.") }
        return device
    }
    func capability() async -> SwitchCapability {
        guard controller.permission.isAvailable else { return controller.permission }
        guard !settings.preferences.preferredAirPodsAddress.isEmpty else { return .needsPermission("Choose paired headphones in Settings → AirPods.") }
        return .available
    }
    func status() async -> SwitchStatus {
        guard await capability().isAvailable else { return SwitchStatus(state: .needsPermission, detail: (await capability()).reason ?? "Choose headphones.") }
        do {
            let device = try selected()
            let battery = MWHBluetoothBattery(device).map { "\($0.key) \($0.value)%" }.sorted().joined(separator: " · ")
            let output = controller.outputUID(for: device)
            let routed = output != nil && output == AudioHardware.defaultOutputUID()
            return SwitchStatus(state: device.isConnected() ? (routed ? .on : .partial) : .off, detail: battery.isEmpty ? (device.isConnected() ? "Connected · battery unavailable" : "\(device.name ?? "Headphones") disconnected") : battery)
        } catch { return SwitchStatus(state: .unsupported, detail: error.localizedDescription) }
    }
    func snapshot() async throws -> ResourceSnapshot {
        let device = try selected()
        return ResourceSnapshot(["address": device.addressString ?? "", "connected": String(device.isConnected()), "outputUID": AudioHardware.defaultOutputUID() ?? ""])
    }
    func apply(enabled: Bool, context: ActionContext) async throws {
        guard controller.permission.isAvailable else { throw SwitchError.unavailable(controller.permission.reason ?? "Bluetooth permission is required.") }
        let device = try selected()
        if enabled {
            if priorOutputUID == nil { priorOutputUID = AudioHardware.defaultOutputUID() }
            if !device.isConnected() {
                let code = await controller.connection(address: device.addressString ?? "", open: true)
                guard code == kIOReturnSuccess else { throw SwitchError.failed("The headphones could not connect (\(code)). Make sure they are awake.") }
                connectedByApp = device.addressString
            }
            for _ in 0..<20 {
                if let uid = controller.outputUID(for: device) { try AudioHardware.setDefaultOutput(uid: uid); return }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw SwitchError.failed("Bluetooth connected, but its audio output did not become available.")
        } else {
            if let uid = controller.outputUID(for: device), uid == AudioHardware.defaultOutputUID(), let priorOutputUID { try AudioHardware.setDefaultOutput(uid: priorOutputUID) }
            let code = await controller.connection(address: device.addressString ?? "", open: false)
            guard code == kIOReturnSuccess else { throw SwitchError.failed("The headphones could not disconnect (\(code)).") }
            connectedByApp = nil; priorOutputUID = nil
        }
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {
        guard let address = snapshot.values["address"], let device = controller.device(address: address) else { throw SwitchError.failed("The original headphones are no longer paired.") }
        if let output = snapshot.values["outputUID"], !output.isEmpty { try AudioHardware.setDefaultOutput(uid: output) }
        if snapshot.values["connected"] == "false", device.isConnected() {
            guard await controller.connection(address: address, open: false) == kIOReturnSuccess else { throw SwitchError.failed("The original Bluetooth state could not be restored.") }
        }
        connectedByApp = nil; priorOutputUID = nil
    }
}

private struct MicrophoneControl: Codable, Equatable {
    let channel: UInt32
    let mute: Bool
    let value: Float32
}
private struct MicrophoneRecord: Codable, Equatable {
    let uid: String
    let name: String
    var controls: [MicrophoneControl]
}

@MainActor final class MicrophoneAdapter: SystemSwitchAdapter {
    let id: SwitchID = .microphone
    private var original: [MicrophoneRecord]?
    private func controls(_ device: AudioDeviceID) -> [MicrophoneControl] {
        let channels = AudioHardware.channelCount(device, scope: kAudioObjectPropertyScopeInput)
        guard channels > 0 else { return [] }
        for mute in [true, false] {
            let selector = mute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar
            let main = AudioHardware.address(selector, scope: kAudioObjectPropertyScopeInput)
            if let value = read(device, property: main, mute: mute), settable(device, main) { return [MicrophoneControl(channel: 0, mute: mute, value: value)] }
            var values: [MicrophoneControl] = []
            for channel in 1...channels {
                let property = AudioHardware.address(selector, scope: kAudioObjectPropertyScopeInput, element: UInt32(channel))
                if let value = read(device, property: property, mute: mute), settable(device, property) { values.append(MicrophoneControl(channel: UInt32(channel), mute: mute, value: value)) }
            }
            if values.count == channels { return values }
        }
        return []
    }
    private func settable(_ device: AudioDeviceID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property, result: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &property, &result) == noErr && result.boolValue
    }
    private func read(_ device: AudioDeviceID, property: AudioObjectPropertyAddress, mute: Bool) -> Float32? {
        var property = property, size: UInt32 = 4
        if mute {
            var value: UInt32 = 0
            return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr ? Float32(value) : nil
        }
        var value: Float32 = 0
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr ? value : nil
    }
    private func records() -> [MicrophoneRecord] {
        AudioHardware.devices().filter { AudioHardware.channelCount($0, scope: kAudioObjectPropertyScopeInput) > 0 }.compactMap { device in
            guard let uid = AudioHardware.string(device, kAudioDevicePropertyDeviceUID) else { return nil }
            return MicrophoneRecord(uid: uid, name: AudioHardware.string(device, kAudioObjectPropertyName) ?? "Microphone", controls: controls(device))
        }.sorted { $0.uid < $1.uid }
    }
    private func muted(_ control: MicrophoneControl) -> Bool { control.mute ? control.value != 0 : control.value == 0 }
    func capability() async -> SwitchCapability { records().contains { !$0.controls.isEmpty } ? .available : .unsupported("No microphone exposes a writable hardware mute or input volume control.") }
    func status() async -> SwitchStatus {
        let devices = records(), controls = devices.flatMap(\.controls)
        guard !controls.isEmpty else { return SwitchStatus(state: .unsupported, detail: "Microphones do not expose writable hardware mute controls.") }
        let mutedCount = controls.filter(muted).count
        let unsupported = devices.filter { $0.controls.isEmpty }.map(\.name)
        let state: SwitchState = mutedCount == 0 ? .off : mutedCount == controls.count && unsupported.isEmpty ? .on : .partial
        var details: [String] = []
        if mutedCount > 0 && mutedCount < controls.count { details.append("Some microphone inputs remain unmuted.") }
        if !unsupported.isEmpty { details.append("Cannot mute: \(unsupported.joined(separator: ", "))") }
        return SwitchStatus(state: state, detail: details.joined(separator: " "))
    }
    func snapshot() async throws -> ResourceSnapshot { var result = ResourceSnapshot(); try result.encode(records(), key: "microphones"); return result }
    private func write(_ record: MicrophoneRecord, muteTo: Bool?) throws {
        guard let device = AudioHardware.devices().first(where: { AudioHardware.string($0, kAudioDevicePropertyDeviceUID) == record.uid }) else { throw SwitchError.failed("\(record.name) is disconnected; its state could not be restored.") }
        for control in record.controls {
            let selector = control.mute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar
            var property = AudioHardware.address(selector, scope: kAudioObjectPropertyScopeInput, element: control.channel)
            var code: OSStatus
            if control.mute {
                var value: UInt32 = muteTo.map { $0 ? 1 : 0 } ?? UInt32(control.value)
                code = AudioObjectSetPropertyData(device, &property, 0, nil, 4, &value)
            } else {
                var value: Float32 = muteTo.map { $0 ? 0 : max(control.value, 0.5) } ?? control.value
                code = AudioObjectSetPropertyData(device, &property, 0, nil, 4, &value)
            }
            guard code == noErr else { throw SwitchError.failed("\(record.name) refused the microphone change (\(code)).") }
            let expected: Float32 = control.mute ? (muteTo.map { $0 ? 1 : 0 } ?? control.value) : (muteTo.map { $0 ? 0 : max(control.value, 0.5) } ?? control.value)
            guard let actual = read(device, property: property, mute: control.mute), abs(actual - expected) <= (control.mute ? 0 : 0.005) else {
                throw SwitchError.failed("\(record.name) did not apply the requested microphone state.")
            }
        }
    }
    func apply(enabled: Bool, context: ActionContext) async throws {
        let values = records()
        guard values.contains(where: { !$0.controls.isEmpty }) else { throw SwitchError.unavailable("No writable microphone controls are available.") }
        if enabled {
            if original == nil { original = values }
            var errors: [String] = []
            for record in values where !record.controls.isEmpty { do { try write(record, muteTo: true) } catch { errors.append(error.localizedDescription) } }
            if !errors.isEmpty { throw SwitchError.failed(errors.joined(separator: "\n")) }
        } else {
            let saved = original ?? values
            var errors: [String] = []
            for record in saved where !record.controls.isEmpty { do { try write(record, muteTo: original == nil ? false : nil) } catch { errors.append(error.localizedDescription) } }
            if errors.isEmpty { original = nil } else { throw SwitchError.failed(errors.joined(separator: "\n")) }
        }
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {
        let records = try snapshot.decoded([MicrophoneRecord].self, key: "microphones")
        var errors: [String] = []
        for record in records where !record.controls.isEmpty { do { try write(record, muteTo: nil) } catch { errors.append(error.localizedDescription) } }
        if errors.isEmpty { original = nil } else { throw SwitchError.failed(errors.joined(separator: "\n")) }
    }
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool {
        let saved = try snapshot.decoded([MicrophoneRecord].self, key: "microphones")
        let current = Dictionary(uniqueKeysWithValues: records().map { ($0.uid, $0) })
        // New devices belong to the user; they do not prevent restoring the devices this operation changed.
        return saved.allSatisfy { current[$0.uid]?.controls == $0.controls }
    }
}
