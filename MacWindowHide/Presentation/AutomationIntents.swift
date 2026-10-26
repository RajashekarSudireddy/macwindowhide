import AppIntents

extension SwitchID: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Control" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.desktopIcons: "Hide Desktop Icons", .backdrop: "Backdrop", .otherApps: "Hide Other Apps",
         .dock: "Hide Dock", .menuBar: "Hide Menu Bar", .darkMode: "Dark Mode",
         .nightShift: "Night Shift", .trueTone: "True Tone", .screenSaver: "Screen Saver",
         .keepAwake: "Keep Awake", .airPods: "AirPods",
         .alertSounds: "Mute Alert Sounds", .microphone: "Mute Microphone", .keyboardLock: "Lock Keyboard"]
    }
}
enum ControlOperation: String, AppEnum {
    case toggle, on, off
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Operation" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.toggle: "Toggle", .on: "Turn on", .off: "Turn off"] }
}
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Recording Mode" }
    static var description: IntentDescription { "Prepare your screen with the actions selected in MacWindowHide Settings." }
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        await model.coordinator.startRecording(foregroundPID: model.foregroundPID)
        if !model.coordinator.isRecording { throw SwitchError.failed(model.coordinator.issue ?? "Recording Mode did not start.") }
        return .result()
    }
}
struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource { "Restore Recording Mode" }
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        let coordinator = AppModel.shared.coordinator
        await coordinator.stopRecording()
        if coordinator.phase == .recoveryNeeded { throw SwitchError.failed(coordinator.issue ?? "Some changes still need restoration.") }
        return .result()
    }
}
struct SetControlIntent: AppIntent {
    static var title: LocalizedStringResource { "Set MacWindowHide Control" }
    static var openAppWhenRun: Bool { true }
    @Parameter(title: "Control") var control: SwitchID
    @Parameter(title: "Operation", default: .toggle) var operation: ControlOperation
    static var parameterSummary: some ParameterSummary { Summary("\(\.$operation) \(\.$control)") }
    @MainActor func perform() async throws -> some IntentResult {
        guard !control.isRetired else { throw SwitchError.unavailable("This control has been removed from MacWindowHide.") }
        guard !control.isMomentary || operation != .off else {
            throw SwitchError.unavailable("Screen Saver is a start-only action. Interact with the Mac to dismiss it.")
        }
        let model = AppModel.shared
        switch operation {
        case .toggle: await model.toggle(control)
        case .on: await model.set(control, enabled: true)
        case .off: await model.set(control, enabled: false)
        }
        if let issue = model.coordinator.issue { throw SwitchError.failed(issue) }
        return .result()
    }
}
struct MacWindowHideShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: ["Start Recording Mode in \(.applicationName)", "Prepare my screen with \(.applicationName)"], shortTitle: "Start Recording Mode", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(), phrases: ["Restore Recording Mode in \(.applicationName)", "Restore my screen with \(.applicationName)"], shortTitle: "Restore Recording Mode", systemImageName: "arrow.uturn.backward")
        AppShortcut(intent: SetControlIntent(), phrases: ["Toggle \(\.$control) in \(.applicationName)"], shortTitle: "Set Control", systemImageName: "switch.2")
    }
}
