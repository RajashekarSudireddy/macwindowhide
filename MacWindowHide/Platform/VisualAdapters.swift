import AppKit
import Darwin

@MainActor func makeVisualAdapters(settings: SettingsStore) -> [any SystemSwitchAdapter] {
    BackdropController.shared.configure(settings: settings)
    MenuBarController.shared.configure(settings: settings)
    return [DesktopIconsAdapter(), BackdropAdapter(), OtherAppsAdapter(settings: settings), MenuBarAdapter()]
}

@MainActor private final class DesktopIconsAdapter: SystemSwitchAdapter {
    let id = SwitchID.desktopIcons
    func capability() async -> SwitchCapability { .available }
    func status() async -> SwitchStatus { SwitchStatus(state: BackdropController.shared.desktopHidden ? .on : .off, detail: "Desktop files and widgets are covered on every display.") }
    func snapshot() async throws -> ResourceSnapshot { ResourceSnapshot(enabled: BackdropController.shared.desktopHidden) }
    func apply(enabled: Bool, context: ActionContext) async throws { BackdropController.shared.setDesktopHidden(enabled, owner: context.owner) }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws { BackdropController.shared.setDesktopHidden(false, owner: context.owner) }
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool { snapshot.enabled == BackdropController.shared.desktopHidden }
    func shutdown() { BackdropController.shared.shutdown() }
}

@MainActor private final class BackdropAdapter: SystemSwitchAdapter {
    let id = SwitchID.backdrop
    func capability() async -> SwitchCapability { .available }
    func status() async -> SwitchStatus {
        if BackdropController.shared.isEnabled && !BackdropController.shared.hasVisibleBackdrop {
            return SwitchStatus(state: .partial, detail: "No foreground window is available; the backdrop is temporarily hidden.")
        }
        return SwitchStatus(state: BackdropController.shared.isEnabled ? .on : .off, detail: "A backdrop sits directly below the foreground app window.")
    }
    func snapshot() async throws -> ResourceSnapshot { ResourceSnapshot(enabled: BackdropController.shared.isEnabled) }
    func apply(enabled: Bool, context: ActionContext) async throws { try BackdropController.shared.setEnabled(enabled, context: context) }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws { try BackdropController.shared.setEnabled(false, context: context) }
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool { snapshot.enabled == BackdropController.shared.isEnabled }
}

@MainActor private final class MenuBarAdapter: SystemSwitchAdapter {
    let id = SwitchID.menuBar
    func capability() async -> SwitchCapability {
        if MenuBarController.shared.mode == .wholeBar { return await SystemScript.permission() }
        return MenuBarController.shared.capability()
    }
    func status() async -> SwitchStatus {
        switch await capability() {
        case .needsPermission(let reason): return SwitchStatus(state: .needsPermission, detail: reason)
        case .unsupported(let reason): return SwitchStatus(state: .unsupported, detail: reason)
        case .available: break
        }
        do {
            let snapshot = try await MenuBarController.shared.snapshot()
            return SwitchStatus(state: snapshot.enabled ? .on : .off, detail: MenuBarController.shared.mode == .icons ? "Visible, Hidden and Always Hidden shelves" : "The whole menu bar reveals at the screen edge.")
        } catch { return SwitchStatus(state: .unknown, detail: error.localizedDescription) }
    }
    func snapshot() async throws -> ResourceSnapshot { try await MenuBarController.shared.snapshot() }
    func apply(enabled: Bool, context: ActionContext) async throws { try await MenuBarController.shared.setEnabled(enabled, context: context) }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws { try await MenuBarController.shared.restore(snapshot, context: context) }
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool {
        if snapshot.values["mode"] == MenuBarMode.wholeBar.rawValue {
            return String(try await SystemScript.readBoolean(.menuBarHidden)) == snapshot.values["wholeBar"]
        }
        let current = try await self.snapshot()
        return current.enabled == snapshot.enabled
    }
    func shutdown() { MenuBarController.shared.shutdown() }
}

private struct HiddenAppIdentity: Codable, Equatable {
    var pid: Int32
    var bundleID: String
    var launchTime: TimeInterval
}
private struct HiddenAppLedger: Codable {
    var owners: [String: [HiddenAppIdentity]] = [:]
}

@MainActor private final class OtherAppsAdapter: SystemSwitchAdapter {
    let id = SwitchID.otherApps
    private let settings: SettingsStore
    private let ledgerURL: URL
    private var ledger: HiddenAppLedger
    private var ledgerReadError: String?
    private var unhideObserver: NSObjectProtocol?

