import XCTest
@testable import SpeakPaste

final class MacHUDVisibilityPolicyTests: XCTestCase {
    func testBatchKeepsConfiguredHUD() {
        XCTAssertTrue(
            MacHUDVisibilityPolicy.shouldPresent(
                hudEnabled: true,
                realtimeCompositionActive: false
            )
        )
        XCTAssertFalse(
            MacHUDVisibilityPolicy.shouldPresent(
                hudEnabled: false,
                realtimeCompositionActive: false
            )
        )
    }

    func testOnlyAnAttachedRealtimeCompositionSuppressesStatusHUD() {
        XCTAssertFalse(
            MacHUDVisibilityPolicy.shouldPresent(
                hudEnabled: true,
                realtimeCompositionActive: true
            )
        )
        XCTAssertTrue(
            MacHUDVisibilityPolicy.shouldPresent(
                hudEnabled: true,
                realtimeCompositionActive: false
            )
        )
    }
}
