import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

/// Event filtering never waits for AppKit. Releasing this state immediately makes the tap pass events.
final class KeyboardSafetyState: @unchecked Sendable {
    private let mutex = NSLock()
    private var active = true
    private var escapeDown: TimeInterval?
    private var escapeGeneration = 0
    let deadline: TimeInterval
    private let released: @Sendable () -> Void
    init(duration: TimeInterval = 60, now: TimeInterval = ProcessInfo.processInfo.systemUptime, released: @escaping @Sendable () -> Void) {
        deadline = now + duration
        self.released = released
    }
    var isActive: Bool { mutex.lock(); defer { mutex.unlock() }; return active }
    @discardableResult func release() -> Bool {
        mutex.lock()
        let changed = active
        active = false
        escapeDown = nil
        mutex.unlock()
        if changed { released() }
        return changed
    }
    func check(now: TimeInterval = ProcessInfo.processInfo.systemUptime, permission: Bool = true, sessionLocked: Bool = false) {
        mutex.lock()
        let mustRelease = active && (!permission || sessionLocked || now >= deadline || escapeDown.map { now - $0 >= 3 } == true)
        mutex.unlock()
        if mustRelease { release() }
    }
    /// Returns true only when the system should receive the key.
    func key(down: Bool, escape: Bool, repeatEvent: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        mutex.lock()
        guard active else { mutex.unlock(); return true }
        if escape {
            if down && !repeatEvent && escapeDown == nil {
                escapeDown = now
                escapeGeneration += 1
                let generation = escapeGeneration
                mutex.unlock()
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    self.mutex.lock()
                    let held = self.active && self.escapeGeneration == generation && self.escapeDown != nil
                    self.mutex.unlock()
                    if held { self.release() }
                }
                return false
            }
            if !down { escapeDown = nil; escapeGeneration += 1 }
        }
        mutex.unlock()
        check(now: now)
        return !isActive
    }
}

private final class KeyboardTapWorker: @unchecked Sendable {
    let safety: KeyboardSafetyState
    private let mutex = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)
    private var didStart = false
    init(safety: KeyboardSafetyState) { self.safety = safety }
    func start() -> Bool {
        let thread = Thread { [self] in run() }
        thread.name = "MacWindowHide.KeyboardSafety"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard started.wait(timeout: .now() + 2) == .success else { stop(); return false }
        mutex.lock(); defer { mutex.unlock() }
        return didStart
    }
    private func run() {
        // NX_SYSDEFINED (14) carries media keys and is deliberately filtered with ordinary keys.
        let mask = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let worker = Unmanaged<KeyboardTapWorker>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { worker.safety.release(); return Unmanaged.passUnretained(event) }
            guard worker.safety.isActive else { return Unmanaged.passUnretained(event) }
            let escape = event.getIntegerValueField(.keyboardEventKeycode) == 53
            let pass = worker.safety.key(down: type == .keyDown, escape: escape && (type == .keyDown || type == .keyUp), repeatEvent: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            return pass ? Unmanaged.passUnretained(event) : nil
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else { started.signal(); safety.release(); return }
        let loop = CFRunLoopGetCurrent()
        mutex.lock()
        tap = created; runLoop = loop; didStart = safety.isActive
        mutex.unlock()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0) { [weak self] _ in
            guard let self else { return }
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
            self.safety.check(permission: AXIsProcessTrusted() && !IsSecureEventInputEnabled(), sessionLocked: locked)
            if !self.safety.isActive { self.stop() }
        }
        CFRunLoopAddTimer(loop, timer, .commonModes)
        started.signal()
        if safety.isActive { CFRunLoopRun() }
        CGEvent.tapEnable(tap: created, enable: false)
        CFMachPortInvalidate(created)
        CFRunLoopRemoveTimer(loop, timer, .commonModes)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        mutex.lock(); tap = nil; runLoop = nil; mutex.unlock()
    }
    func stop() {
        safety.release()
        mutex.lock()
        let currentTap = tap, loop = runLoop
        mutex.unlock()
        if let currentTap { CGEvent.tapEnable(tap: currentTap, enable: false); CFMachPortInvalidate(currentTap) }
        if let loop { CFRunLoopStop(loop) }
    }
}

