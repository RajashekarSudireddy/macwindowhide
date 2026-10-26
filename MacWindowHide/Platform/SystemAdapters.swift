import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt

enum SystemScript {
    enum BooleanProperty: Sendable {
        case dockHidden, menuBarHidden, darkMode
        var expression: String {
            switch self {
            case .dockHidden: "autohide of dock preferences"
            case .menuBarHidden: "autohide menu bar of dock preferences"
            case .darkMode: "dark mode of appearance preferences"
            }
        }
    }
    static func permission() async -> SwitchCapability {
        let code = await permissionStatus(askUserIfNeeded: false)
        if code == noErr { return .available }
        return .needsPermission("Allow MacWindowHide to control System Events in Privacy & Security → Automation.")
    }
    private static func permissionStatus(askUserIfNeeded: Bool) async -> OSStatus {
        await Task.detached(priority: .utility) {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUserIfNeeded)
        }.value
    }
    @MainActor static func requestPermission() async throws {
        // The permission API requires a running target; launch only during explicit setup.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systemevents") else {
                throw SwitchError.unavailable("System Events could not be found on this Mac.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        try validatePermissionRequest(await permissionStatus(askUserIfNeeded: true))
    }
    static func validatePermissionRequest(_ code: OSStatus) throws {
        switch code {
        case noErr: return
        case OSStatus(errAEEventNotPermitted):
            throw SwitchError.unavailable("System Events control is not allowed. Open Automation Settings and enable System Events under MacWindowHide. macOS does not repeat a previously denied permission prompt.")
        case OSStatus(errAEEventWouldRequireUserConsent):
            throw SwitchError.unavailable("System Events control still needs permission. Try again and respond to the macOS permission prompt.")
        default:
            throw SwitchError.failed("macOS could not request System Events control (error \(code)). Try again, or check Automation Settings.")
        }
    }
    static func readBoolean(_ property: BooleanProperty) async throws -> Bool {
        guard await permission().isAvailable else { throw SwitchError.unavailable("System Events Automation permission is required.") }
        let result = try await run("get \(property.expression)")
        guard result == "true" || result == "false" else { throw SwitchError.failed("System Events returned an unrecognized state.") }
        return result == "true"
    }
    static func setBoolean(_ value: Bool, for property: BooleanProperty) async throws {
        _ = try await run("set \(property.expression) to \(value ? "true" : "false")")
        guard try await readBoolean(property) == value else { throw SwitchError.failed("macOS did not apply the setting.") }
    }
    private static func run(_ expression: String) async throws -> String {
        let result = try await ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", "tell application \"System Events\" to \(expression)"])
        if result.exitCode != 0 && (result.error.contains("1743") || result.error.contains("1744")) { throw SwitchError.unavailable("Allow System Events in Privacy & Security → Automation.") }
        return try result.checked()
    }
}

@MainActor final class ScriptSwitchAdapter: SystemSwitchAdapter {
    let id: SwitchID
    let property: SystemScript.BooleanProperty
    init(id: SwitchID, property: SystemScript.BooleanProperty) { self.id = id; self.property = property }
    func capability() async -> SwitchCapability { await SystemScript.permission() }
    func status() async -> SwitchStatus {
        let permission = await capability()
        guard permission.isAvailable else { return SwitchStatus(state: .needsPermission, detail: permission.reason ?? "Automation is required.") }
        do { return SwitchStatus(state: try await SystemScript.readBoolean(property) ? .on : .off) }
        catch { return SwitchStatus(state: .unknown, detail: error.localizedDescription) }
    }
    func snapshot() async throws -> ResourceSnapshot { ResourceSnapshot(enabled: try await SystemScript.readBoolean(property)) }
    func apply(enabled: Bool, context: ActionContext) async throws { try await SystemScript.setBoolean(enabled, for: property) }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws { try await apply(enabled: snapshot.enabled, context: context) }
}

