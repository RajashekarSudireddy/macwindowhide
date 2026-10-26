import XCTest
@testable import MacWindowHide

@MainActor final class MutationCoordinatorTests: XCTestCase {
    private func fixture(_ ids: [SwitchID]) -> (SettingsStore, [FakeSwitch], MutationCoordinator, JournalStore) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacWindowHideTests-\(UUID().uuidString)")
        let settings = SettingsStore(directory: directory)
        settings.preferences.recordingSwitches = Set(ids)
        settings.preferences.switchOrder = ids
        let adapters = ids.map { FakeSwitch(id: $0) }
        let store = JournalStore(directory: directory)
        return (settings, adapters, MutationCoordinator(adapters: adapters, settings: settings, journalStore: store), store)
    }

    func testRecordingRestoresOriginalValuesInReverseOrder() async {
        let (settings, adapters, coordinator, _) = fixture([.dock, .darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        let log = EventLog()
        adapters.forEach { $0.log = log }
        await coordinator.startRecording(foregroundPID: 42)
        XCTAssertEqual(coordinator.phase, .active)
        XCTAssertTrue(adapters.allSatisfy(\.enabled))
        await coordinator.stopRecording()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(adapters.contains(where: \.enabled))
        XCTAssertEqual(log.events, ["dock.apply.true", "darkMode.apply.true", "darkMode.restore", "dock.restore"])
        XCTAssertEqual(adapters[0].lastContext?.foregroundPID, 42)
    }

    func testUnavailableSelectedSwitchAbortsBeforeAnyMutation() async {
        let (settings, adapters, coordinator, _) = fixture([.dock, .darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        adapters[1].availability = .needsPermission("Automation permission is required.")
        await coordinator.startRecording()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(adapters.contains(where: \.enabled))
        XCTAssertEqual(adapters[0].applyCount, 0)
        XCTAssertTrue(coordinator.issue?.contains("Automation permission") == true)
    }

    func testChangedExternalValueIsNeverOverwrittenOnStop() async {
        let (settings, adapters, coordinator, _) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await coordinator.startRecording()
        adapters[0].value = "user-value"
        await coordinator.stopRecording()
        XCTAssertEqual(adapters[0].value, "user-value")
        XCTAssertEqual(adapters[0].restoreCount, 0)
    }

    func testDetectedExternalChangeRelinquishesOwnershipEvenAfterValueReturns() async {
        let (settings, adapters, coordinator, _) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await coordinator.startRecording()
        adapters[0].value = "user-value"
        await coordinator.refresh()
        adapters[0].value = "on"
        await coordinator.stopRecording()
        XCTAssertTrue(adapters[0].enabled)
        XCTAssertEqual(adapters[0].restoreCount, 0)
    }

    func testManualChangeDuringRecordingIsPreserved() async {
        let (settings, adapters, coordinator, _) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await coordinator.startRecording()
        await coordinator.setSwitch(.darkMode, enabled: false)
        await coordinator.stopRecording()
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertEqual(adapters[0].value, "off")
    }

    func testFailedSecondApplyRollsBackBothResources() async {
        let (settings, adapters, coordinator, _) = fixture([.dock, .darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        adapters[1].failAfterApplying = true
        await coordinator.startRecording()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(adapters.contains(where: \.enabled))
        XCTAssertTrue(coordinator.issue?.contains("simulated apply failure") == true)
    }

    func testJournalFailureAfterMutationRollsBackUsingPreparedRecord() async {
        let (settings, adapters, coordinator, store) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        var writes = 0
        store.beforeSave = {
            writes += 1
            if writes == 3 { throw SwitchError.failed("simulated disk failure") }
        }
        await coordinator.startRecording()
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(coordinator.issue?.contains("simulated disk failure") == true)
        XCTAssertTrue((try? store.load().changes.isEmpty) == true)
    }

    func testJournalFailureBeforeMutationPreventsOSChange() async {
        let (settings, adapters, coordinator, store) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        store.beforeSave = { throw SwitchError.failed("disk full") }
        await coordinator.startRecording()
        XCTAssertEqual(adapters[0].applyCount, 0)
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertNotNil(coordinator.issue)
    }

    func testLaunchRecoversPreparedOperationWhenApplyWasNotAcknowledged() async throws {
        let (settings, adapters, _, store) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        let original = try await adapters[0].snapshot()
        var journal = MutationJournal()
        journal.session = RecordingJournalSession(foregroundPID: nil)
        journal.changes = [JournalChange(switchID: .darkMode, owner: .recording, original: original, requestedEnabled: true)]
        try store.save(journal)
        adapters[0].enabled = true
        adapters[0].value = "on"
        let relaunched = MutationCoordinator(adapters: adapters, settings: settings, journalStore: store)
        await relaunched.recover()
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertEqual(adapters[0].value, "initial")
        XCTAssertEqual(relaunched.phase, .idle)
        XCTAssertNil(try store.load().session)
    }

    func testCorruptJournalBlocksMutationAndPreservesSystemState() async throws {
        let (settings, adapters, _, store) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        try FileManager.default.createDirectory(at: settings.directory, withIntermediateDirectories: true)
        try Data("not valid JSON".utf8).write(to: store.fileURL)
        let coordinator = MutationCoordinator(adapters: adapters, settings: settings, journalStore: store)
        await coordinator.recover()
        await coordinator.setSwitch(.darkMode, enabled: true)
        XCTAssertEqual(coordinator.phase, .recoveryNeeded)
        XCTAssertEqual(adapters[0].applyCount, 0)
        XCTAssertNotNil(coordinator.issue)
    }

    func testExpiredStandaloneTimerDefersUntilRecordingStops() async {
        let (settings, adapters, coordinator, _) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        settings.preferences.autoOffMinutes[SwitchID.darkMode.rawValue] = 30
        await coordinator.setSwitch(.darkMode, enabled: true)
        await coordinator.scheduleAutoOff(.darkMode, date: Date().addingTimeInterval(-1))
        await coordinator.startRecording()
        await coordinator.tick()
        XCTAssertTrue(adapters[0].enabled)
        await coordinator.stopRecording()
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertNil(coordinator.timers[.darkMode])
    }

    func testRestoreFailureRemainsDurableAndCanBeRetried() async throws {
        let (settings, adapters, coordinator, store) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await coordinator.startRecording()
        adapters[0].failRestore = true
        await coordinator.stopRecording()
        XCTAssertEqual(coordinator.phase, .recoveryNeeded)
        XCTAssertEqual(try store.load().changes.count, 1)
        adapters[0].failRestore = false
        await coordinator.recover()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertTrue(try store.load().changes.isEmpty)
    }

    func testFailedAtomicSavePreservesPreviousJournal() throws {
        let (settings, _, _, store) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        var first = MutationJournal()
        first.timers[SwitchID.darkMode.rawValue] = Date(timeIntervalSince1970: 100)
        try store.save(first)
        store.beforeSave = { throw SwitchError.failed("simulated interrupted save") }
        XCTAssertThrowsError(try store.save(MutationJournal()))
        XCTAssertEqual(try store.load().timers, first.timers)
    }

    func testShutdownRestoresTransientStandaloneChanges() async {
        let (settings, adapters, coordinator, store) = fixture([.otherApps])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await coordinator.setSwitch(.otherApps, enabled: true)
        XCTAssertTrue(adapters[0].enabled)
        await coordinator.shutdown()
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertTrue((try? store.load().changes.isEmpty) == true)
    }

    func testRecoveryRestoresOtherControlsAndRetainsRemovedControlEvidence() async throws {
        let (settings, adapters, coordinator, store) = fixture([.dock])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await coordinator.startRecording()
        var old = try store.load()
        let removed = JournalChange(switchID: .retiredDoNotDisturb, owner: .recording,
                                    original: ResourceSnapshot(enabled: false), applied: ResourceSnapshot(enabled: true),
                                    requestedEnabled: true, phase: .applied)
        old.changes.append(removed)
        old.timers["doNotDisturb"] = Date(timeIntervalSince1970: 1)
        try store.save(old)
        let relaunched = MutationCoordinator(adapters: adapters, settings: settings, journalStore: store)
        await relaunched.recover()
        XCTAssertEqual(relaunched.phase, .idle)
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertNil(relaunched.statuses[.retiredDoNotDisturb])
        XCTAssertNil(relaunched.timers[.retiredDoNotDisturb])
        XCTAssertTrue(try store.load().changes.isEmpty)
        XCTAssertEqual(try store.load().retiredChanges?.map(\.id), [removed.id])
    }

    func testShutdownRestoresRecordingBeforeStandaloneChanges() async throws {
        let (settings, adapters, coordinator, store) = fixture([.dock, .otherApps])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        settings.preferences.recordingSwitches = [.dock]
        let log = EventLog()
        adapters.forEach { $0.log = log }
        await coordinator.setSwitch(.otherApps, enabled: true)
        await coordinator.startRecording()
        await coordinator.shutdown()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(adapters.contains(where: \.enabled))
        XCTAssertTrue(try store.load().changes.isEmpty)
        XCTAssertEqual(Array(log.events.suffix(2)), ["dock.restore", "otherApps.restore"])
    }

    func testShutdownFailureRetainsRecoveryEvidence() async throws {
        let (settings, adapters, coordinator, store) = fixture([.otherApps])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await coordinator.setSwitch(.otherApps, enabled: true)
        adapters[0].failRestore = true
        await coordinator.shutdown()
        XCTAssertEqual(coordinator.phase, .recoveryNeeded)
        XCTAssertEqual(try store.load().changes.count, 1)
        XCTAssertTrue(coordinator.issue?.contains("simulated restore failure") == true)
        adapters[0].failRestore = false
        await coordinator.shutdown()
        XCTAssertTrue(try store.load().changes.isEmpty)
    }

    func testStandaloneAudioOffAfterRelaunchRestoresExactOriginalSnapshot() async {
        let (settings, adapters, coordinator, store) = fixture([.alertSounds])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        adapters[0].value = "original volume 0.27"
        await coordinator.setSwitch(.alertSounds, enabled: true)
        let relaunched = MutationCoordinator(adapters: adapters, settings: settings, journalStore: store)
        await relaunched.recover()
        XCTAssertTrue(adapters[0].enabled)
        await relaunched.setSwitch(.alertSounds, enabled: false)
        XCTAssertFalse(adapters[0].enabled)
        XCTAssertEqual(adapters[0].value, "original volume 0.27")
    }

    func testKeepAwakeStandaloneTimerCannotReleaseRecordingLease() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacWindowHideTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(directory: directory)
        settings.preferences.recordingSwitches = [.keepAwake]
        let adapter = FakeLeaseSwitch()
        let coordinator = MutationCoordinator(adapters: [adapter], settings: settings)
        await coordinator.setSwitch(.keepAwake, enabled: true)
        await coordinator.scheduleAutoOff(.keepAwake, date: Date().addingTimeInterval(-1))
        await coordinator.startRecording()
        await coordinator.tick()
        XCTAssertEqual(adapter.owners, [.recording])
        await coordinator.stopRecording()
        XCTAssertTrue(adapter.owners.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testIdleTickDoesNotPollSystemAdapters() async {
        let (settings, adapters, coordinator, _) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        await coordinator.tick()
        XCTAssertEqual(adapters[0].statusCount, 0)
    }

    func testPendingTimerStillPollsForExternalChanges() async {
        let (settings, adapters, coordinator, _) = fixture([.darkMode])
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        settings.preferences.autoOffMinutes[SwitchID.darkMode.rawValue] = 30
        await coordinator.setSwitch(.darkMode, enabled: true)
        let previous = adapters[0].statusCount
        await coordinator.tick()
        XCTAssertGreaterThan(adapters[0].statusCount, previous)
    }
}

@MainActor private final class EventLog { var events: [String] = [] }

@MainActor private final class FakeSwitch: SystemSwitchAdapter {
    let id: SwitchID
    var enabled = false
    var value = "initial"
    var availability: SwitchCapability = .available
    var failAfterApplying = false
    var failRestore = false
    var applyCount = 0
    var restoreCount = 0
    var statusCount = 0
    var lastContext: ActionContext?
    var log: EventLog?
    init(id: SwitchID) { self.id = id }
    func capability() async -> SwitchCapability { availability }
    func status() async -> SwitchStatus { statusCount += 1; return SwitchStatus(state: enabled ? .on : .off) }
    func snapshot() async throws -> ResourceSnapshot { ResourceSnapshot(["enabled": String(enabled), "value": value]) }
    func apply(enabled: Bool, context: ActionContext) async throws {
        applyCount += 1
        lastContext = context
        log?.events.append("\(id.rawValue).apply.\(enabled)")
        self.enabled = enabled
        value = enabled ? "on" : "off"
        if failAfterApplying { throw SwitchError.failed("simulated apply failure") }
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {
        restoreCount += 1
        lastContext = context
        log?.events.append("\(id.rawValue).restore")
        if failRestore { throw SwitchError.failed("simulated restore failure") }
        enabled = snapshot.enabled
        value = snapshot.values["value"] ?? "initial"
    }
}

@MainActor private final class FakeLeaseSwitch: SystemSwitchAdapter {
    let id = SwitchID.keepAwake
    var owners: Set<ActionOwner> = []
    func capability() async -> SwitchCapability { .available }
    func status() async -> SwitchStatus { SwitchStatus(state: owners.isEmpty ? .off : .on) }
    func snapshot() async throws -> ResourceSnapshot {
        ResourceSnapshot(["enabled": String(!owners.isEmpty), "owners": owners.map(\.rawValue).sorted().joined(separator: ",")])
    }
    func apply(enabled: Bool, context: ActionContext) async throws {
        if enabled { owners.insert(context.owner) } else { owners.remove(context.owner) }
    }
    func restore(_ snapshot: ResourceSnapshot, context: ActionContext) async throws {
        try await apply(enabled: snapshot.values["owners", default: ""].split(separator: ",").contains(Substring(context.owner.rawValue)), context: context)
    }
    func matches(_ snapshot: ResourceSnapshot) async throws -> Bool { snapshot.enabled == !owners.isEmpty }
}
