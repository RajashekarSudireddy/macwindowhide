import AppKit
import Combine
import SwiftUI

@main struct MacWindowHideMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var quitting = false
    private var terminationTask: Task<Void, Never>?
    private var model: AppModel { .shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Controls", action: #selector(showPanel), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacWindowHide", action: #selector(quitApp), keyEquivalent: "q")
        for item in appMenu.items { item.target = self }
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        menu.addItem(appMenuItem)
        NSApp.mainMenu = menu
        if UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position MacWindowHide.Main") == nil {
            UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position MacWindowHide.Main")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MacWindowHide.Main"
        item.behavior = [.removalAllowed]
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: ControlPanel(model: model, settings: model.settings, coordinator: model.coordinator))
        model.showSettingsHandler = { [weak self] in self?.openSettings() }
        model.closePanelHandler = { [weak self] in self?.popover.performClose(nil) }
        model.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.updateStatus() } }.store(in: &subscriptions)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        updateStatus()
        if ProcessInfo.processInfo.arguments.contains("--integration-smoke-test") { Task { await integrationSmokeTest() }; return }
        if ProcessInfo.processInfo.arguments.contains("--quit-smoke-test") { Task { model.quit() }; return }
        model.start()
        if ProcessInfo.processInfo.arguments.contains("--show-settings") { openSettings() }
        else if ProcessInfo.processInfo.arguments.contains("--show-panel") { showPanel() }
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            Task { await model.toggleRecording() }
        } else if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: model.coordinator.isRecording ? "Restore Recording Mode" : "Start Recording Mode", action: #selector(toggleRecording), keyEquivalent: "")
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "")
            for item in menu.items { item.target = self }
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }
    @objc private func showPanel() {
        guard statusItem?.isVisible == true, let button = statusItem?.button,
              let window = button.window, window.isVisible,
              !button.isHiddenOrHasHiddenAncestor, button.visibleRect.intersects(button.bounds) else {
            showControlsUnavailable()
            return
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { model.foregroundPID = front.processIdentifier }
        let available = (window.screen?.visibleFrame.height ?? 800) - 35
        let height = min(650, max(420, available))
        popover.contentSize = NSSize(width: 360, height: height)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else {
            showControlsUnavailable()
            return
        }
        popover.contentViewController?.view.window?.title = "MacWindowHide Controls"
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.coordinator.refresh() }
    }
    private func showControlsUnavailable() {
        openSettings()
        model.message = "MacWindowHide's menu bar icon is not currently visible. Show the icon again in the macOS menu bar settings, then choose Show Controls."
    }
    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let recording = model.coordinator.isRecording
        let image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "rectangle.on.rectangle.slash", accessibilityDescription: "MacWindowHide")
        image?.isTemplate = !recording
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
        button.title = recording ? " \(model.elapsed)" : ""
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.toolTip = recording ? "Recording Mode · \(model.elapsed) · Option-click to restore" : "MacWindowHide · Option-click for Recording Mode"
        button.setAccessibilityLabel("MacWindowHide")
    }
    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "MacWindowHide Settings"
            window.minSize = NSSize(width: 760, height: 600)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppSettingsView(model: model, settings: model.settings, coordinator: model.coordinator))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleRecording() { Task { await model.toggleRecording() } }
    @objc private func quitApp() { model.quit() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        guard NSClassFromString("XCTestCase") == nil else { return .terminateNow }
        guard terminationTask == nil else { return .terminateCancel }
        guard !model.coordinator.isBusy || model.coordinator.phase == .countdown else {
            model.message = "Wait for the current operation to finish before quitting."
            return .terminateCancel
        }
        terminationTask = Task {
            if !(await model.prepareToQuit()) {
                terminationTask = nil
                openSettings()
                model.message = "Some settings could not be restored. Retry recovery before quitting; the journal remains on disk."
            } else {
                quitting = true
                sender.terminate(nil)
            }
        }
        // terminateLater runs a modal loop that can stall Swift main-actor tasks.
        return .terminateCancel
    }
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw), url.scheme == "macwindowhide" else { return }
        // URL actions are deliberately limited to navigation. System mutations use App Intents.
        if url.host == "settings" { openSettings() }
    }

    private func integrationSmokeTest() async {
        model.settings.preferences.recordingSwitches = [.desktopIcons, .backdrop, .keepAwake]
        model.settings.preferences.countdownEnabled = false
        await model.coordinator.recover()
        await model.coordinator.startRecording(foregroundPID: model.foregroundPID)
        let started = model.coordinator.isRecording
        let activeIssue = model.coordinator.issue
        try? await Task.sleep(for: .seconds(2))
        await model.coordinator.stopRecording()
        let restored = model.coordinator.phase == .idle
        let report: [String: Any] = ["started": started, "restored": restored, "activeIssue": activeIssue ?? "", "restoreIssue": model.coordinator.issue ?? "", "controls": ["desktopIcons", "backdrop", "keepAwake"]]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { FileHandle.standardOutput.write(data) }
        quitting = true
        NSApp.terminate(nil)
    }
}
