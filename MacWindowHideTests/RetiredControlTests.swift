import XCTest
@testable import MacWindowHide

@MainActor final class RetiredControlTests: XCTestCase {
    func testRemovedControlIsAbsentFromAllEntryPoints() async {
        let retired = SwitchID.retiredDoNotDisturb
        XCTAssertEqual(SwitchID.allCases.count, 14)
        XCTAssertFalse(SwitchID.allCases.contains(retired))
        XCTAssertFalse(retired.supportsRecording)
        XCTAssertFalse(retired.supportsTimer)
        XCTAssertFalse(SwitchID.defaultRecording.contains(retired))
        XCTAssertFalse(AppPreferences().visibleSwitches.contains(retired))
        XCTAssertNil(SwitchID.caseDisplayRepresentations[retired])
        var intent = SetControlIntent()
        intent.control = retired
        intent.operation = .on
        do {
            _ = try await intent.perform()
            XCTFail("A previously saved Shortcut must not run the removed control.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("removed")) }
    }

    func testOldSettingsKeepUserChoicesWhileRemovingRetiredReferences() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var old = AppPreferences()
        old.countdownEnabled = true
        old.recordingLimitMinutes = 45
        old.backdropPreset = 8
        old.recordingSwitches = [.retiredDoNotDisturb, .dock]
        old.switchOrder = [.keepAwake, .retiredDoNotDisturb, .dock]
        old.visibleSwitches = [.retiredDoNotDisturb, .keepAwake]
        old.hiddenSwitches = [.retiredDoNotDisturb, .darkMode]
        old.autoOffMinutes = ["doNotDisturb": 10, "keepAwake": 30]
        let file = directory.appendingPathComponent("Settings.json")
        try JSONEncoder().encode(old).write(to: file)
        let store = SettingsStore(directory: directory)
        var expected = old
        expected.removeRetiredControls()
        XCTAssertEqual(store.preferences, expected)
        XCTAssertEqual(store.preferences.switchOrder, [.keepAwake, .dock])
        XCTAssertEqual(store.preferences.recordingSwitches, [.dock])
        XCTAssertEqual(store.preferences.autoOffMinutes, ["keepAwake": 30])
        store.preferences.countdownEnabled = false
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("doNotDisturb"))
    }

    func testOldRecoveryEvidenceIsRetainedAndRetirementIsIdempotent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let removed = JournalChange(switchID: .retiredDoNotDisturb, owner: .recording,
                                    original: ResourceSnapshot(["state": "none", "enabled": "false"]),
                                    applied: ResourceSnapshot(["state": "dnd", "enabled": "true"]),
                                    requestedEnabled: true, phase: .applied)
        let retained = JournalChange(switchID: .dock, owner: .recording,
                                     original: ResourceSnapshot(enabled: false), requestedEnabled: true)
        var old = MutationJournal()
        old.changes = [removed, retained]
        old.timers = ["doNotDisturb": Date(timeIntervalSince1970: 100), "keepAwake": Date(timeIntervalSince1970: 200)]
        try store.save(old)
        let originalData = try Data(contentsOf: store.fileURL)
        let migrated = try store.load()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)
        XCTAssertEqual(migrated.changes.map(\.id), [retained.id])
        XCTAssertEqual(migrated.retiredChanges?.map(\.id), [removed.id])
        XCTAssertEqual(migrated.retiredChanges?.first?.original, removed.original)
        XCTAssertEqual(migrated.retiredChanges?.first?.applied, removed.applied)
        XCTAssertEqual(migrated.timers, ["keepAwake": Date(timeIntervalSince1970: 200)])
        XCTAssertEqual(migrated.retiredTimers, ["doNotDisturb": Date(timeIntervalSince1970: 100)])
        try store.save(migrated)
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.retiredChanges?.map(\.id), [removed.id])
        XCTAssertEqual(reloaded.changes.map(\.id), [retained.id])
    }

    func testUnknownTimersAndInvalidRetiredEvidenceStillFailClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        var journal = MutationJournal()
        journal.timers = ["unknownControl": Date()]
        try store.save(journal)
        let original = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        journal.timers = [:]
        journal.retiredChanges = [JournalChange(switchID: .dock, owner: .recording,
                                               original: ResourceSnapshot(enabled: false), requestedEnabled: true)]
        try store.save(journal)
        XCTAssertThrowsError(try store.load())
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacWindowHideRetiredTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