    init(settings: SettingsStore) {
        self.settings = settings
        ledgerURL = settings.directory.appendingPathComponent("HiddenApps.json")
        do {
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                ledger = try JSONDecoder().decode(HiddenAppLedger.self, from: Data(contentsOf: ledgerURL))
            } else { ledger = HiddenAppLedger() }
        } catch {
            ledger = HiddenAppLedger()
            ledgerReadError = "Hidden-app recovery data could not be read. Reveal any hidden apps manually before repairing the recovery file: \(error.localizedDescription)"
        }
        unhideObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let launch = app.launchDate?.timeIntervalSince1970 else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.ledgerReadError == nil else { return }
                // A user-revealed app is released from both leases and stays visible.
                for owner in self.ledger.owners.keys {
                    self.ledger.owners[owner]?.removeAll { $0.pid == pid && $0.launchTime == launch }
                }
                try? self.persist()
            }
        }
    }

    func capability() async -> SwitchCapability {
        if let ledgerReadError { return .unsupported(ledgerReadError) }
        return .available
    }
    func status() async -> SwitchStatus {
        if let ledgerReadError { return SwitchStatus(state: .unknown, detail: ledgerReadError) }
        let count = ledger.owners.values.flatMap { $0 }.filter { liveApp($0)?.isHidden == true }.count
        return SwitchStatus(state: count > 0 ? .on : .off, detail: count > 0 ? "Only apps hidden by MacWindowHide will be restored." : "The foreground app and excluded recorders stay visible.")
    }
    func snapshot() async throws -> ResourceSnapshot {
        if let ledgerReadError { throw SwitchError.failed(ledgerReadError) }
        let status = await status()
        var snapshot = ResourceSnapshot(enabled: status.isEnabled)
        try snapshot.encode(ledger.owners, key: "owners")
        return snapshot
    }
    func apply(enabled: Bool, context: ActionContext) async throws {
        if let ledgerReadError { throw SwitchError.failed(ledgerReadError) }
        guard enabled else { try release(context.owner); return }
        let foreground = context.foregroundPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let excluded = Set(settings.preferences.excludedBundleIDs)
        let owner = context.owner.rawValue
        var failed: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.processIdentifier != foreground,
                  let bundle = app.bundleIdentifier, bundle != "com.apple.finder", !excluded.contains(bundle), let launched = app.launchDate else { continue }
            let identity = HiddenAppIdentity(pid: app.processIdentifier, bundleID: bundle, launchTime: launched.timeIntervalSince1970)
            let alreadyOwned = ledger.owners.values.contains { $0.contains(identity) }
            guard !app.isHidden || alreadyOwned else { continue }
            if ledger.owners[owner]?.contains(identity) != true {
                ledger.owners[owner, default: []].append(identity)
                // Write ahead of each hide; a process death cannot strand an app.
                try persist()
            }
            if !app.isHidden && !app.hide() {
                ledger.owners[owner]?.removeAll { $0 == identity }; try persist()
                failed.append(app.localizedName ?? bundle)
            }
        }
        if !failed.isEmpty { throw SwitchError.failed("These apps could not be hidden: \(failed.joined(separator: ", ")).") }
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws { try release(context.owner) }
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool {
        if let ledgerReadError { throw SwitchError.failed(ledgerReadError) }
        // Restore per process below; a user revealing one app must not strand others.
        let hasClaims = ledger.owners.values.contains { !$0.isEmpty }
        return snapshot.enabled ? hasClaims : !hasClaims
    }
    private func release(_ owner: ActionOwner) throws {
        if let ledgerReadError { throw SwitchError.failed(ledgerReadError) }
        let owned = ledger.owners[owner.rawValue] ?? []
        var failed: [HiddenAppIdentity] = []
        for identity in owned {
            let shared = ledger.owners.contains { $0.key != owner.rawValue && $0.value.contains(identity) }
            if !shared, let app = liveApp(identity), app.isHidden, !app.unhide() { failed.append(identity); continue }
            // A claim remains durable until its unhide succeeded or is unnecessary.
            ledger.owners[owner.rawValue]?.removeAll { $0 == identity }
            try persist()
        }
        if !failed.isEmpty {
            throw SwitchError.failed("Some hidden apps did not respond. Restore again to retry.")
        }
    }
    private func liveApp(_ identity: HiddenAppIdentity) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: identity.pid), app.bundleIdentifier == identity.bundleID,
              app.launchDate?.timeIntervalSince1970 == identity.launchTime, !app.isTerminated else { return nil }
        return app
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: settings.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
        let file = open(ledgerURL.path, O_RDONLY)
        guard file >= 0 else { throw SwitchError.failed("The hidden-app recovery ledger could not be opened for synchronization.") }
        defer { close(file) }
        if fcntl(file, F_FULLFSYNC) != 0, fsync(file) != 0 { throw SwitchError.failed("The hidden-app recovery ledger could not be synchronized.") }
        let directory = open(settings.directory.path, O_RDONLY)
        guard directory >= 0 else { throw SwitchError.failed("The recovery directory could not be opened for synchronization.") }
        defer { close(directory) }
        if fsync(directory) != 0 && errno != EINVAL && errno != ENOTSUP { throw SwitchError.failed("The recovery directory could not be synchronized.") }
    }
    func shutdown() {
        if let unhideObserver { NSWorkspace.shared.notificationCenter.removeObserver(unhideObserver) }
        unhideObserver = nil
    }
}
