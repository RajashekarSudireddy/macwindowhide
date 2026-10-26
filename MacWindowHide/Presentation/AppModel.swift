import AppKit
import ApplicationServices
import Combine
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let recordingMode = Self("recordingMode", initial: .init(.r, modifiers: [.control, .option, .command]))
    static func control(_ id: SwitchID) -> Self { Self("switch.\(id.rawValue)") }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", recording = "Recording Mode", switches = "Switches", backdrop = "Backdrop"
    case menuBar = "Menu Bar", shortcuts = "Shortcuts", permissions = "Permissions"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .switches: "switch.2"
        case .backdrop: "photo"
        case .menuBar: "menubar.rectangle"
        case .shortcuts: "command"
        case .permissions: "hand.raised"
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    let settings: SettingsStore
    let coordinator: MutationCoordinator
    @Published var selectedSection: SettingsSection = .general
    @Published var message: String?
    @Published private(set) var requestingAutomation = false
    @Published var foregroundPID: Int32?
    @Published var now = Date()
    var showSettingsHandler: (() -> Void)?
    var closePanelHandler: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var tickTask: Task<Void, Never>?

    private init() {
        let store = SettingsStore()
        settings = store
        coordinator = MutationCoordinator(adapters: makeSystemAdapters(settings: store) + makeVisualAdapters(settings: store), settings: store)
        foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                if let pid, pid != ProcessInfo.processInfo.processIdentifier { self?.foregroundPID = pid }
            }
        }
    }

    func start() {
        KeyboardShortcuts.onKeyUp(for: .recordingMode) { Task { @MainActor in await AppModel.shared.toggleRecording() } }
        for id in SwitchID.allCases {
            KeyboardShortcuts.onKeyUp(for: .control(id)) { Task { @MainActor in await AppModel.shared.toggle(id) } }
        }
        Task { await coordinator.recover(); await coordinator.refresh() }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.now = Date()
                await self.coordinator.tick()
            }
        }
    }

    func toggleRecording() async {
        if coordinator.isRecording || coordinator.phase == .countdown || coordinator.phase == .recoveryNeeded {
            await coordinator.stopRecording()
        } else {
            await coordinator.startRecording(foregroundPID: foregroundPID)
        }
    }
    func toggle(_ id: SwitchID) async {
        let enabled = !(coordinator.statuses[id]?.isEnabled ?? false)
        await coordinator.setSwitch(id, enabled: enabled, foregroundPID: foregroundPID)
    }
    func set(_ id: SwitchID, enabled: Bool) async {
        await coordinator.setSwitch(id, enabled: enabled, foregroundPID: foregroundPID)
    }
    func showSettings(_ section: SettingsSection = .general) {
        selectedSection = section
        closePanelHandler?()
        showSettingsHandler?()
    }
    func extendAwake(minutes: Int) async {
        guard coordinator.statuses[.keepAwake]?.isEnabled == true else { return }
        let baseline = max(coordinator.timers[.keepAwake] ?? now, now)
        await coordinator.scheduleAutoOff(.keepAwake, date: baseline.addingTimeInterval(Double(minutes) * 60))
    }
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
    func requestAutomation() async {
        guard !requestingAutomation else { return }
        requestingAutomation = true
        defer { requestingAutomation = false }
        do {
            try await SystemScript.requestPermission()
            message = "System Events control is allowed. MacWindowHide can control the Dock, whole menu bar and Dark Mode."
        } catch { message = error.localizedDescription }
        await coordinator.refresh()
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            objectWillChange.send()
        } catch { message = error.localizedDescription }
    }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func importBackdrop() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let values = try source.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 50_000_000, NSImage(contentsOf: source) != nil else {
                throw SwitchError.failed("Choose a readable image smaller than 50 MB.")
            }
            let directory = settings.directory.appendingPathComponent("Images", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            settings.preferences.backdropImagePath = destination.path
            settings.preferences.backdropStyle = .image
            BackdropController.shared.refreshAppearance()
        } catch { message = error.localizedDescription }
    }
    func chooseHeadphones() {
        BluetoothAudioController.shared.requestPermission()
        let headphones = BluetoothAudioController.shared.pairedHeadphones()
        guard !headphones.isEmpty else {
            message = "No paired headphones are available. Allow Bluetooth access, pair headphones in System Settings, then choose again."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Choose your headphones"
        alert.informativeText = "MacWindowHide will connect this already-paired device and verify its audio output."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        picker.addItems(withTitles: headphones.map { "\($0.name) · \($0.address)" })
        if let selected = headphones.firstIndex(where: { $0.address == settings.preferences.preferredAirPodsAddress }) { picker.selectItem(at: selected) }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Choose")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.preferences.preferredAirPodsAddress = headphones[picker.indexOfSelectedItem].address
            Task { await coordinator.refresh() }
        }
    }
    func refreshBackdrop() { BackdropController.shared.refreshAppearance() }
    func setMenuShelf(_ shelf: MenuShelf, for bundleID: String) {
        Task {
            do { try await MenuBarController.shared.setShelf(shelf, for: bundleID); objectWillChange.send() }
            catch { message = error.localizedDescription }
        }
    }
    func revealMenuItems(all: Bool) {
        Task {
            do {
                if all { try await MenuBarController.shared.revealAll() }
                else { try await MenuBarController.shared.revealHidden() }
                objectWillChange.send()
            } catch { message = error.localizedDescription }
        }
    }
    func collapseMenuItems() {
        Task { do { try await MenuBarController.shared.collapse() } catch { message = error.localizedDescription } }
    }
    func quit() {
        NSApplication.shared.terminate(nil)
    }
    func prepareToQuit() async -> Bool {
        await coordinator.shutdown()
        guard coordinator.phase != .recoveryNeeded else { return false }
        tickTask?.cancel()
        KeyboardLockController.shared.unlock()
        return true
    }
    var elapsed: String {
        guard let start = coordinator.startedAt else { return "00:00" }
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    func timerLabel(_ id: SwitchID) -> String? {
        guard let deadline = coordinator.timers[id] else { return nil }
        let seconds = max(0, Int(deadline.timeIntervalSince(now)))
        return seconds >= 3600 ? "Off in \(seconds / 3600)h \((seconds % 3600) / 60)m" : "Off in \(seconds / 60)m \(seconds % 60)s"
    }
}
