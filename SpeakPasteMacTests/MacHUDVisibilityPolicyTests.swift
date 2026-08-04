import XCTest
@testable import SpeakPaste

final class MacHUDVisibilityPolicyTests: XCTestCase {
    func testBatchKeepsConfiguredHUD() {
        XCTAssertTrue(
            MacHUDVisibilityPolicy.shouldPresent(
                hudEnabled: true,
                realtimeDictationEnabled: false
            )
        )
        XCTAssertFalse(
            MacHUDVisibilityPolicy.shouldPresent(
                hudEnabled: false,
                realtimeDictationEnabled: false
            )
        )
    }

    func testRealtimeToggleAlwaysSuppressesStatusHUD() {
        XCTAssertFalse(
            MacHUDVisibilityPolicy.shouldPresent(
                hudEnabled: true,
                realtimeDictationEnabled: true
            )
        )
    }
}
