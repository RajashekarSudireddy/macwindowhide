import AppKit
import Combine
import CoreImage

enum BackdropPalette {
    static let hexes: [[String]] = [
        ["#AAD2E6", "#47678C", "#D1BDDE"], ["#D7B5CB", "#705D9C", "#B2D9DC"], ["#F3C5A2", "#D97878", "#EAD69F"],
        ["#DDE7C5", "#548A78", "#B3CBDD"], ["#F8E2A2", "#C59A65", "#D5BACD"], ["#A3C8D5", "#2C546D", "#A3B9BA"],
        ["#E6C8E0", "#AC7FA8", "#C8D5E8"], ["#ACC4B6", "#465C55", "#CAD3A4"], ["#F5DAD2", "#BC898F", "#DDC3A7"],
        ["#B8C5EC", "#6178B4", "#D3BADE"], ["#DDD6C8", "#8F887E", "#B5C8BE"], ["#B6DDD8", "#497D82", "#A9BFE0"],
        ["#E6CC9F", "#AB785E", "#E5AF9F"], ["#C8C9DE", "#666A8E", "#B7D4D6"]
    ]
    @MainActor static func colors(for index: Int) -> [NSColor] { hexes[abs(index % hexes.count)].map(NSColor.init(hex:)) }
}

@MainActor final class BackdropController: ObservableObject {
    static let shared = BackdropController()
    @Published private(set) var isEnabled = false
    private weak var settings: SettingsStore?
    private var windows: [NSWindow] = []
    private var desktopWindows: [NSWindow] = []
    private var backdropOwners: Set<ActionOwner> = []
    private var desktopOwners: Set<ActionOwner> = []
    private var observation: NSObjectProtocol?
    private var timer: Timer?
    private var foregroundPID: pid_t?
    private var lastTarget: CGWindowID?

    func configure(settings: SettingsStore) { self.settings = settings }
    var desktopHidden: Bool { !desktopOwners.isEmpty }
    var hasVisibleBackdrop: Bool { windows.contains { $0.isVisible } }
    func backdropActive(for owner: ActionOwner) -> Bool { backdropOwners.contains(owner) }
    func desktopActive(for owner: ActionOwner) -> Bool { desktopOwners.contains(owner) }

    func setDesktopHidden(_ hidden: Bool, owner: ActionOwner) {
        if hidden { desktopOwners.insert(owner) } else { desktopOwners.remove(owner) }
        if desktopOwners.isEmpty { desktopWindows.forEach { $0.close() }; desktopWindows.removeAll() }
        else { rebuildDesktop() }
        updateObservation()
    }

    func setEnabled(_ enabled: Bool, context: ActionContext) throws {
        if enabled {
            if settings?.preferences.backdropStyle == .image,
               NSImage(contentsOfFile: settings?.preferences.backdropImagePath ?? "") == nil {
                throw SwitchError.unavailable("Choose an accessible image in Backdrop settings first.")
            }
            if let pid = context.foregroundPID, pid != ProcessInfo.processInfo.processIdentifier { foregroundPID = pid }
            if foregroundPID == nil { foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier }
            guard targetWindow() != nil else { throw SwitchError.unavailable("Bring the window you want to show to the front, then enable Backdrop.") }
            backdropOwners.insert(context.owner)
            isEnabled = true
            renderBackdrop()
        } else {
            backdropOwners.remove(context.owner)
            isEnabled = !backdropOwners.isEmpty
            if !isEnabled { windows.forEach { $0.close() }; windows.removeAll(); lastTarget = nil }
        }
        updateObservation()
    }

    func refreshAppearance() {
        if desktopHidden { rebuildDesktop() }
        if isEnabled { renderBackdrop(force: true) }
    }

    func shutdown() {
        backdropOwners.removeAll(); desktopOwners.removeAll(); isEnabled = false
        windows.forEach { $0.close() }; desktopWindows.forEach { $0.close() }
        windows.removeAll(); desktopWindows.removeAll()
        timer?.invalidate(); timer = nil
        if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
        observation = nil
    }

