import Foundation
import XCTest
@testable import SpeakPaste

final class MacTranscriptPostProcessorRegressionTests: XCTestCase {
    func testLeadingParagraphCommandSurvivesCursorFitting() {
        XCTAssertEqual(
            process("new paragraph hello", after: "First."),
            "\n\nHello"
        )
    }

    func testLeadingLineCommandSurvivesWithoutInventingSentenceCasing() {
        XCTAssertEqual(process("new line hello", after: "first"), "\nhello")
        XCTAssertEqual(process("new line hello"), "\nHello")
    }

    func testTrailingLayoutCommandsSurviveCursorFitting() {
        XCTAssertEqual(process("hello new paragraph", after: "Start:"), " Hello\n\n")
        XCTAssertEqual(process("hello new line", after: "Start:"), " Hello\n")
    }

    func testSpokenDelimitersRemoveOnlyTheirInteriorSpaces() {
        XCTAssertEqual(
            process("say open parenthesis hello close parenthesis now"),
            "Say (hello) now"
        )
        XCTAssertEqual(
            process("say open bracket hello close bracket now"),
            "Say [hello] now"
        )
    }

    func testConfiguredReplacementOwnsExactLeadingCase() {
        XCTAssertEqual(
            process(
                "iphone",
                replacements: [replacement(spoken: "iphone", written: "iPhone")]
            ),
            "iPhone"
        )
        XCTAssertEqual(
            process(
                "dog",
                replacements: [replacement(spoken: "dog", written: "dog")]
            ),
            "dog"
        )
    }

    func testScribeMixedCaseProperNameIsNotDamagedAtSentenceStart() {
        XCTAssertEqual(process("iPhone is ready"), "iPhone is ready")
        XCTAssertEqual(process("macOS is ready", after: "Done."), " macOS is ready")
    }

    private func process(
        _ transcript: String,
        replacements: [MacTextReplacement] = [],
        after precedingText: String? = nil
    ) -> String {
        MacTranscriptPostProcessor.apply(
            transcript,
            replacements: replacements,
            precedingText: precedingText
        )
    }

    private func replacement(spoken: String, written: String) -> MacTextReplacement {
        MacTextReplacement(
            spoken: spoken,
            written: written,
            isEnabled: true,
            matchesWholeWordsOnly: true
        )
    }
}

final class MacLanguageConfidenceReviewTests: XCTestCase {
    func testLowAutomaticConfidenceNamesKnownDetectedLanguage() {
        XCTAssertEqual(
            MacLanguageConfidenceReview.notice(
                isAutomatic: true,
                languageTitle: "Spanish",
                probability: 0.423
            ),
            "Scribe was only 42% confident that the language was Spanish. Review the text or pin the language in Settings."
        )
    }

    func testLowAutomaticConfidenceStillWarnsWithoutKnownLanguage() {
        XCTAssertEqual(
            MacLanguageConfidenceReview.notice(
                isAutomatic: true,
                languageTitle: nil,
                probability: 0.49
            ),
            "Scribe's automatic language confidence was only 49%. Review the text or pin the language in Settings."
        )
    }

    func testPinnedHighOrInvalidConfidenceDoesNotWarn() {
        XCTAssertNil(
            MacLanguageConfidenceReview.notice(
                isAutomatic: false,
                languageTitle: "Spanish",
                probability: 0.1
            )
        )
        XCTAssertNil(
            MacLanguageConfidenceReview.notice(
                isAutomatic: true,
                languageTitle: "Spanish",
                probability: 0.5
            )
        )
        XCTAssertNil(
            MacLanguageConfidenceReview.notice(
                isAutomatic: true,
                languageTitle: nil,
                probability: .nan
            )
        )
    }
}

final class MacDiagnosticsRegressionTests: XCTestCase {
    func testMicrophoneGainClampsToDocumentedRange() {
        XCTAssertEqual(microphone(gain: 1.7).gain, 1)
        XCTAssertEqual(microphone(gain: -0.4).gain, 0)
        XCTAssertEqual(microphone(gain: 0.45).gain, 0.45)
    }

    func testNonFiniteMicrophoneGainBecomesUnavailable() {
        XCTAssertNil(microphone(gain: .nan).gain)
        XCTAssertNil(microphone(gain: .infinity).gain)
        XCTAssertNil(microphone(gain: -.infinity).gain)
    }

    func testDecodedMicrophoneGainIsClampedToo() throws {
        let data = Data(
            #"{"name":"Microphone","transport":"builtIn","gain":2.5}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            MacDiagnosticsSnapshot.Microphone.self,
            from: data
        )
        XCTAssertEqual(decoded.gain, 1)
    }

    private func microphone(gain: Double?) -> MacDiagnosticsSnapshot.Microphone {
        MacDiagnosticsSnapshot.Microphone(
            transport: .builtIn,
            gain: gain
        )
    }
}
