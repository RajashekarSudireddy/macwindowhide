import Foundation
import XCTest
@testable import MacWindowHide

final class KeyboardSafetyTests: XCTestCase {
    func testExpiresAtSixtySecondsAndPassesKeysAfterward() {
        let releases = ReleaseCounter()
        let state = KeyboardSafetyState(now: 100) { releases.increment() }
        state.check(now: 159.9)
        XCTAssertTrue(state.isActive)
        state.check(now: 160)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.key(down: true, escape: false, now: 160))
        state.release()
        XCTAssertEqual(releases.value, 1)
    }

    func testHoldingEscapeThreeSecondsReleases() {
        let state = KeyboardSafetyState(now: 100) {}
        XCTAssertFalse(state.key(down: true, escape: true, now: 101))
        state.check(now: 103.9)
        XCTAssertTrue(state.isActive)
        state.check(now: 104)
        XCTAssertFalse(state.isActive)
    }

    func testReleasingEscapeCancelsEmergencyHold() {
        let state = KeyboardSafetyState(now: 100) {}
        _ = state.key(down: true, escape: true, now: 101)
        _ = state.key(down: false, escape: true, now: 102)
        state.check(now: 104)
        XCTAssertTrue(state.isActive)
        state.release()
    }

    func testPermissionLossAndSessionLockFailOpen() {
        let revoked = KeyboardSafetyState(now: 100) {}
        revoked.check(now: 101, permission: false)
        XCTAssertFalse(revoked.isActive)
        let locked = KeyboardSafetyState(now: 100) {}
        locked.check(now: 101, sessionLocked: true)
        XCTAssertFalse(locked.isActive)
    }
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
