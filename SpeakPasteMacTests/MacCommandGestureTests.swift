import XCTest
@testable import SpeakPaste

final class MacCommandGestureTests: XCTestCase {
    func testBareCommandReleaseProducesOneTapCandidate() {
        var recognizer = CommandTapRecognizer()

        XCTAssertFalse(recognizer.modifiersChanged(commandDown: true, hasOtherModifiers: false))
        XCTAssertTrue(recognizer.modifiersChanged(commandDown: false, hasOtherModifiers: false))
        XCTAssertFalse(recognizer.modifiersChanged(commandDown: false, hasOtherModifiers: false))
    }

    func testCommandChordNeverBecomesATap() {
        var recognizer = CommandTapRecognizer()

        XCTAssertFalse(recognizer.modifiersChanged(commandDown: true, hasOtherModifiers: false))
        recognizer.keyPressed()
        XCTAssertFalse(recognizer.modifiersChanged(commandDown: false, hasOtherModifiers: false))
    }

    func testSingleTapCommitsOnlyWithItsLiveToken() {
        var recognizer = CommandTapSequenceRecognizer()
        guard case let .deferSingle(token) = recognizer.registerTap() else {
            return XCTFail("First tap should be deferred")
        }

        XCTAssertTrue(recognizer.hasPendingSingleTap)
        XCTAssertFalse(recognizer.commitSingleTap(token: UUID()))
        XCTAssertTrue(recognizer.commitSingleTap(token: token))
        XCTAssertFalse(recognizer.hasPendingSingleTap)
    }

    func testSecondTapBecomesDoubleAndInvalidatesDeferredSingle() {
        var recognizer = CommandTapSequenceRecognizer()
        guard case let .deferSingle(token) = recognizer.registerTap() else {
            return XCTFail("First tap should be deferred")
        }

        XCTAssertEqual(recognizer.registerTap(), .doubleTap)
        XCTAssertFalse(recognizer.commitSingleTap(token: token))
        XCTAssertFalse(recognizer.hasPendingSingleTap)
    }

    func testCancellationPreventsADeferredSingleFromFiring() {
        var recognizer = CommandTapSequenceRecognizer()
        guard case let .deferSingle(token) = recognizer.registerTap() else {
            return XCTFail("First tap should be deferred")
        }

        recognizer.cancel()

        XCTAssertFalse(recognizer.commitSingleTap(token: token))
    }
}

final class MacInputModeTests: XCTestCase {
    func testModeToggleIsSymmetric() {
        XCTAssertEqual(MacInputMode.mac.opposite, .iPhone)
        XCTAssertEqual(MacInputMode.iPhone.opposite, .mac)
    }

    func testModeRawValueRoundTripsForStickyPersistence() {
        for mode in MacInputMode.allCases {
            XCTAssertEqual(MacInputMode(rawValue: mode.rawValue), mode)
        }
    }

    func testModesMatchOnlyTheirSemanticTransport() {
        XCTAssertTrue(MacInputMode.mac.matches(isContinuityDevice: false, isBuiltInDevice: true))
        XCTAssertFalse(MacInputMode.mac.matches(isContinuityDevice: true, isBuiltInDevice: false))
        XCTAssertTrue(MacInputMode.iPhone.matches(isContinuityDevice: true, isBuiltInDevice: false))
        XCTAssertFalse(MacInputMode.iPhone.matches(isContinuityDevice: false, isBuiltInDevice: true))
        XCTAssertFalse(MacInputMode.iPhone.matches(isContinuityDevice: false, isBuiltInDevice: false))
        XCTAssertFalse(MacInputMode.mac.matches(isContinuityDevice: false, isBuiltInDevice: false))
    }
}
