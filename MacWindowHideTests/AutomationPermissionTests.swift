import ApplicationServices
import XCTest
@testable import MacWindowHide

final class AutomationPermissionTests: XCTestCase {
    func testGrantedPermissionSucceeds() {
        XCTAssertNoThrow(try SystemScript.validatePermissionRequest(noErr))
    }

    func testDeniedPermissionExplainsHowToEnableIt() {
        XCTAssertThrowsError(try SystemScript.validatePermissionRequest(OSStatus(errAEEventNotPermitted))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Open Automation Settings"))
            XCTAssertTrue(error.localizedDescription.contains("previously denied"))
        }
    }

    func testUnresolvedConsentIsNotReportedAsSuccess() {
        XCTAssertThrowsError(try SystemScript.validatePermissionRequest(OSStatus(errAEEventWouldRequireUserConsent))) { error in
            XCTAssertTrue(error.localizedDescription.contains("still needs permission"))
        }
    }

    func testUnexpectedFailurePreservesSystemErrorCode() {
        XCTAssertThrowsError(try SystemScript.validatePermissionRequest(-600)) { error in
            XCTAssertTrue(error.localizedDescription.contains("error -600"))
        }
    }
}