    private func updateObservation() {
        guard isEnabled || desktopHidden else {
            timer?.invalidate(); timer = nil
            if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
            observation = nil
            return
        }
        if observation == nil {
            observation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = application.processIdentifier
                Task { @MainActor [weak self] in
                    guard pid != ProcessInfo.processInfo.processIdentifier else { return }
                    self?.foregroundPID = pid
                    self?.renderBackdrop(force: true)
                }
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.desktopHidden && (self.desktopWindows.count != NSScreen.screens.count || zip(self.desktopWindows, NSScreen.screens).contains(where: { $0.frame != $1.frame })) { self.rebuildDesktop() }
                    self.renderBackdrop()
                }
            }
        }
    }

    private func targetWindow() -> (CGWindowID, CGRect)? {
        guard let pid = foregroundPID,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary), bounds.width > 80, bounds.height > 60 else { continue }
            return (number, bounds)
        }
        return nil
    }

    private func makeWindow(on screen: NSScreen, desktop: Bool) -> NSWindow {
        let window = QuietCoverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = !desktop
        window.level = desktop ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1) : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = CoverView(frame: CGRect(origin: .zero, size: screen.frame.size), preferences: settings?.preferences ?? AppPreferences(), wallpaper: NSWorkspace.shared.desktopImageURL(for: screen), desktop: desktop)
        return window
    }

    private func rebuildDesktop() {
        desktopWindows.forEach { $0.close() }
        desktopWindows = NSScreen.screens.map { makeWindow(on: $0, desktop: true) }
        desktopWindows.forEach { $0.orderFrontRegardless() }
    }

    private func renderBackdrop(force: Bool = false) {
        guard isEnabled else { return }
        guard let (target, _) = targetWindow() else {
            // A windowless app cannot be isolated safely. Do not cover its screen.
            windows.forEach { $0.orderOut(nil) }; lastTarget = nil
            return
        }
        let geometryChanged = windows.count != NSScreen.screens.count || zip(windows, NSScreen.screens).contains { $0.frame != $1.frame }
        if force || geometryChanged || windows.isEmpty {
            windows.forEach { $0.close() }
            windows = NSScreen.screens.map { makeWindow(on: $0, desktop: false) }
        }
        if force || geometryChanged || target != lastTarget || windows.contains(where: { !$0.isVisible }) {
            for window in windows { window.order(.below, relativeTo: Int(target)) }
            lastTarget = target
        }
    }
}

@MainActor private final class QuietCoverWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class CoverView: NSView {
    private let preferences: AppPreferences
    private let wallpaper: URL?
    private let desktop: Bool
    private var image: NSImage?

    init(frame: NSRect, preferences: AppPreferences, wallpaper: URL?, desktop: Bool) {
        self.preferences = preferences; self.wallpaper = wallpaper; self.desktop = desktop
        super.init(frame: frame)
        if desktop || preferences.backdropStyle == .wallpaper { image = wallpaper.flatMap { NSImage(contentsOf: $0) } }
        if !desktop && preferences.backdropStyle == .image { image = NSImage(contentsOfFile: preferences.backdropImagePath) }
        if !desktop, preferences.backdropBlur > 0, let source = image?.tiffRepresentation, let input = CIImage(data: source) {
            let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: preferences.backdropBlur]).cropped(to: input.extent)
            if let cg = CIContext().createCGImage(blurred, from: input.extent) { image = NSImage(cgImage: cg, size: input.extent.size) }
        }
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {} // Prevent wallpaper clicks from invoking Show Desktop.
    override func rightMouseDown(with event: NSEvent) {}
    override func draw(_ dirtyRect: NSRect) {
        let palette = BackdropPalette.colors(for: preferences.backdropPreset)
        let first = palette[0]; let second = palette[1]
        if let image {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            let scale = max(bounds.width / max(image.size.width, 1), bounds.height / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
        } else if desktop {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
        } else {
            switch preferences.backdropStyle {
            case .color: first.setFill(); bounds.fill()
            case .custom: NSColor(hex: preferences.customColorHex).setFill(); bounds.fill()
            case .mesh:
                NSGradient(starting: first, ending: second)?.draw(in: bounds, angle: 35)
                let blobs: [(NSColor, CGFloat, CGFloat, CGFloat)] = [(palette[2], 0.18, 0.82, 0.85), (first, 0.85, 0.72, 0.75), (second, 0.48, 0.05, 0.8)]
                for (color, x, y, radius) in blobs {
                    let center = NSPoint(x: bounds.width * x, y: bounds.height * y)
                    NSGradient(colors: [color.withAlphaComponent(0.95), color.withAlphaComponent(0.65), color.withAlphaComponent(0)])?.draw(fromCenter: center, radius: 0, toCenter: center, radius: max(bounds.width, bounds.height) * radius, options: [])
                }
            default: NSGradient(starting: first, ending: second)?.draw(in: bounds, angle: 35)
            }
        }
        if !desktop { NSColor.black.withAlphaComponent(min(max(preferences.backdropDim, 0), 1)).setFill(); bounds.fill() }
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(raw, radix: 16) ?? 0x527D91
        self.init(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}
