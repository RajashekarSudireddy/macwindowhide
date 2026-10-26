import AppKit
import Combine
import Foundation

enum SwitchID: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case desktopIcons, backdrop, otherApps, dock, menuBar, darkMode, nightShift, trueTone
    case screenSaver, keepAwake, airPods, alertSounds, microphone, keyboardLock
    // Decode old files without exposing or running the removed control.
    case retiredDoNotDisturb = "doNotDisturb"
    static let allCases: [Self] = [.desktopIcons, .backdrop, .otherApps, .dock, .menuBar, .darkMode, .nightShift, .trueTone,
                                   .screenSaver, .keepAwake, .airPods, .alertSounds, .microphone, .keyboardLock]
    var isRetired: Bool { self == .retiredDoNotDisturb }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktopIcons: "Hide Desktop Icons"
        case .backdrop: "Backdrop"
        case .otherApps: "Hide Other Apps"
        case .dock: "Hide Dock"
        case .menuBar: "Hide Menu Bar"
        case .darkMode: "Dark Mode"
        case .nightShift: "Night Shift"
        case .trueTone: "True Tone"
        case .screenSaver: "Screen Saver"
        case .retiredDoNotDisturb: "Removed control"
        case .keepAwake: "Keep Awake"
        case .airPods: "AirPods"
        case .alertSounds: "Mute Alert Sounds"
        case .microphone: "Mute Microphone"
        case .keyboardLock: "Lock Keyboard"
        }
    }
    var symbol: String {
        switch self {
        case .desktopIcons: "desktopcomputer"
        case .backdrop: "photo.on.rectangle"
        case .otherApps: "macwindow.on.rectangle"
        case .dock: "dock.rectangle"
        case .menuBar: "menubar.rectangle"
        case .darkMode: "moon.fill"
        case .nightShift: "sun.horizon.fill"
        case .trueTone: "sun.max.fill"
        case .screenSaver: "sparkles.tv"
        case .retiredDoNotDisturb: "xmark.circle"
        case .keepAwake: "cup.and.saucer.fill"
        case .airPods: "airpodspro"
        case .alertSounds: "bell.slash.fill"
        case .microphone: "mic.slash.fill"
        case .keyboardLock: "keyboard"
        }
    }
    var isMomentary: Bool { self == .screenSaver }
    var supportsRecording: Bool { !isRetired && ![.screenSaver, .airPods, .keyboardLock].contains(self) }
    var supportsTimer: Bool { !isRetired && !isMomentary && self != .keyboardLock }
    static let defaultRecording: Set<Self> = [.desktopIcons, .backdrop, .otherApps, .dock, .menuBar, .keepAwake, .alertSounds]
}

enum SwitchState: String, Codable, Sendable { case on, off, partial, unknown, needsPermission, unsupported }
struct SwitchStatus: Equatable, Sendable {
    var state: SwitchState
    var detail: String = ""
    var isEnabled: Bool { state == .on || state == .partial }
    static let unknown = SwitchStatus(state: .unknown)
}
enum SwitchCapability: Equatable, Sendable {
    case available, needsPermission(String), unsupported(String)
    var reason: String? {
        switch self { case .available: nil; case .needsPermission(let reason), .unsupported(let reason): reason }
    }
    var isAvailable: Bool { self == .available }
}
struct ResourceSnapshot: Codable, Equatable, Sendable {
    var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    init(enabled: Bool) { values = ["enabled": String(enabled)] }
    var enabled: Bool { values["enabled"] == "true" }
    func decoded<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard let text = values[key], let data = text.data(using: .utf8) else { throw SwitchError.failed("Missing snapshot field: \(key)") }
        return try JSONDecoder().decode(type, from: data)
    }
    mutating func encode<T: Encodable>(_ value: T, key: String) throws {
        values[key] = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
enum ActionOwner: String, Codable, Sendable { case standalone, recording }
struct ActionContext: Sendable {
    var owner: ActionOwner = .standalone
    var foregroundPID: Int32? = nil
}
enum SwitchError: LocalizedError {
    case failed(String), unavailable(String), busy
    var errorDescription: String? {
        switch self {
        case .failed(let message), .unavailable(let message): message
        case .busy: "Another operation is still finishing."
        }
    }
}
@MainActor protocol SystemSwitchAdapter: AnyObject {
    var id: SwitchID { get }
    func capability() async -> SwitchCapability
    func status() async -> SwitchStatus
    func snapshot() async throws -> ResourceSnapshot
    func apply(enabled: Bool, context: ActionContext) async throws
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool
    func shutdown()
}
extension SystemSwitchAdapter {
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool { try await self.snapshot() == snapshot }
    func shutdown() {}
}

enum BackdropStyle: String, CaseIterable, Codable, Sendable { case color, gradient, mesh, custom, wallpaper, image }
enum MenuBarMode: String, CaseIterable, Codable, Sendable { case icons, wholeBar }
enum MenuShelf: String, CaseIterable, Codable, Sendable { case visible, hidden, alwaysHidden }
enum AwakeTimerMode: String, CaseIterable, Codable, Sendable { case duration, clock, indefinite }
struct AppPreferences: Codable, Equatable, Sendable {
    var countdownEnabled = false
    var recordingLimitMinutes = 0
    var recordingSwitches = SwitchID.defaultRecording
    var switchOrder = SwitchID.allCases
    var visibleSwitches: Set<SwitchID> = [.darkMode, .keepAwake, .desktopIcons, .otherApps, .dock, .alertSounds, .microphone]
    var hiddenSwitches: Set<SwitchID> = []
    var keepAwakeMinutes = 120
    var awakeTimerMode: AwakeTimerMode = .duration
    var awakeUntil = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 8), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
    var backdropStyle: BackdropStyle = .gradient
    var backdropPreset = 0
    var customColorHex = "#527D91"
    var backdropImagePath = ""
    var backdropBlur = 0.0
    var backdropDim = 0.12
    var menuBarMode: MenuBarMode = .icons
    var menuBarAssignments: [String: MenuShelf] = [:]
    var menuBarHoverReveal = true
    var preferredAirPodsAddress = ""
    var excludedBundleIDs = ["us.zoom.xos", "com.loom.desktop", "com.timplaus.screen-studio", "com.obsproject.obs-studio", "com.microsoft.teams2", "com.apple.QuickTimePlayerX"]
    var autoOffMinutes: [String: Int] = [:]

    mutating func removeRetiredControls() {
        recordingSwitches = recordingSwitches.filter { !$0.isRetired }
        switchOrder.removeAll(where: \.isRetired)
        visibleSwitches = visibleSwitches.filter { !$0.isRetired }
        hiddenSwitches = hiddenSwitches.filter { !$0.isRetired }
        autoOffMinutes.removeValue(forKey: SwitchID.retiredDoNotDisturb.rawValue)
    }
}

@MainActor final class SettingsStore: ObservableObject {
    @Published var preferences: AppPreferences { didSet { save() } }
    let directory: URL
    private let fileURL: URL
    @Published private(set) var persistenceError: String?
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        fileURL = self.directory.appendingPathComponent("Settings.json")
        if let data = try? Data(contentsOf: fileURL), var saved = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            saved.removeRetiredControls()
            preferences = saved
        } else { preferences = AppPreferences() }
    }
    static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["MACWINDOWHIDE_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacWindowHide", isDirectory: true)
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: fileURL, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Settings could not be saved: \(error.localizedDescription)" }
    }
}
