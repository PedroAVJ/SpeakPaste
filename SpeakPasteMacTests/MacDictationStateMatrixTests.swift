import Carbon
import XCTest
@testable import SpeakPaste

/// The product's state matrix, asserted directly against the pure projection
/// the menu-bar map draws. Anything that changes what a key means in a state
/// has to change this table too.
final class MacDictationStateMatrixTests: XCTestCase {
    private func indications(
        _ phase: MacCapturePhase,
        source: MacInputMode? = nil,
        banked: Bool = false,
        ready: Bool = true
    ) -> [MacDictationKey: MacKeyIndication] {
        MacKeyboardMapState.indications(
            phase: phase,
            activeSource: source,
            hasBankedSegments: banked,
            canStartRecording: ready
        )
    }

    // MARK: Idle

    func testIdleOffersBothSourcesAndNothingElse() {
        let map = indications(.ready)
        XCTAssertTrue(map[.macSource]?.isActive == true)
        XCTAssertTrue(map[.iPhoneSource]?.isActive == true)
        XCTAssertFalse(map[.end]?.isActive == true)
        XCTAssertFalse(map[.cancel]?.isActive == true)
    }

    func testIdleWithoutSetupOffersNothing() {
        let map = indications(.ready, ready: false)
        XCTAssertFalse(map[.macSource]?.isActive == true)
        XCTAssertFalse(map[.iPhoneSource]?.isActive == true)
    }

    // MARK: Connecting

    func testConnectingRetargetsWithTheOtherSourceKeyOnly() {
        let map = indications(.connecting, source: .mac)
        XCTAssertFalse(map[.macSource]?.isActive == true, "the key already connecting is inert")
        XCTAssertTrue(map[.iPhoneSource]?.isActive == true)
    }

    func testEndIsInertWhileConnectingWithNothingBanked() {
        XCTAssertFalse(
            indications(.connecting, source: .iPhone)[.end]?.isActive == true
        )
        XCTAssertTrue(
            indications(.connecting, source: .iPhone, banked: true)[.end]?.isActive == true
        )
    }

    func testEscapeAlwaysAbortsAConnection() {
        XCTAssertTrue(indications(.connecting, source: .mac)[.cancel]?.isActive == true)
    }

    // MARK: Recording

    func testRecordingPausesOnItsOwnSourceKey() {
        let map = indications(.recording, source: .mac, banked: false)
        XCTAssertEqual(map[.macSource], .active(symbol: "pause.fill", tint: .source))
    }

    func testTheOtherSourceKeyRefusesRatherThanSwitching() {
        XCTAssertEqual(
            indications(.recording, source: .mac)[.iPhoneSource],
            .refused(symbol: "iphone")
        )
        XCTAssertEqual(
            indications(.recording, source: .iPhone)[.macSource],
            .refused(symbol: "laptopcomputer")
        )
    }

    func testRecordingAlwaysOffersEndAndDiscard() {
        let map = indications(.recording, source: .iPhone)
        XCTAssertTrue(map[.end]?.isActive == true)
        XCTAssertTrue(map[.cancel]?.isActive == true)
    }

    // MARK: Resting

    func testRestingResumesOnEitherSourceKey() {
        let map = indications(.paused, banked: true)
        XCTAssertEqual(map[.macSource], .active(symbol: "laptopcomputer", tint: .source))
        XCTAssertEqual(map[.iPhoneSource], .active(symbol: "iphone", tint: .source))
    }

    func testRestingDeliversOnEndAndDiscardsOnEscape() {
        let map = indications(.paused, banked: true)
        XCTAssertTrue(map[.end]?.isActive == true)
        XCTAssertTrue(map[.cancel]?.isActive == true)
    }

    // MARK: Invariants

    /// The safety property the whole control surface exists to guarantee.
    func testNoSourceKeyEverDeliversOrDiscards() {
        for phase in Self.everyPhase {
            for source in [MacInputMode.mac, .iPhone, nil] {
                for banked in [true, false] {
                    let map = indications(phase, source: source, banked: banked)
                    for key in [MacDictationKey.macSource, .iPhoneSource] {
                        switch map[key] {
                        case .active(_, let tint):
                            XCTAssertEqual(
                                tint,
                                .source,
                                "\(key) must never carry a delivery or discard verb"
                            )
                        case .blank, .inert, .refused, nil:
                            continue
                        }
                    }
                }
            }
        }
    }

