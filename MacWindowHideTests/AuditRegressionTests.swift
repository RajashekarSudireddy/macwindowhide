import XCTest
@testable import MacWindowHide

/// Regression tests for audit findings F1-F6 (27 October 2026). `GateSwitch` pauses inside `status()` or
/// `apply()` so coordinator interleavings can be forced deterministically without touching the OS.
@MainActor final class AuditRegressionTests: XCTestCase {
    private func make(_ ids: [SwitchID], countdown: Bool = false) -> (SettingsStore, [GateSwitch], MutationCoordinator, JournalStore) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacWindowHideTests-\(UUID().uuidString)")
        let settings = SettingsStore(directory: directory)
        settings.preferences.recordingSwitches = Set(ids.filter(\.supportsRecording))
        settings.preferences.switchOrder = ids
        settings.preferences.countdownEnabled = countdown
        let adapters = ids.map { GateSwitch(id: $0) }
        let store = JournalStore(directory: directory)
        return (settings, adapters, MutationCoordinator(adapters: adapters, settings: settings, journalStore: store), store)
    }
    private func waitFor(_ condition: () -> Bool, _ label: String) async throws {
        for _ in 0..<800 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for \(label)"); throw SwitchError.failed(label)
    }
    private func isBusyError(_ error: Error) -> Bool { if case SwitchError.busy = error { true } else { false } }

    // F1: a refresh during the countdown must not be able to clear the preparation guard.
    func testF1_RefreshDuringCountdownCannotReleasePreparationGuard() async throws {
        let (settings, a, c, store) = make([.dock, .darkMode], countdown: true)
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        let start = Task { await c.startRecording() }
        try await waitFor({ c.phase == .countdown }, "countdown")
        let refreshAccepted = await c.refresh()
        XCTAssertFalse(refreshAccepted, "A refresh during the countdown must be refused")
        a[1].gateApply = true
        try await waitFor({ a[1].waiting }, "darkMode apply gate (preparing)")
        XCTAssertEqual(c.phase, .preparing)
        let refreshDuringPreparation = await c.refresh()
        let stopDuringPreparation = await c.stopRecording()
        let recoverDuringPreparation = await c.recover()
        XCTAssertFalse(refreshDuringPreparation)
        XCTAssertFalse(stopDuringPreparation)
        XCTAssertFalse(recoverDuringPreparation)
        XCTAssertTrue(c.isBusy)
        a[1].release()
        let started = await start.value
        XCTAssertTrue(started)
        XCTAssertEqual(c.phase, .active)
        XCTAssertEqual(try store.load().changes.map(\.switchID), [.dock, .darkMode], "Every applied change is journaled")
        await c.stopRecording()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(a.contains(where: \.enabled))
        XCTAssertTrue(try store.load().changes.isEmpty)
    }

    // F2: Quit waits for an in-flight refresh and then restores, instead of exiting with changes applied.
    func testF2_ShutdownWaitsForInFlightRefreshThenRestores() async throws {
        let (settings, a, c, store) = make([.dock, .otherApps])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        settings.preferences.recordingSwitches = [.dock]
        await c.setSwitch(.otherApps, enabled: true)
        await c.startRecording()
        a[0].gateStatus = true
        let refresh = Task { await c.refresh() }
        try await waitFor({ a[0].waiting }, "status gate")
        let shutdown = Task { await c.shutdown() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(a[0].enabled, "Nothing is restored while another operation holds the guard")
        a[0].gateStatus = false; a[0].release(); _ = await refresh.value
        let mayQuit = await shutdown.value
        XCTAssertTrue(mayQuit)
        XCTAssertFalse(a[0].enabled)
        XCTAssertFalse(a[1].enabled)
        XCTAssertTrue(try store.load().changes.isEmpty)
    }

    // F2: when the in-flight operation does not finish, Quit reports failure rather than success.
    func testF2_ShutdownReportsFailureWhenOperationDoesNotFinish() async throws {
        let (settings, a, c, store) = make([.dock])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await c.startRecording()
        a[0].gateStatus = true
        let refresh = Task { await c.refresh() }
        try await waitFor({ a[0].waiting }, "status gate")
        let mayQuit = await c.shutdown(waitLimit: .milliseconds(100))
        XCTAssertFalse(mayQuit)
        XCTAssertNotNil(c.issue)
        XCTAssertTrue(a[0].enabled)
        XCTAssertEqual(try store.load().changes.count, 1)
        a[0].gateStatus = false; a[0].release(); _ = await refresh.value
        let retried = await c.shutdown()
        XCTAssertTrue(retried)
        XCTAssertFalse(a[0].enabled)
    }

    // F3 [A]: a Shortcut while another switch operation runs reports busy, not success.
    func testF3_BusySetControlRequestThrowsBusy() async throws {
        let (settings, a, c, _) = make([.darkMode, .dock])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        a[0].gateApply = true
        let first = Task { await c.setSwitch(.darkMode, enabled: true) }
        try await waitFor({ a[0].waiting }, "darkMode apply gate")
        do {
            try await AutomationRequest.setSwitch(c, .dock, enabled: true, foregroundPID: nil, waitLimit: .milliseconds(50))
            XCTFail("A dropped request must not report success")
        } catch { XCTAssertTrue(isBusyError(error), "\(error)") }
        XCTAssertEqual(a[1].applyCount, 0)
        a[0].release(); _ = await first.value
    }

    // F3: a short in-flight operation is waited for, so the request runs instead of being dropped.
    func testF3_SetControlRequestRunsAfterShortOperationFinishes() async throws {
        let (settings, a, c, _) = make([.darkMode, .dock])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        a[0].gateApply = true
        let first = Task { await c.setSwitch(.darkMode, enabled: true) }
        try await waitFor({ a[0].waiting }, "darkMode apply gate")
        let request = Task { try await AutomationRequest.setSwitch(c, .dock, enabled: true, foregroundPID: nil) }
        try await Task.sleep(for: .milliseconds(50))
        a[0].release(); _ = await first.value
        try await request.value
        XCTAssertTrue(a[1].enabled)
    }

    // F3: a stale issue from an earlier failure is not reported for an unrelated dropped request.
    func testF3_StaleIssueIsNotReportedForDroppedRequest() async throws {
        let (settings, a, c, _) = make([.darkMode, .dock])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        a[0].gateApply = true
        let first = Task { await c.setSwitch(.darkMode, enabled: true) }
        try await waitFor({ a[0].waiting }, "darkMode apply gate")
        c.issue = "An old, unrelated failure"
        do {
            try await AutomationRequest.setSwitch(c, .dock, enabled: true, foregroundPID: nil, waitLimit: .milliseconds(50))
            XCTFail("A dropped request must not report success")
        } catch {
            XCTAssertTrue(isBusyError(error), "\(error)")
            XCTAssertFalse(error.localizedDescription.contains("old, unrelated"))
        }
        a[0].release(); _ = await first.value
    }

    // F3 [B]: Restore Recording Mode during the periodic refresh reports busy; recording stays active.
    func testF3_BusyStopRecordingRequestThrowsBusy() async throws {
        let (settings, a, c, _) = make([.dock])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await c.startRecording()
        a[0].gateStatus = true
        let refresh = Task { await c.refresh() }
        try await waitFor({ a[0].waiting }, "status gate")
        do {
            try await AutomationRequest.stopRecording(c, waitLimit: .milliseconds(50))
            XCTFail("A dropped restore must not report success")
        } catch { XCTAssertTrue(isBusyError(error), "\(error)") }
        XCTAssertEqual(c.phase, .active)
        a[0].gateStatus = false; a[0].release(); _ = await refresh.value
        try await AutomationRequest.stopRecording(c)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(a[0].enabled)
    }

    // F3 [H]: on cold launch before recovery runs, a control request fails instead of reporting success.
    func testF3_SetControlBeforeRecoveryFails() async throws {
        let (settings, a, _, store) = make([.dock, .darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        var journal = MutationJournal(); journal.session = RecordingJournalSession(foregroundPID: nil)
        try store.save(journal)
        let relaunched = MutationCoordinator(adapters: a, settings: settings, journalStore: store)
        XCTAssertEqual(relaunched.phase, .recoveryNeeded)
        do {
            try await AutomationRequest.setSwitch(relaunched, .darkMode, enabled: true, foregroundPID: nil, waitLimit: .milliseconds(50))
            XCTFail("A refused request must not report success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("restoration"), "\(error)") }
        XCTAssertEqual(a[1].applyCount, 0)
    }

    // F4 [I]: the popover's Retry restoration runs full recovery, including standalone transients.
    func testF4_RetryRestorationRecoversStandaloneChanges() async throws {
        let (settings, a, c, store) = make([.otherApps])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await c.setSwitch(.otherApps, enabled: true)
        a[0].failRestore = true
        let failedQuit = await c.shutdown()
        XCTAssertFalse(failedQuit)
        XCTAssertEqual(c.phase, .recoveryNeeded)
        a[0].failRestore = false
        await c.toggleRecording()          // what the popover's "Retry restoration" button calls
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(a[0].enabled)
        XCTAssertTrue(try store.load().changes.isEmpty)
    }

    // F4 [J]: retry does not clear recoveryNeeded while an unresolved standalone record remains.
    func testF4_RetryRestorationReconcilesPreparedStandaloneRecord() async throws {
        let (settings, a, _, store) = make([.dock, .darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        var journal = MutationJournal(); journal.session = RecordingJournalSession(foregroundPID: nil)
        journal.changes = [
            JournalChange(switchID: .darkMode, owner: .standalone, original: ResourceSnapshot(["enabled": "false", "value": "initial"]), requestedEnabled: true),
            JournalChange(switchID: .dock, owner: .recording, original: ResourceSnapshot(["enabled": "false", "value": "initial"]), requestedEnabled: true),
        ]
        try store.save(journal)
        a[0].enabled = true; a[0].value = "on"; a[1].enabled = true; a[1].value = "on"
        let relaunched = MutationCoordinator(adapters: a, settings: settings, journalStore: store)
        XCTAssertEqual(relaunched.phase, .recoveryNeeded)
        await relaunched.toggleRecording()
        XCTAssertEqual(relaunched.phase, .idle)
        XCTAssertFalse(a[0].enabled)
        XCTAssertFalse(a[1].enabled, "The prepared standalone Dark Mode change is restored")
        XCTAssertTrue(try store.load().changes.isEmpty)
    }

    // F5 [K]: once a retried Quit restores everything, Quit is allowed again.
    func testF5_SuccessfulRetryShutdownClearsRecoveryNeeded() async throws {
        let (settings, a, c, store) = make([.otherApps])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await c.setSwitch(.otherApps, enabled: true)
        a[0].failRestore = true
        let first = await c.shutdown()
        XCTAssertFalse(first)
        a[0].failRestore = false
        let second = await c.shutdown()
        XCTAssertTrue(second)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNil(c.issue)
        XCTAssertTrue(try store.load().changes.isEmpty)
    }

    // F5 [L]: an unreadable journal does not trap the app, and Quit leaves the file byte-for-byte intact.
    func testF5_UnreadableJournalAllowsQuitAndPreservesEvidence() async throws {
        let (settings, a, _, store) = make([.dock])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        try FileManager.default.createDirectory(at: settings.directory, withIntermediateDirectories: true)
        let corrupt = Data("{".utf8)
        try corrupt.write(to: store.fileURL)
        let c = MutationCoordinator(adapters: a, settings: settings, journalStore: store)
        await c.recover()
        await c.setSwitch(.dock, enabled: true)
        XCTAssertEqual(a[0].applyCount, 0, "Mutations stay blocked")
        let mayQuit = await c.shutdown()
        XCTAssertTrue(mayQuit)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
        XCTAssertEqual(a[0].restoreCount, 0)
    }

    // F6 [E]: a clock deadline that has passed means the same time at its next occurrence.
    func testF6_KeepAwakeClockModeUsesNextOccurrenceOfStoredTime() async throws {
        let (settings, a, c, _) = make([.keepAwake])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        settings.preferences.awakeTimerMode = .clock
        let stale = Date().addingTimeInterval(-3600 - 86_400 * 3)
        settings.preferences.awakeUntil = stale
        await c.setSwitch(.keepAwake, enabled: true)
        let deadline = try XCTUnwrap(c.timers[.keepAwake])
        XCTAssertGreaterThan(deadline, Date())
        XCTAssertLessThanOrEqual(deadline, Date().addingTimeInterval(86_400))
        let calendar = Calendar.current
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: deadline), calendar.dateComponents([.hour, .minute], from: stale))
        await c.tick()
        XCTAssertTrue(a[0].enabled)
        XCTAssertNil(c.issue)
    }

    // F6: a future clock deadline is still used exactly as chosen.
    func testF6_KeepAwakeClockModeKeepsFutureDate() async throws {
        let (settings, _, c, _) = make([.keepAwake])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        settings.preferences.awakeTimerMode = .clock
        let future = Date().addingTimeInterval(86_400 * 2).rounded()
        settings.preferences.awakeUntil = future
        await c.setSwitch(.keepAwake, enabled: true)
        XCTAssertEqual(c.timers[.keepAwake]?.timeIntervalSince1970 ?? 0, future.timeIntervalSince1970, accuracy: 0.001)
    }
}

private extension Date {
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}

@MainActor private final class GateSwitch: SystemSwitchAdapter {
    let id: SwitchID
    var enabled = false
    var value = "initial"
    var applyCount = 0
    var restoreCount = 0
    var failRestore = false
    var gateStatus = false
    var gateApply = false
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(id: SwitchID) { self.id = id }
    func release() { waiting = false; let c = continuation; continuation = nil; c?.resume() }
    private func gate() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func capability() async -> SwitchCapability { .available }
    func status() async -> SwitchStatus {
        if gateStatus && continuation == nil { await gate() }
        return SwitchStatus(state: enabled ? .on : .off)
    }
    func snapshot() async throws -> ResourceSnapshot { ResourceSnapshot(["enabled": String(enabled), "value": value]) }
    func apply(enabled: Bool, context: ActionContext) async throws {
        if gateApply { gateApply = false; await gate() }
        applyCount += 1
        self.enabled = enabled
        value = enabled ? "on" : "off"
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {
        restoreCount += 1
        if failRestore { throw SwitchError.failed("simulated restore failure") }
        enabled = snapshot.enabled
        value = snapshot.values["value"] ?? "initial"
    }
}
