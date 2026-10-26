import AppKit
import XCTest
@testable import MacWindowHide

@MainActor final class VisualRecoveryTests: XCTestCase {
    private func fixture(owners: [String: [[String: Any]]]) throws -> (SettingsStore, any SystemSwitchAdapter) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacWindowHideVisualTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["owners": owners]).write(to: directory.appendingPathComponent("HiddenApps.json"))
        let settings = SettingsStore(directory: directory)
        let adapter = try XCTUnwrap(makeVisualAdapters(settings: settings).first { $0.id == .otherApps })
        return (settings, adapter)
    }

    func testRecoveryReleasesOnlyItsOwnerAndDiscardsStaleProcesses() async throws {
        let identity: [String: Any] = ["pid": Int32.max, "bundleID": "example.nonexistent", "launchTime": 0.0]
        let (settings, adapter) = try fixture(owners: ["recording": [identity], "standalone": [identity]])
        defer { adapter.shutdown(); try? FileManager.default.removeItem(at: settings.directory) }
        try await adapter.restore(ResourceSnapshot(enabled: false), context: ActionContext(owner: .recording))
        let data = try Data(contentsOf: settings.directory.appendingPathComponent("HiddenApps.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let owners = try XCTUnwrap(root["owners"] as? [String: [[String: Any]]])
        XCTAssertEqual(owners["recording"]?.count ?? 0, 0)
        XCTAssertEqual(owners["standalone"]?.count, 1)
        try await adapter.restore(ResourceSnapshot(enabled: false), context: ActionContext(owner: .standalone))
        let matches = try await adapter.matches(ResourceSnapshot(enabled: false))
        XCTAssertTrue(matches)
    }

    func testReusedPIDWithDifferentLaunchDateDoesNotOwnTheLiveProcess() async throws {
        let current = NSRunningApplication.current
        let identity: [String: Any] = ["pid": current.processIdentifier, "bundleID": current.bundleIdentifier ?? "", "launchTime": -1.0]
        let (settings, adapter) = try fixture(owners: ["recording": [identity]])
        defer { adapter.shutdown(); try? FileManager.default.removeItem(at: settings.directory) }
        let beforeHidden = current.isHidden
        try await adapter.restore(ResourceSnapshot(enabled: false), context: ActionContext(owner: .recording))
        XCTAssertEqual(current.isHidden, beforeHidden)
        let matches = try await adapter.matches(ResourceSnapshot(enabled: false))
        XCTAssertTrue(matches)
    }

    func testCorruptRecoveryLedgerFailsClosedWithoutOverwritingIt() async throws {
        let (settings, original) = try fixture(owners: [:])
        original.shutdown()
        defer { try? FileManager.default.removeItem(at: settings.directory) }
        let url = settings.directory.appendingPathComponent("HiddenApps.json")
        let corrupt = Data("{bad json".utf8)
        try corrupt.write(to: url)
        let adapter = try XCTUnwrap(makeVisualAdapters(settings: settings).first { $0.id == .otherApps })
        defer { adapter.shutdown() }
        let capability = await adapter.capability()
        XCTAssertFalse(capability.isAvailable)
        do {
            try await adapter.restore(ResourceSnapshot(enabled: false), context: ActionContext(owner: .recording))
            XCTFail("Corrupt recovery data must stop automatic restoration.")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}