@MainActor final class DisplaySwitchAdapter: SystemSwitchAdapter {
    let id: SwitchID
    private var kind: Int { id == .nightShift ? 0 : 1 }
    init(id: SwitchID) { self.id = id }
    func capability() async -> SwitchCapability {
        MWHDisplaySupported(kind) && MWHDisplayEnabled(kind) >= 0 ? .available : .unsupported("\(id.title) is unavailable on this display or macOS version.")
    }
    func status() async -> SwitchStatus {
        let value = MWHDisplayEnabled(kind)
        return SwitchStatus(state: value < 0 ? .unsupported : value == 1 ? .on : .off, detail: value < 0 ? "This display or macOS version is not supported." : "")
    }
    func snapshot() async throws -> ResourceSnapshot {
        let value = MWHDisplayEnabled(kind)
        guard value >= 0 else { throw SwitchError.unavailable("\(id.title) state cannot be read.") }
        return ResourceSnapshot(enabled: value == 1)
    }
    func apply(enabled: Bool, context: ActionContext) async throws {
        guard MWHSetDisplayEnabled(kind, enabled) else { throw SwitchError.unavailable("macOS could not change \(id.title). The display may not support it.") }
        guard MWHDisplayEnabled(kind) == (enabled ? 1 : 0) else { throw SwitchError.failed("\(id.title) could not be verified.") }
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws { try await apply(enabled: snapshot.enabled, context: context) }
}

@MainActor final class ScreenSaverAdapter: SystemSwitchAdapter {
    let id: SwitchID = .screenSaver
    private let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
    func capability() async -> SwitchCapability { FileManager.default.fileExists(atPath: url.path) ? .available : .unsupported("The system Screen Saver application could not be found.") }
    func status() async -> SwitchStatus { SwitchStatus(state: .off, detail: "Start the current screen saver") }
    func snapshot() async throws -> ResourceSnapshot { ResourceSnapshot(enabled: false) }
    func apply(enabled: Bool, context: ActionContext) async throws {
        guard enabled else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {}
}

@MainActor final class KeepAwakeAdapter: SystemSwitchAdapter {
    let id: SwitchID = .keepAwake
    private var leases: [ActionOwner: IOPMAssertionID] = [:]
    func capability() async -> SwitchCapability { .available }
    func status() async -> SwitchStatus { SwitchStatus(state: leases.isEmpty ? .off : .on, detail: leases.isEmpty ? "" : "Preventing display and idle sleep") }
    func snapshot() async throws -> ResourceSnapshot {
        ResourceSnapshot(["owners": leases.keys.map(\.rawValue).sorted().joined(separator: ","), "enabled": String(!leases.isEmpty)])
    }
    func apply(enabled: Bool, context: ActionContext) async throws {
        if enabled {
            guard leases[context.owner] == nil else { return }
            var token: IOPMAssertionID = 0
            let code = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacWindowHide \(context.owner.rawValue)" as CFString, &token)
            guard code == kIOReturnSuccess else { throw SwitchError.failed("macOS refused the keep-awake assertion (\(code)).") }
            leases[context.owner] = token
        } else if let token = leases.removeValue(forKey: context.owner) { IOPMAssertionRelease(token) }
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {
        let owners = snapshot.values["owners", default: ""].split(separator: ",").map(String.init)
        try await apply(enabled: owners.contains(context.owner.rawValue), context: context)
    }
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool { snapshot.enabled == !leases.isEmpty }
    func shutdown() { for token in leases.values { IOPMAssertionRelease(token) }; leases.removeAll() }
}

@MainActor final class AlertSoundsAdapter: SystemSwitchAdapter {
    let id: SwitchID = .alertSounds
    private var priorVolume: Int?
    private func readVolume() async throws -> Int {
        let result = try await ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", "alert volume of (get volume settings)"])
        let text = try result.checked()
        guard let value = Int(text), (0...100).contains(value) else { throw SwitchError.failed("macOS returned an invalid alert volume.") }
        return value
    }
    private func writeVolume(_ value: Int) async throws {
        guard (0...100).contains(value) else { throw SwitchError.failed("The saved alert volume is invalid.") }
        _ = try await ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", "set volume alert volume \(value)"]).checked()
        guard try await readVolume() == value else { throw SwitchError.failed("macOS did not apply the alert volume.") }
    }
    func capability() async -> SwitchCapability { .available }
    func status() async -> SwitchStatus {
        do { return SwitchStatus(state: try await readVolume() == 0 ? .on : .off) }
        catch { return SwitchStatus(state: .unknown, detail: error.localizedDescription) }
    }
    func snapshot() async throws -> ResourceSnapshot { ResourceSnapshot(["volume": String(try await readVolume())]) }
    func apply(enabled: Bool, context: ActionContext) async throws {
        if enabled {
            if priorVolume == nil { priorVolume = try await readVolume() }
            try await writeVolume(0)
        } else {
            try await writeVolume(priorVolume ?? 100)
            priorVolume = nil
        }
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {
        guard let volume = snapshot.values["volume"].flatMap(Int.init) else { throw SwitchError.failed("The saved alert volume is missing.") }
        try await writeVolume(volume)
        priorVolume = nil
    }
}

@MainActor func makeSystemAdapters(settings: SettingsStore) -> [any SystemSwitchAdapter] {
    [ScriptSwitchAdapter(id: .dock, property: .dockHidden), ScriptSwitchAdapter(id: .darkMode, property: .darkMode),
     DisplaySwitchAdapter(id: .nightShift), DisplaySwitchAdapter(id: .trueTone), ScreenSaverAdapter(), KeepAwakeAdapter(),
     AirPodsAdapter(settings: settings), AlertSoundsAdapter(), MicrophoneAdapter(), KeyboardLockAdapter()]
}
