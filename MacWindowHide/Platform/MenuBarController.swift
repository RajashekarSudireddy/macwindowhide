import AppKit
import ApplicationServices
import Combine

struct MenuBarOwner: Identifiable, Equatable {
    var bundleID: String
    var ownerName: String
    var shelf: MenuShelf
    var id: String { bundleID }
}

@MainActor final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()
    @Published private(set) var inventory: [MenuBarOwner] = []
    @Published private(set) var isCollapsed = false
    @Published private(set) var lastError: String?
    var didChange: (() -> Void)?
    private weak var settings: SettingsStore?
    private var hiddenDivider: NSStatusItem?
    private var alwaysDivider: NSStatusItem?
    private var revealItem: NSStatusItem?
    private var assertion: Any?
    private var generation = 0
    private var owners: Set<ActionOwner> = []
    private var activeMode: MenuBarMode?
    private var menuBarWasHidden = false
    private var mouseMonitor: Any?
    private var hoverTimer: Timer?
    private var rehideTimer: Timer?
    private var frames: [String: CGRect] = [:]
    private var recordingDividerPosition: CGPoint?
    private var screenObserver: NSObjectProtocol?
    private var native: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    func configure(settings: SettingsStore) {
        self.settings = settings
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isCollapsed, self.mode == .icons else { return }
                    do { try await self.collapse() } catch { self.lastError = error.localizedDescription; self.didChange?() }
                }
            }
        }
    }
    var mode: MenuBarMode { activeMode ?? settings?.preferences.menuBarMode ?? .icons }
    func active(for owner: ActionOwner) -> Bool { owners.contains(owner) }

    func capability() -> SwitchCapability {
        if (settings?.preferences.menuBarMode ?? .icons) == .wholeBar { return .available }
        if native && !MWHMenuBarNativeAvailable() { return .unsupported("The menu bar interface is unavailable on this macOS build. Whole Menu Bar mode is available in Settings.") }
        if !AXIsProcessTrusted() { return .needsPermission("Allow Accessibility to organize and reveal other apps’ menu bar items.") }
        return .available
    }

    func refreshInventory() async {
        guard AXIsProcessTrusted() else { inventory = []; didChange?(); return }
        // Hidden items retain stale AX positions. Keep the last unrestricted inventory.
        if native && assertion != nil { return }
        var found: [MenuBarOwner] = []; var newFrames: [String: CGRect] = [:]
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier != Bundle.main.bundleIdentifier {
            guard let bundle = app.bundleIdentifier else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var extras: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &extras) == .success,
                  let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() else { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(unsafeDowncast(extras, to: AXUIElement.self), kAXChildrenAttribute as CFString, &children) == .success,
                  let items = children as? [AXUIElement], !items.isEmpty else { continue }
            let rect = items.compactMap(Self.frame).reduce(CGRect.null) { $0.union($1) }
            if !rect.isNull { newFrames[bundle] = rect }
            let shelf = settings?.preferences.menuBarAssignments[bundle] ?? (native ? .hidden : inferredShelf(rect))
            found.append(MenuBarOwner(bundleID: bundle, ownerName: app.localizedName ?? bundle, shelf: shelf))
        }
        frames = newFrames
        inventory = found.sorted { $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName) == .orderedAscending }
        didChange?()
    }

    func setShelf(_ shelf: MenuShelf, for bundleID: String) async throws {
        guard AXIsProcessTrusted() else { throw SwitchError.unavailable("Accessibility permission is required to organize menu bar items.") }
        let wasCollapsed = isCollapsed
        try await revealAll()
        await refreshInventory()
        if !native {
            ensureItems()
            guard let source = frames[bundleID], let hidden = hiddenDivider?.button?.window, let always = alwaysDivider?.button?.window else { throw SwitchError.unavailable("This menu bar item is not visible. Reveal the menu bar and try again.") }
            let h = Self.quartzFrame(hidden.frame); let a = Self.quartzFrame(always.frame)
            let destinationX: CGFloat
            switch shelf {
            case .visible: destinationX = h.maxX + 6
            case .hidden: destinationX = (a.maxX + h.minX) / 2
            case .alwaysHidden: destinationX = a.minX - 6
            }
            try Self.drag(from: CGPoint(x: source.midX, y: source.midY), to: CGPoint(x: destinationX, y: source.midY))
        }
        settings?.preferences.menuBarAssignments[bundleID] = shelf
        if let index = inventory.firstIndex(where: { $0.bundleID == bundleID }) { inventory[index].shelf = shelf }
        if wasCollapsed { try await collapse() }
        didChange?()
    }

    func revealHidden() async throws { try await show(includeAlwaysHidden: false) }
    func revealAll() async throws { try await show(includeAlwaysHidden: true) }
    func collapse() async throws {
        ensureItems()
        if native {
            await refreshInventory()
            let keep = owners.contains(.recording) ? [] : inventory.filter { $0.shelf == .visible }.map(\.bundleID)
            try await restrictNative(to: keep)
        } else {
            let width = min(max((NSScreen.screens.map { $0.frame.width }.max() ?? 1920) * 2, 500), 10_000)
            hiddenDivider?.length = width
            alwaysDivider?.length = width
        }
        isCollapsed = true
        startHoverMonitor()
        didChange?()
    }

    func setEnabled(_ enabled: Bool, context: ActionContext) async throws {
        if enabled {
            let availability = capability()
            guard availability.isAvailable else { throw SwitchError.unavailable(availability.reason ?? "Menu bar controls are unavailable.") }
            if owners.isEmpty {
                activeMode = settings?.preferences.menuBarMode ?? .icons
                if activeMode == .wholeBar { menuBarWasHidden = try await SystemScript.readBoolean(.menuBarHidden) }
            }
            owners.insert(context.owner)
            do {
                if mode == .wholeBar { try await SystemScript.setBoolean(true, for: .menuBarHidden); isCollapsed = true }
                else {
                    ensureItems()
                    if context.owner == .recording && !native { try moveDividerForRecording() }
                    try await collapse()
                }
            } catch { owners.remove(context.owner); throw error }
        } else {
            owners.remove(context.owner)
            if mode == .wholeBar {
                if owners.isEmpty { try await SystemScript.setBoolean(menuBarWasHidden, for: .menuBarHidden); isCollapsed = false }
            } else if owners.isEmpty { try await revealAll(); restoreRecordingDivider() }
            else { if !owners.contains(.recording) { restoreRecordingDivider() }; try await collapse() }
            if owners.isEmpty { activeMode = nil }
        }
    }

    func snapshot() async throws -> ResourceSnapshot {
        if mode == .wholeBar {
            let whole = try await SystemScript.readBoolean(.menuBarHidden)
            return ResourceSnapshot(["enabled": String(whole), "mode": mode.rawValue, "wholeBar": String(whole)])
        }
        var values = ["enabled": String(isCollapsed), "mode": mode.rawValue]
        if !native {
            for name in ["Reveal", "HiddenBoundary", "AlwaysHiddenBoundary"] {
                let key = "NSStatusItem Preferred Position MacWindowHide.\(name)"
                values["position.\(name)"] = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.stringValue ?? "missing"
            }
        }
        return ResourceSnapshot(values)
    }

    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {
        owners.remove(context.owner)
        if mode == .wholeBar || (owners.isEmpty && snapshot.values["mode"] == MenuBarMode.wholeBar.rawValue) {
            if owners.isEmpty {
                let original = snapshot.values["wholeBar"] == "true"
                try await SystemScript.setBoolean(original, for: .menuBarHidden)
                isCollapsed = false; activeMode = nil
            } else {
                try await SystemScript.setBoolean(true, for: .menuBarHidden)
                isCollapsed = true
            }
            return
        }
        if owners.isEmpty {
            try await revealAll(); restoreRecordingDivider()
            restoreLegacyPositions(snapshot)
            if let value = snapshot.values["wholeBar"] { try await SystemScript.setBoolean(value == "true", for: .menuBarHidden) }
            activeMode = nil
            if snapshot.enabled && snapshot.values["mode"] == MenuBarMode.icons.rawValue { try await collapse() }
        } else { try await collapse() }
    }

    func shutdown() {
        generation += 1
        if let assertion { MWHMenuBarInvalidate(assertion) }; assertion = nil
        stopHoverMonitor()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        for item in [hiddenDivider, alwaysDivider, revealItem].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        hiddenDivider = nil; alwaysDivider = nil; revealItem = nil; owners.removeAll(); isCollapsed = false
    }

    private func ensureItems() {
        guard revealItem == nil else { return }
        if !native {
            for (name, position) in [("Reveal", 1), ("HiddenBoundary", 2), ("AlwaysHiddenBoundary", 10_000)] {
                let key = "NSStatusItem Preferred Position MacWindowHide.\(name)"
                if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(position, forKey: key) }
            }
        }
        // New items are inserted on the left; create right-hand control first.
        let reveal = NSStatusBar.system.statusItem(withLength: 20)
        reveal.autosaveName = "MacWindowHide.Reveal"
        reveal.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Reveal hidden menu bar icons")
        reveal.button?.target = self; reveal.button?.action = #selector(clickedReveal)
        reveal.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        revealItem = reveal
        let hidden = NSStatusBar.system.statusItem(withLength: native ? 0 : 12)
        hidden.autosaveName = "MacWindowHide.HiddenBoundary"; hidden.button?.title = "│"
        hiddenDivider = hidden
        let always = NSStatusBar.system.statusItem(withLength: native ? 0 : 12)
        always.autosaveName = "MacWindowHide.AlwaysHiddenBoundary"; always.button?.title = "┆"
        alwaysDivider = always
    }

    @objc private func clickedReveal() {
        Task { @MainActor in
            do {
                if NSEvent.modifierFlags.contains(.option) { try await revealAll() }
                else if isCollapsed { try await revealHidden() }
                else { try await collapse() }
            } catch { lastError = error.localizedDescription; didChange?() }
        }
    }

    private func show(includeAlwaysHidden: Bool) async throws {
        ensureItems(); rehideTimer?.invalidate()
        if native {
            if includeAlwaysHidden {
                generation += 1
                if let assertion { MWHMenuBarInvalidate(assertion) }; assertion = nil
            } else {
                await refreshInventory()
                try await restrictNative(to: inventory.filter { $0.shelf != .alwaysHidden }.map(\.bundleID))
            }
        } else {
            hiddenDivider?.length = 12
            alwaysDivider?.length = includeAlwaysHidden ? 12 : min(max((NSScreen.screens.map { $0.frame.width }.max() ?? 1920) * 2, 500), 10_000)
        }
        isCollapsed = false
        revealItem?.button?.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Collapse menu bar icons")
        if !owners.isEmpty { scheduleRehide() }
        didChange?()
    }

    private func restrictNative(to bundles: [String]) async throws {
        generation += 1; let expected = generation
        let own = Bundle.main.bundleIdentifier.map { [$0] } ?? []
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            MWHMenuBarActivate(Array(Set(own + bundles))) { [weak self] handle, error in
                MainActor.assumeIsolated {
                    guard let self, self.generation == expected else {
                        if let handle { MWHMenuBarInvalidate(handle) }
                        continuation.resume(throwing: SwitchError.busy); return
                    }
                    if let handle {
                        let previous = self.assertion; self.assertion = handle
                        if let previous { MWHMenuBarInvalidate(previous) }
                        continuation.resume()
                    } else {
                        if let previous = self.assertion { MWHMenuBarInvalidate(previous) }; self.assertion = nil
                        self.isCollapsed = false
                        continuation.resume(throwing: error ?? SwitchError.unavailable("macOS could not hide menu bar items."))
                    }
                }
            }
        }
    }

    private func inferredShelf(_ rect: CGRect) -> MenuShelf {
        guard !rect.isNull, let h = hiddenDivider?.button?.window else { return .visible }
        let hidden = Self.quartzFrame(h.frame)
        if let always = alwaysDivider?.button?.window, rect.midX < Self.quartzFrame(always.frame).midX { return .alwaysHidden }
        return rect.midX < hidden.midX ? .hidden : .visible
    }

    private func startHoverMonitor() {
        revealItem?.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Reveal hidden menu bar icons")
        guard mouseMonitor == nil, settings?.preferences.menuBarHoverReveal == true else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pointerMoved() }
        }
    }
    private func pointerMoved() {
        guard isCollapsed, !owners.contains(.recording), settings?.preferences.menuBarHoverReveal == true else { return }
        let point = NSEvent.mouseLocation
        let overMenu = NSScreen.screens.contains { point.x >= $0.frame.minX && point.x <= $0.frame.maxX && point.y >= $0.visibleFrame.maxY && point.y <= $0.frame.maxY }
        if overMenu && hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }; self.hoverTimer = nil
                    do { try await self.revealHidden() } catch { self.lastError = error.localizedDescription }
                }
            }
        } else if !overMenu { hoverTimer?.invalidate(); hoverTimer = nil }
    }
    private func scheduleRehide() {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let point = NSEvent.mouseLocation
                if NSApp.isActive || NSScreen.screens.contains(where: { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }) { self.scheduleRehide(); return }
                do { try await self.collapse() } catch { self.lastError = error.localizedDescription }
            }
        }
    }
    private func stopHoverMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        hoverTimer?.invalidate(); hoverTimer = nil; rehideTimer?.invalidate(); rehideTimer = nil
    }

    private func moveDividerForRecording() throws {
        guard recordingDividerPosition == nil, let divider = hiddenDivider?.button?.window, let reveal = revealItem?.button?.window else { return }
        let from = Self.quartzFrame(divider.frame); let to = Self.quartzFrame(reveal.frame)
        recordingDividerPosition = CGPoint(x: from.midX, y: from.midY)
        try Self.drag(from: CGPoint(x: from.midX, y: from.midY), to: CGPoint(x: to.minX - 1, y: to.midY))
    }
    private func restoreRecordingDivider() {
        guard let destination = recordingDividerPosition, let current = hiddenDivider?.button?.window else { return }
        let frame = Self.quartzFrame(current.frame)
        try? Self.drag(from: CGPoint(x: frame.midX, y: frame.midY), to: destination)
        recordingDividerPosition = nil
    }
    private func restoreLegacyPositions(_ snapshot: ResourceSnapshot) {
        guard !native, snapshot.values["position.HiddenBoundary"] != nil else { return }
        for item in [hiddenDivider, alwaysDivider, revealItem].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        hiddenDivider = nil; alwaysDivider = nil; revealItem = nil
        for name in ["Reveal", "HiddenBoundary", "AlwaysHiddenBoundary"] {
            let key = "NSStatusItem Preferred Position MacWindowHide.\(name)"
            if let value = snapshot.values["position.\(name)"], let position = Double(value) { UserDefaults.standard.set(position, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        ensureItems()
    }
    private static func quartzFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY, width: frame.width, height: frame.height)
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?; var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private static func drag(from: CGPoint, to: CGPoint) throws {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left),
              let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: to, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) else { throw SwitchError.unavailable("Accessibility permission is required to move menu bar items.") }
        // Quartz delivers these in order; no shell automation or keyboard monitor.
        for event in [down, drag, up] { event.flags = .maskCommand; event.post(tap: .cghidEventTap) }
    }
}
