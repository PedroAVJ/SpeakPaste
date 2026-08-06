import XCTest
@testable import SpeakPaste

final class SegmentedDictationModelTests: XCTestCase {
    func testToggleUsesStateToChooseStartPauseAndResume() {
        XCTAssertEqual(
            SegmentedDictationCaptureState.idle.toggleAction,
            .start
        )
        XCTAssertEqual(
            SegmentedDictationCaptureState.recording.toggleAction,
            .pause
        )
        XCTAssertEqual(
            SegmentedDictationCaptureState.paused.toggleAction,
            .resume
        )
        for transitionalState in [
            SegmentedDictationCaptureState.starting,
            .pausing,
            .resuming,
            .closing,
        ] {
            XCTAssertEqual(transitionalState.toggleAction, .none)
        }
    }

    func testTranscriptAssemblyUsesSpokenOrderNotCompletionOrder() throws {
        let result = try XCTUnwrap(
            SegmentedTranscriptAssembler.assemble([
                SegmentedTranscriptPiece(
                    ordinal: 2,
                    text: " third. ",
                    languageCode: "en"
                ),
                SegmentedTranscriptPiece(
                    ordinal: 0,
                    text: "First,",
                    languageCode: "en"
                ),
                SegmentedTranscriptPiece(
                    ordinal: 1,
                    text: "second",
                    languageCode: "en"
                ),
            ])
        )

        XCTAssertEqual(result.text, "First, second third.")
        XCTAssertEqual(result.languageCode, "en")
    }

    func testTranscriptAssemblyDoesNotClaimOneLanguageForMixedSegments() throws {
        let result = try XCTUnwrap(
            SegmentedTranscriptAssembler.assemble([
                SegmentedTranscriptPiece(
                    ordinal: 0,
                    text: "Hello.",
                    languageCode: "en"
                ),
                SegmentedTranscriptPiece(
                    ordinal: 1,
                    text: "Hola.",
                    languageCode: "es"
                ),
            ])
        )

        XCTAssertEqual(result.text, "Hello. Hola.")
        XCTAssertNil(result.languageCode)
        XCTAssertNil(
            SegmentedTranscriptAssembler.assemble([
                SegmentedTranscriptPiece(
                    ordinal: 0,
                    text: "  \n ",
                    languageCode: nil
                ),
            ])
        )
    }
}