@MainActor final class KeyboardLockController: ObservableObject {
    static let shared = KeyboardLockController()
    @Published private(set) var isLocked = false
    @Published private(set) var remainingSeconds = 60
    private var worker: KeyboardTapWorker?
    private var panels: [NSPanel] = []
    private var countdown: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var screensObserver: NSObjectProtocol?
    private var generation = UUID()
    var hasPermission: Bool { AXIsProcessTrusted() }
    func requestPermission() { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    func lock() throws {
        guard !isLocked else { return }
        guard hasPermission else { throw SwitchError.unavailable("Allow Accessibility access before locking the keyboard.") }
        guard !IsSecureEventInputEnabled() else { throw SwitchError.unavailable("Finish secure text entry before locking the keyboard.") }
        let token = UUID()
        generation = token
        let safety = KeyboardSafetyState {
            Task { @MainActor in
                let controller = KeyboardLockController.shared
                if controller.generation == token { controller.unlock() }
            }
        }
        let worker = KeyboardTapWorker(safety: safety)
        self.worker = worker
        guard worker.start() else { self.worker = nil; throw SwitchError.unavailable("macOS could not start the keyboard filter. Check Accessibility permission.") }
        isLocked = true; remainingSeconds = 60
        showPanels()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KeyboardLockController.shared.unlock() }
            })
        }
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let controller = KeyboardLockController.shared
                guard controller.isLocked else { return }
                controller.closePanels(); controller.showPanels()
            }
        }
        countdown = Task { [weak self] in
            while !Task.isCancelled, let self, self.isLocked {
                self.remainingSeconds = max(0, Int(ceil(safety.deadline - ProcessInfo.processInfo.systemUptime)))
                if self.remainingSeconds == 0 || !safety.isActive { self.unlock(); return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    private func showPanels() {
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false; panel.backgroundColor = NSColor.black.withAlphaComponent(0.28)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: KeyboardUnlockView(controller: self))
            panel.orderFrontRegardless(); panels.append(panel)
        }
    }
    private func closePanels() { for panel in panels { panel.orderOut(nil) }; panels.removeAll() }
    func unlock() {
        isLocked = false
        let activeWorker = worker; worker = nil
        activeWorker?.stop()
        countdown?.cancel(); countdown = nil
        closePanels()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
    }
}

private struct KeyboardUnlockView: View {
    @ObservedObject var controller: KeyboardLockController
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard").font(.system(size: 36))
            Text("Keyboard locked").font(.title2.weight(.semibold))
            Text("Unlocking in \(controller.remainingSeconds)s").monospacedDigit().font(.headline)
            Text("The mouse still works. Hold Escape for 3 seconds to unlock.").font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Unlock keyboard") { controller.unlock() }.buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(32).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .contain)
    }
}

@MainActor final class KeyboardLockAdapter: SystemSwitchAdapter {
    let id: SwitchID = .keyboardLock
    func capability() async -> SwitchCapability { KeyboardLockController.shared.hasPermission ? .available : .needsPermission("Allow Accessibility to filter keyboard input.") }
    func status() async -> SwitchStatus {
        guard KeyboardLockController.shared.hasPermission else { return SwitchStatus(state: .needsPermission, detail: "Allow Accessibility before locking the keyboard.") }
        return SwitchStatus(state: KeyboardLockController.shared.isLocked ? .on : .off, detail: "Mouse unlock · hold Escape 3 seconds · 60-second limit")
    }
    func snapshot() async throws -> ResourceSnapshot { ResourceSnapshot(enabled: KeyboardLockController.shared.isLocked) }
    func apply(enabled: Bool, context: ActionContext) async throws { if enabled { try KeyboardLockController.shared.lock() } else { KeyboardLockController.shared.unlock() } }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws { KeyboardLockController.shared.unlock() }
    func shutdown() { KeyboardLockController.shared.unlock() }
}
