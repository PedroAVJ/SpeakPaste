import Foundation
import XCTest
@testable import SpeakPaste

final class MacAccessibilityTargetFingerprintTests: XCTestCase {
    private let frame = CGRect(x: 20, y: 30, width: 500, height: 80)

    func testRebuiltEditorMatchesOnlyWithContinuityProof() {
        let original = fingerprint(identifiers: ["dom:prompt"])
        let rebuilt = fingerprint(identifiers: ["dom:prompt"])

        XCTAssertTrue(
            original.safelyMatchesRebuilt(
                rebuilt,
                sameWindow: true,
                noInterveningUserInput: true
            )
        )
        XCTAssertFalse(
            original.safelyMatchesRebuilt(
                rebuilt,
                sameWindow: false,
                noInterveningUserInput: true
            )
        )
        XCTAssertFalse(
            original.safelyMatchesRebuilt(
                rebuilt,
                sameWindow: true,
                noInterveningUserInput: false
            )
        )
    }

    func testRebuiltEditorFallbackRequiresMatchingRoleAndSubstantialFrameOverlap() {
        let original = fingerprint()
        let shiftedSlightly = MacAccessibilityTargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            stableIdentifiers: [],
            placeholder: "Message",
            frame: frame.offsetBy(dx: 10, dy: 0)
        )
        let unrelatedField = MacAccessibilityTargetFingerprint(
            role: "AXTextField",
            subrole: nil,
            stableIdentifiers: [],
            placeholder: "Search",
            frame: CGRect(x: 20, y: 300, width: 500, height: 40)
        )

        XCTAssertTrue(
            original.safelyMatchesRebuilt(
                shiftedSlightly,
                sameWindow: true,
                noInterveningUserInput: true
            )
        )
        XCTAssertFalse(
            original.safelyMatchesRebuilt(
                unrelatedField,
                sameWindow: true,
                noInterveningUserInput: true
            )
        )
    }

    private func fingerprint(
        identifiers: Set<String> = []
    ) -> MacAccessibilityTargetFingerprint {
        MacAccessibilityTargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            stableIdentifiers: identifiers,
            placeholder: "Message",
            frame: frame
        )
    }
}

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

    func testPreparedChunkDoesNotCollideWithPrecedingWord() {
        let chunk = prepare("Next")

        XCTAssertEqual(
            MacTranscriptPostProcessor.fit(chunk, after: "word"),
            " Next"
        )
    }

    func testPreparedChunkDoesNotAddSpaceAfterWhitespaceNewlineOrOpeningMark() {
        let chunk = prepare("next")

        XCTAssertEqual(MacTranscriptPostProcessor.fit(chunk, after: "word "), "next")
        XCTAssertEqual(MacTranscriptPostProcessor.fit(chunk, after: "word\n"), "next")
        XCTAssertEqual(MacTranscriptPostProcessor.fit(chunk, after: "("), "next")
    }

    func testPreparedPunctuationAttachesToPrecedingText() {
        let chunk = prepare(", next")

        XCTAssertEqual(MacTranscriptPostProcessor.fit(chunk, after: "word"), ", next")
    }

    func testPreparedChunkUsesSentenceCaseWithoutOverridingReplacementCase() {
        XCTAssertEqual(
            MacTranscriptPostProcessor.fit(prepare("next"), after: "Done."),
            " Next"
        )

        let replacementChunk = prepare(
            "iphone",
            replacements: [replacement(spoken: "iphone", written: "iPhone")]
        )
        XCTAssertEqual(
            MacTranscriptPostProcessor.fit(replacementChunk, after: "Done."),
            " iPhone"
        )
    }

    func testPreparedChunkFoldCarriesActualTextAcrossThreeFragments() {
        let chunks = ["one", "two.", "three"].map { prepare($0) }

        XCTAssertEqual(
            MacTranscriptPostProcessor.fold(chunks, after: "Draft"),
            " one two. Three"
        )
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

    private func prepare(
        _ transcript: String,
        replacements: [MacTextReplacement] = []
    ) -> MacPreparedTranscriptChunk {
        MacTranscriptPostProcessor.prepare(
            transcript,
            replacements: replacements
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
