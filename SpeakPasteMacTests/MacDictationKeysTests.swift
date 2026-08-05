import XCTest
@testable import SpeakPaste

private extension MacModifierSnapshot {
    static let none = MacModifierSnapshot()
    static let rightCommandOnly = MacModifierSnapshot(rightCommand: true)
    static let rightOptionOnly = MacModifierSnapshot(rightOption: true)
    static let functionOnly = MacModifierSnapshot(function: true)
}

final class MacDictationKeyRecognizerTests: XCTestCase {
    func testEachWatchedKeyProducesItsOwnBareTap() {
        let cases: [(MacModifierSnapshot, MacDictationKey)] = [
            (.rightCommandOnly, .macSource),
            (.rightOptionOnly, .iPhoneSource),
            (.functionOnly, .end),
        ]
        for (down, expected) in cases {
            var recognizer = MacDictationKeyRecognizer()
            XCTAssertNil(recognizer.modifiersChanged(down))
            XCTAssertEqual(recognizer.modifiersChanged(.none), expected)
            // The release is consumed; a repeated all-up event fires nothing.
            XCTAssertNil(recognizer.modifiersChanged(.none))
        }
    }

    func testChordWithAnotherKeyNeverBecomesATap() {
        var recognizer = MacDictationKeyRecognizer()

        XCTAssertNil(recognizer.modifiersChanged(.rightCommandOnly))
        recognizer.otherInputArrived()
        XCTAssertNil(recognizer.modifiersChanged(.none))
    }

    func testChordWithAnUnwatchedModifierNeverBecomesATap() {
        var recognizer = MacDictationKeyRecognizer()

        XCTAssertNil(
            recognizer.modifiersChanged(
                MacModifierSnapshot(rightCommand: true, otherModifiers: true)
            )
        )
        XCTAssertNil(recognizer.modifiersChanged(.rightCommandOnly))
        XCTAssertNil(recognizer.modifiersChanged(.none))
    }

    /// The bug this guards: releasing one half of a two-key chord leaves a
    /// single watched key down, which must not be promoted into a fresh tap.
    func testReleasingHalfOfAChordDoesNotPromoteTheSurvivor() {
        var recognizer = MacDictationKeyRecognizer()

        XCTAssertNil(recognizer.modifiersChanged(.rightCommandOnly))
        XCTAssertNil(
            recognizer.modifiersChanged(
                MacModifierSnapshot(rightCommand: true, rightOption: true)
            )
        )
        XCTAssertNil(recognizer.modifiersChanged(.rightOptionOnly))
        XCTAssertNil(recognizer.modifiersChanged(.none))
    }

    func testBothKeysArrivingTogetherNeverProduceATap() {
        var recognizer = MacDictationKeyRecognizer()

        XCTAssertNil(
            recognizer.modifiersChanged(
                MacModifierSnapshot(rightCommand: true, function: true)
            )
        )
        XCTAssertNil(recognizer.modifiersChanged(.functionOnly))
        XCTAssertNil(recognizer.modifiersChanged(.none))
    }

    /// Typing without any watched key held must not poison the next tap.
    func testTypingBeforeAPressLeavesTheNextTapIntact() {
        var recognizer = MacDictationKeyRecognizer()

        recognizer.otherInputArrived()
        XCTAssertNil(recognizer.modifiersChanged(.rightOptionOnly))
        XCTAssertEqual(recognizer.modifiersChanged(.none), .iPhoneSource)
    }

    func testConsecutiveTapsBothFireWithNoTimingWindow() {
        var recognizer = MacDictationKeyRecognizer()

        XCTAssertNil(recognizer.modifiersChanged(.rightCommandOnly))
        XCTAssertEqual(recognizer.modifiersChanged(.none), .macSource)
        XCTAssertNil(recognizer.modifiersChanged(.rightCommandOnly))
        XCTAssertEqual(recognizer.modifiersChanged(.none), .macSource)
    }

    func testResetAbandonsAnInFlightPress() {
        var recognizer = MacDictationKeyRecognizer()

        XCTAssertNil(recognizer.modifiersChanged(.functionOnly))
        recognizer.reset()
        XCTAssertNil(recognizer.modifiersChanged(.none))
    }
}

final class MacModifierSideTests: XCTestCase {
    func testSnapshotSeparatesTheRightHandKeysFromTheLeft() {
        let right = MacModifierSide.snapshot(
            rawFlags: MacModifierSide.rightCommand
        )
        XCTAssertTrue(right.rightCommand)
        XCTAssertFalse(right.otherModifiers)

        let left = MacModifierSide.snapshot(rawFlags: MacModifierSide.leftCommand)
        XCTAssertFalse(left.rightCommand)
        XCTAssertTrue(left.otherModifiers)

        let leftOption = MacModifierSide.snapshot(
            rawFlags: MacModifierSide.leftOption
        )
        XCTAssertFalse(leftOption.rightOption)
        XCTAssertTrue(leftOption.otherModifiers)
    }

    func testFunctionBitIsWatchedRatherThanDisqualifying() {
        let snapshot = MacModifierSide.snapshot(rawFlags: MacModifierSide.function)
        XCTAssertTrue(snapshot.function)
        XCTAssertFalse(snapshot.otherModifiers)
        XCTAssertEqual(snapshot.downKeys, [.end])
    }

    func testShiftAndControlDisqualifyAWatchedPress() {
        for raw in [MacModifierSide.rightShift, MacModifierSide.rightControl] {
            let snapshot = MacModifierSide.snapshot(
                rawFlags: MacModifierSide.rightCommand | raw
            )
            XCTAssertTrue(snapshot.rightCommand)
            XCTAssertTrue(snapshot.otherModifiers)
        }
    }
}

final class MacDictationKeyTests: XCTestCase {
    func testOnlyTheSourceKeysCarryAnInputMode() {
        XCTAssertEqual(MacDictationKey.macSource.inputMode, .mac)
        XCTAssertEqual(MacDictationKey.iPhoneSource.inputMode, .iPhone)
        XCTAssertNil(MacDictationKey.end.inputMode)
        XCTAssertNil(MacDictationKey.cancel.inputMode)
    }

    func testSourceKeyLookupIsTheInverseOfInputMode() {
        for mode in MacInputMode.allCases {
            XCTAssertEqual(MacDictationKey.sourceKey(for: mode).inputMode, mode)
        }
    }

    func testEscapeIsTheOnlyNonModifierKey() {
        XCTAssertEqual(
            MacDictationKey.allCases.filter { !$0.isModifierKey },
            [.cancel]
        )
    }

    func testEveryKeyIsDescribedExactlyOnceInTheShortcutTable() {
        XCTAssertEqual(
            MacDictationShortcut.all.map(\.dictationKey),
            MacDictationKey.allCases
        )
    }
}

final class MacInputModeTests: XCTestCase {
    func testModeToggleIsSymmetric() {
        XCTAssertEqual(MacInputMode.mac.opposite, .iPhone)
        XCTAssertEqual(MacInputMode.iPhone.opposite, .mac)
    }

    func testModeRawValueRoundTrips() {
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