    func testEndAndEscapeNeverBothActOnAClosedDictation() {
        for phase in [MacCapturePhase.ready, .succeeded("done"), .failed("nope")] {
            let map = indications(phase, banked: true)
            XCTAssertFalse(map[.end]?.isActive == true)
            XCTAssertFalse(map[.cancel]?.isActive == true)
        }
    }

    func testEveryPhaseDescribesEveryKey() {
        for phase in Self.everyPhase {
            let map = indications(phase, source: .mac, banked: true)
            XCTAssertEqual(Set(map.keys), Set(MacDictationKey.allCases))
        }
    }

    private static let everyPhase: [MacCapturePhase] = [
        .ready,
        .connecting,
        .recording,
        .finalizing,
        .paused,
        .succeeded("done"),
        .failed("nope"),
    ]
}

final class MacCapturePhaseTests: XCTestCase {
    func testRestingIsOpenButHoldsNoMicrophone() {
        XCTAssertTrue(MacCapturePhase.paused.dictationIsOpen)
        XCTAssertFalse(MacCapturePhase.paused.holdsMicrophone)
    }

    func testOnlyTheCapturePhasesHoldTheMicrophone() {
        XCTAssertEqual(
            [
                MacCapturePhase.ready,
                .connecting,
                .recording,
                .finalizing,
                .paused,
                .succeeded("done"),
                .failed("nope"),
            ].filter(\.holdsMicrophone),
            [.connecting, .recording, .finalizing]
        )
    }

    func testAClosedDictationNeverBlocksDelivery() {
        XCTAssertFalse(MacCapturePhase.ready.dictationIsOpen)
        XCTAssertFalse(MacCapturePhase.succeeded("done").dictationIsOpen)
        XCTAssertFalse(MacCapturePhase.failed("nope").dictationIsOpen)
    }
}

final class MacKeyboardMapLayoutTests: XCTestCase {
    func testEveryShapeBindsExactlyTheFourKeysOnce() {
        for shape in [MacPhysicalKeyboardShape.ansi, .iso, .jis] {
            let bound = MacKeyboardMapLayout.keys(for: shape).compactMap(\.binding)
            XCTAssertEqual(
                Set(bound),
                Set(MacDictationKey.allCases),
                "\(shape) must draw all four bound keys"
            )
            XCTAssertEqual(bound.count, MacDictationKey.allCases.count, "\(shape) duplicates a binding")
        }
    }

    func testEveryShapeFillsTheSameBoardWidth() {
        for shape in [MacPhysicalKeyboardShape.ansi, .iso, .jis] {
            let keys = MacKeyboardMapLayout.keys(for: shape)
            for row in Set(keys.map(\.y)) {
                // Measure the rightmost edge of everything crossing this row's
                // midline: the stacked arrow pair shares one column, and the
                // ISO/JIS return spans down from the row above.
                let midline = row + 0.25
                let edge = keys
                    .filter { $0.y <= midline && $0.y + $0.height >= midline }
                    .map { $0.x + $0.width }
                    .max() ?? 0
                XCTAssertEqual(
                    edge,
                    MacKeyboardMapLayout.unitsWide,
                    accuracy: 0.001,
                    "\(shape) row at \(row) does not span the board"
                )
            }
        }
    }

    func testNoKeyEscapesTheBoard() {
        for shape in [MacPhysicalKeyboardShape.ansi, .iso, .jis] {
            for key in MacKeyboardMapLayout.keys(for: shape) {
                XCTAssertGreaterThanOrEqual(key.x, 0)
                XCTAssertLessThanOrEqual(
                    key.y + key.height,
                    MacKeyboardMapLayout.unitsTall + 0.001
                )
            }
        }
    }

    func testLayoutTypeMapsToTheDrawnShape() {
        XCTAssertEqual(MacPhysicalKeyboardShape.shape(forLayoutType: kKeyboardANSI), .ansi)
        XCTAssertEqual(MacPhysicalKeyboardShape.shape(forLayoutType: kKeyboardISO), .iso)
        XCTAssertEqual(MacPhysicalKeyboardShape.shape(forLayoutType: kKeyboardJIS), .jis)
        XCTAssertEqual(MacPhysicalKeyboardShape.shape(forLayoutType: -1), .ansi)
    }
}
