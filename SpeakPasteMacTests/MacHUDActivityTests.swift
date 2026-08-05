import AppKit
import Combine
import XCTest
@testable import SpeakPaste

final class MacHUDHeldSymbolTests: XCTestCase {
    func testHeldSymbolMappingUsesClipboardAndDocumentGlyphs() {
        XCTAssertEqual(
            MacHUDHeldSymbol.systemName(
                clipboardBacked: true,
                isAvailable: { _ in true }
            ),
            "clipboard.fill"
        )
        XCTAssertEqual(
            MacHUDHeldSymbol.systemName(
                clipboardBacked: false,
                isAvailable: { _ in true }
            ),
            "doc.text.fill"
        )
    }

    func testHeldSymbolsRenderAndMissingPreferredSymbolFallsBack() {
        for name in [
            MacHUDHeldSymbol.clipboard,
            MacHUDHeldSymbol.recovery,
            MacHUDHeldSymbol.fallback,
        ] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "Expected supported macOS 14 SF Symbol: \(name)"
            )
        }

        XCTAssertEqual(
            MacHUDHeldSymbol.systemName(
                clipboardBacked: true,
                isAvailable: { _ in false }
            ),
            MacHUDHeldSymbol.fallback
        )
    }
}

final class MacHUDStackTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 10_000)

    private func pipelineWithTranscriptions(
        _ entries: [(id: UUID, ordinal: Int, offset: TimeInterval)],
        duration: TimeInterval = 10
    ) -> MacHUDPipeline {
        var pipeline = MacHUDPipeline()
        for entry in entries {
            let createdAt = base.addingTimeInterval(entry.offset)
            pipeline.beginTranscription(
                id: entry.id,
                ordinal: entry.ordinal,
                recordingDuration: duration,
                createdAt: createdAt,
                at: createdAt
            )
        }
        return pipeline
    }

    func testEmptyPipelineResolvesToEmptyStack() {
        let stack = MacHUDStack.resolve(pipeline: MacHUDPipeline(), at: base)

        XCTAssertTrue(stack.isEmpty)
        XCTAssertEqual(stack, .empty)
        XCTAssertNil(MacHUDStack.nextExpiry(in: MacHUDPipeline(), after: base))
    }

    func testWrongSourceNudgeAppearsImmediatelyInFrontAndExpires() {
        let captureID = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(id: captureID, ordinal: 1, at: base)
        pipeline.showWrongSourceNudge(
            attempted: .iPhone,
            live: .mac,
            at: base.addingTimeInterval(1)
        )

        let visible = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(1.5)
        )

        XCTAssertEqual(visible.cards.count, 2)
        XCTAssertEqual(
            visible.cards[0].content,
            .sourceNudge(attempted: .iPhone, live: .mac)
        )
        XCTAssertEqual(visible.cards[1].id, captureID)
        XCTAssertEqual(
            visible.accessibilityLabel(sourceName: "Mac"),
            "SpeakPaste, Pause before switching to the iPhone microphone"
        )
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: pipeline, after: base.addingTimeInterval(1)),
            base.addingTimeInterval(1 + MacHUDStack.sourceNudgeVisibilityCap)
        )

        let expired = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(
                1 + MacHUDStack.sourceNudgeVisibilityCap + 0.001
            )
        )
        XCTAssertEqual(expired.cards.map(\.id), [captureID])
    }

    func testRepeatedNudgeReplacesThePreviousOneAndRestartsExpiry() {
        var pipeline = MacHUDPipeline()
        pipeline.showWrongSourceNudge(attempted: .iPhone, live: .mac, at: base)
        let firstID = MacHUDStack.resolve(pipeline: pipeline, at: base).cards[0].id

        pipeline.showWrongSourceNudge(
            attempted: .mac,
            live: .iPhone,
            at: base.addingTimeInterval(0.4)
        )
        let repeated = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(0.5)
        )

        XCTAssertNotEqual(repeated.cards[0].id, firstID)
        XCTAssertEqual(
            repeated.cards[0].content,
            .sourceNudge(attempted: .mac, live: .iPhone)
        )
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: pipeline, after: base.addingTimeInterval(0.5)),
            base.addingTimeInterval(0.4 + MacHUDStack.sourceNudgeVisibilityCap)
        )
    }

    /// The property that makes resting safe to leave on screen: it has no
    /// deadline of its own, and it survives every rail expiring behind it.
    func testRestingNeverTimesOutAndOutlivesItsRails() {
        let dictationID = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginTranscription(
            id: dictationID,
            ordinal: 1,
            recordingDuration: 3,
            createdAt: base,
            at: base
        )
        pipeline.beginResting(at: base)

        let resting = MacHUDStack.resolve(pipeline: pipeline, at: base)
        XCTAssertTrue(resting.isResting)
        XCTAssertEqual(resting.cards[0].content, .resting)
        XCTAssertEqual(resting.cards.map(\.id).last, dictationID)

        // Long after every transcription rail has timed out.
        let later = base.addingTimeInterval(
            MacHUDStack.transcriptionVisibilityCap + 600
        )
        let stillResting = MacHUDStack.resolve(pipeline: pipeline, at: later)
        XCTAssertEqual(stillResting.cards.map(\.content), [.resting])
        XCTAssertNil(MacHUDStack.nextExpiry(in: pipeline, after: later))
        XCTAssertTrue(
            stillResting
                .accessibilityLabel(sourceName: nil)
                .contains("Dictation resting")
        )
    }

    func testEnteringRestingTwiceKeepsTheSameCard() {
        var pipeline = MacHUDPipeline()
        pipeline.beginResting(at: base)
        let firstID = pipeline.resting?.id
        pipeline.beginResting(at: base.addingTimeInterval(30))

        XCTAssertEqual(pipeline.resting?.id, firstID)
        XCTAssertEqual(pipeline.resting?.startedAt, base)

        pipeline.endResting()
        XCTAssertNil(pipeline.resting)
        XCTAssertFalse(MacHUDStack.resolve(pipeline: pipeline, at: base).isResting)
    }

    func testOneCardKeepsItsIdentityFromCaptureThroughTranscriptionAndHeld() {
        let id = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(id: id, ordinal: 1, at: base)

        let capture = MacHUDStack.resolve(pipeline: pipeline, at: base)
        XCTAssertEqual(capture.cards.map(\.id), [id])
        XCTAssertEqual(capture.cards[0].content, .capture(.connecting))
        XCTAssertEqual(capture.cards[0].ordinal, 1)

        pipeline.beginTranscription(
            id: id,
            ordinal: 1,
            recordingDuration: 7,
            createdAt: base,
            at: base.addingTimeInterval(2)
        )
        let transcription = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(3)
        )
        XCTAssertNil(pipeline.capture)
        XCTAssertEqual(transcription.cards.map(\.id), [id])
        XCTAssertEqual(
            transcription.cards[0].content,
            .transcription(
                stage: .transcribing,
                enqueuedAt: base.addingTimeInterval(2),
                recordingDuration: 7
            )
        )

        pipeline.markHeld(id: id, at: base.addingTimeInterval(4))
        let held = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(5)
        )
        XCTAssertEqual(held.cards.map(\.id), [id])
        XCTAssertEqual(held.cards[0].content, .held)
        XCTAssertEqual(held.cards[0].ordinal, 1)
    }

    func testCaptureIsFrontmostAndOldestPendingDictationIsRearmost() {
        let first = UUID()
        let second = UUID()
        let captureID = UUID()
        var pipeline = pipelineWithTranscriptions([
            (second, 2, 4),
            (first, 1, 1),
        ])
        pipeline.beginCapture(id: captureID, ordinal: 3, at: base.addingTimeInterval(5))
        pipeline.updateCapture(
            id: captureID,
            activity: .listening,
            at: base.addingTimeInterval(6)
        )

        let stack = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(7)
        )

        XCTAssertEqual(stack.cards.map(\.id), [captureID, second, first])
        XCTAssertEqual(stack.cards.map(\.depth), [0, 1, 2])
        XCTAssertEqual(stack.cards.map(\.ordinal), [3, 2, 1])
        XCTAssertEqual(stack.cards.first?.content, .capture(.listening))
        XCTAssertEqual(stack.cards.last?.id, first, "The oldest spoken ticket is next to deliver")
        XCTAssertEqual(stack.liveDictationCount, 2)
    }

    func testStackKeepsFrontAndTwoOldestPeeksWithArbitraryOverflowCount() {
        let ids = (0..<8).map { _ in UUID() }
        let captureID = UUID()
        var pipeline = pipelineWithTranscriptions(
            ids.enumerated().map { index, id in
                (id, index + 1, TimeInterval(index))
            }
        )
        pipeline.beginCapture(id: captureID, ordinal: 9, at: base.addingTimeInterval(9))

        let stack = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(10)
        )

        XCTAssertEqual(stack.cards.count, MacHUDStack.visibleCardBudget)
        XCTAssertEqual(stack.cards.map(\.id), [captureID, ids[1], ids[0]])
        XCTAssertEqual(stack.cards.map(\.hiddenDeeperCount), [0, 0, 6])
        XCTAssertEqual(stack.totalTranscriptionCount, 8)
    }

    func testConnectingAndReleasingHaveIndependentVisibilityCaps() {
        let id = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(id: id, ordinal: 1, at: base)

        XCTAssertFalse(
            MacHUDStack.resolve(
                pipeline: pipeline,
                at: base.addingTimeInterval(19.999)
            ).isEmpty
        )
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: pipeline, after: base),
            base.addingTimeInterval(20)
        )
        XCTAssertTrue(
            MacHUDStack.resolve(
                pipeline: pipeline,
                at: base.addingTimeInterval(20)
            ).isEmpty
        )

        let releaseStart = base.addingTimeInterval(30)
        pipeline.updateCapture(id: id, activity: .releasing, at: releaseStart)
        XCTAssertFalse(
            MacHUDStack.resolve(
                pipeline: pipeline,
                at: releaseStart.addingTimeInterval(14.999)
            ).isEmpty
        )
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: pipeline, after: releaseStart),
            releaseStart.addingTimeInterval(15)
        )
        XCTAssertTrue(
            MacHUDStack.resolve(
                pipeline: pipeline,
                at: releaseStart.addingTimeInterval(15)
            ).isEmpty
        )
    }

    func testListeningPersistsWhileHeldStatusExpires() {
        let listeningID = UUID()
        let heldID = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(id: listeningID, ordinal: 2, at: base)
        pipeline.updateCapture(id: listeningID, activity: .listening, at: base)
        pipeline.markHeld(id: heldID, ordinal: 1, createdAt: base, at: base)

        let shortlyAfter = base.addingTimeInterval(1)
        XCTAssertEqual(
            Set(MacHUDStack.resolve(pipeline: pipeline, at: shortlyAfter).cards.map(\.id)),
            Set([listeningID, heldID])
        )
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: pipeline, after: base),
            base.addingTimeInterval(MacHUDStack.heldVisibilityCap)
        )

        let muchLater = base.addingTimeInterval(10_000)
        let stack = MacHUDStack.resolve(pipeline: pipeline, at: muchLater)

        XCTAssertEqual(stack.cards.map(\.id), [listeningID])
        XCTAssertNil(MacHUDStack.nextExpiry(in: pipeline, after: muchLater))
    }

    func testTranscribingAndAwaitingDeliveryShareNinetySecondCap() {
        let transcribingID = UUID()
        let awaitingID = UUID()
        var pipeline = pipelineWithTranscriptions([
            (transcribingID, 1, 0),
            (awaitingID, 2, 10),
        ])
        pipeline.markAwaitingDelivery(id: awaitingID, at: base.addingTimeInterval(20))

        let beforeFirstExpiry = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(89.999)
        )
        XCTAssertEqual(Set(beforeFirstExpiry.cards.map(\.id)), Set([transcribingID, awaitingID]))
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: pipeline, after: base.addingTimeInterval(20)),
            base.addingTimeInterval(90)
        )

        let afterFirstExpiry = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(90)
        )
        XCTAssertEqual(afterFirstExpiry.cards.map(\.id), [awaitingID])
        XCTAssertEqual(
            afterFirstExpiry.cards[0].content,
            .transcription(
                stage: .awaitingDelivery,
                enqueuedAt: base.addingTimeInterval(10),
                recordingDuration: 10
            )
        )
        XCTAssertTrue(
            MacHUDStack.resolve(
                pipeline: pipeline,
                at: base.addingTimeInterval(100)
            ).isEmpty
        )
    }

    func testSeveralHeldDictationsBecomeOneNewestTransientStatusWithoutCount() {
        let oldest = UUID()
        let middle = UUID()
        let newest = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.markHeld(
            id: newest,
            ordinal: 3,
            createdAt: base.addingTimeInterval(2),
            at: base.addingTimeInterval(5)
        )
        pipeline.markHeld(
            id: oldest,
            ordinal: 1,
            createdAt: base,
            at: base.addingTimeInterval(5)
        )
        pipeline.markHeld(
            id: middle,
            ordinal: 2,
            createdAt: base.addingTimeInterval(1),
            at: base.addingTimeInterval(5)
        )

        let stack = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(6)
        )

        XCTAssertEqual(stack.cards.count, 1)
        XCTAssertEqual(stack.cards[0].id, newest)
        XCTAssertEqual(stack.cards[0].content, .held)
        XCTAssertEqual(stack.cards[0].ordinal, 3)
        XCTAssertTrue(stack.hasTransientHold)
        XCTAssertEqual(pipeline.heldIDs, [oldest, middle, newest])
    }

    func testCardsPreserveSpokenOrdinalsForVoiceOverAndAggregateLabel() {
        let first = UUID()
        let second = UUID()
        var pipeline = pipelineWithTranscriptions([
            (second, 2, 1),
            (first, 1, 0),
        ])
        pipeline.markHeld(id: first, at: base.addingTimeInterval(2))
        let stack = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(3)
        )

        XCTAssertEqual(stack.cards.map(\.ordinal), [2, 1])
        XCTAssertEqual(stack.cards[0].id, second)
        XCTAssertEqual(stack.cards[1].id, first)
        XCTAssertEqual(
            stack.accessibilityLabel(
                sourceName: nil,
                heldClipboardBacked: true
            ),
            "SpeakPaste, 1 dictation transcribing, Dictation held, The held dictation is on the clipboard"
        )
    }

    func testPublisherEmitsDistinctResolvedStackChanges() {
        let subject = CurrentValueSubject<MacHUDPipeline, Never>(MacHUDPipeline())
        var received: [MacHUDStack] = []
        let observation = MacHUDStack.publisher(subject)
            .sink { received.append($0) }
        let id = UUID()
        let now = Date()

        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(id: id, ordinal: 1, at: now)
        subject.send(pipeline)
        subject.send(pipeline)
        pipeline.updateCapture(id: id, activity: .listening, at: now)
        subject.send(pipeline)
        pipeline.beginTranscription(
            id: id,
            ordinal: 1,
            recordingDuration: 3,
            createdAt: now,
            at: now
        )
        subject.send(pipeline)

        XCTAssertEqual(received.count, 4)
        XCTAssertEqual(received[0], .empty)
        XCTAssertEqual(received[1].cards[0].content, .capture(.connecting))
        XCTAssertEqual(received[2].cards[0].content, .capture(.listening))
        XCTAssertEqual(received[3].cards[0].id, id)
        XCTAssertEqual(
            received[3].cards[0].content,
            .transcription(stage: .transcribing, enqueuedAt: now, recordingDuration: 3)
        )
        withExtendedLifetime(observation) {}
    }
}
