import XCTest
@testable import SpeakPaste

final class MacRecordingCancellationPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testRecordingUnderThirtySecondsCancelsImmediately() {
        var policy = MacRecordingCancellationPolicy()

        XCTAssertEqual(
            policy.requestCancellation(recordingDuration: 29.999, now: start),
            .cancelImmediately
        )
        XCTAssertNil(policy.armedUntil)
    }

    func testThirtySecondRecordingRequiresASecondEscape() {
        var policy = MacRecordingCancellationPolicy()
        let expectedExpiration = start.addingTimeInterval(3)

        XCTAssertEqual(
            policy.requestCancellation(recordingDuration: 30, now: start),
            .confirmAgain(expiresAt: expectedExpiration)
        )
        XCTAssertEqual(policy.armedUntil, expectedExpiration)
    }

    func testSecondEscapeInsideWindowCancelsAndDisarms() {
        var policy = MacRecordingCancellationPolicy()
        _ = policy.requestCancellation(recordingDuration: 40, now: start)

        XCTAssertEqual(
            policy.requestCancellation(
                recordingDuration: 41,
                now: start.addingTimeInterval(2.999)
            ),
            .cancelImmediately
        )
        XCTAssertNil(policy.armedUntil)
    }

    func testSecondEscapeAtWindowBoundaryStillCancels() {
        var policy = MacRecordingCancellationPolicy()
        _ = policy.requestCancellation(recordingDuration: 40, now: start)

        XCTAssertEqual(
            policy.requestCancellation(
                recordingDuration: 43,
                now: start.addingTimeInterval(3)
            ),
            .cancelImmediately
        )
    }

    func testEscapeAfterWindowExpiresArmsANewWindow() {
        var policy = MacRecordingCancellationPolicy()
        _ = policy.requestCancellation(recordingDuration: 40, now: start)
        let retryAt = start.addingTimeInterval(3.001)

        XCTAssertEqual(
            policy.requestCancellation(recordingDuration: 43, now: retryAt),
            .confirmAgain(expiresAt: retryAt.addingTimeInterval(3))
        )
    }

    func testResetRemovesAnArmedConfirmation() {
        var policy = MacRecordingCancellationPolicy()
        _ = policy.requestCancellation(recordingDuration: 40, now: start)

        policy.reset()

        XCTAssertNil(policy.armedUntil)
        XCTAssertEqual(
            policy.requestCancellation(
                recordingDuration: 41,
                now: start.addingTimeInterval(1)
            ),
            .confirmAgain(expiresAt: start.addingTimeInterval(4))
        )
    }
}
