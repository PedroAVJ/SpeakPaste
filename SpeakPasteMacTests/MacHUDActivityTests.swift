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
                NSImage(systemSymbolName: name, accessibilityDescription: nil)
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

final class MacHUDVisualStateTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 10_000)

    func testMacCourtesyBeatEndsOnVoiceOrHalfSecondCap() {
        let content = MacHUDStack.CardContent.capture(
            source: .mac,
            activity: .listening,
            stageStartedAt: base
        )

        XCTAssertEqual(
            MacHUDVisualState.resolve(
                content: content,
                inputLevel: 0,
                at: base.addingTimeInterval(0.49)
            ),
            .source(.mac, waiting: false)
        )
        XCTAssertEqual(
            MacHUDVisualState.resolve(
                content: content,
                inputLevel: MacHUDVisualState.voiceCutoffLevel,
                at: base.addingTimeInterval(0.2)
            ),
            .waveform(frozen: false)
        )
        XCTAssertEqual(
            MacHUDVisualState.resolve(
                content: content,
                inputLevel: 0,
                at: base.addingTimeInterval(MacHUDStack.macStartVisibilityCap)
            ),
            .waveform(frozen: false)
        )
    }

    func testPhoneAndNonCaptureFacesResolveWithoutCourtesyTiming() {
        XCTAssertEqual(
            MacHUDVisualState.resolve(
                content: .capture(
                    source: .iPhone,
                    activity: .connecting,
                    stageStartedAt: base
                ),
                inputLevel: 0,
                at: base
            ),
            .source(.iPhone, waiting: true)
        )
        XCTAssertEqual(
            MacHUDVisualState.resolve(
                content: .capture(
                    source: .iPhone,
                    activity: .listening,
                    stageStartedAt: base
                ),
                inputLevel: 0,
                at: base
            ),
            .waveform(frozen: false)
        )
        XCTAssertEqual(
            MacHUDVisualState.resolve(content: .resting, inputLevel: 0, at: base),
            .waveform(frozen: true)
        )
        XCTAssertEqual(
            MacHUDVisualState.resolve(content: .draining, inputLevel: 0, at: base),
            .typing
        )
    }
}

final class MacOrderedDictationBatchTests: XCTestCase {
    func testClosedDictationWaitsForEveryPausedSegment() {
        let batch = MacOrderedDictationBatch(sequences: [4, 5, 6])

        XCTAssertTrue(batch.starts(at: 4))
        XCTAssertFalse(batch.isReady(completedSequences: [4, 6]))
        XCTAssertTrue(batch.isReady(completedSequences: [4, 5, 6, 9]))
        XCTAssertEqual(batch.orderedSequences, [4, 5, 6])
    }

    func testLaterClosedDictationCannotOvertakeEarlierTicket() {
        let batch = MacOrderedDictationBatch(sequences: [8, 9])

        XCTAssertFalse(batch.starts(at: 7))
        XCTAssertTrue(batch.starts(at: 8))
    }
}

final class MacHUDStackTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 10_000)

    func testEmptyPipelineResolvesToEmptyHUD() {
        let pipeline = MacHUDPipeline()
        XCTAssertEqual(MacHUDStack.resolve(pipeline: pipeline, at: base), .empty)
        XCTAssertNil(MacHUDStack.nextExpiry(in: pipeline, after: base))
    }

    func testPositioningPreviewIsOneWordlessStableCapsule() {
        XCTAssertEqual(MacHUDStack.positioning.cards.count, 1)
        XCTAssertEqual(MacHUDStack.positioning.cards.first?.content, .positioning)
        XCTAssertEqual(
            MacHUDStack.positioning.accessibilityLabel(sourceName: nil),
            "SpeakPaste, Move mode. Drag the capsule, then choose Done Moving HUD from the menu bar"
        )
    }

    func testMacAndIPhoneStartsCarryNeutralSourceIdentityInOneCard() {
        let macID = UUID()
        var mac = MacHUDPipeline()
        mac.beginCapture(
            id: macID,
            ordinal: 1,
            source: .mac,
            at: base
        )
        XCTAssertEqual(
            MacHUDStack.resolve(pipeline: mac, at: base).cards,
            [
                MacHUDStack.Card(
                    id: macID,
                    content: .capture(
                        source: .mac,
                        activity: .connecting,
                        stageStartedAt: base
                    )
                )
            ]
        )

        let phoneID = UUID()
        var phone = MacHUDPipeline()
        phone.beginCapture(
            id: phoneID,
            ordinal: 1,
            source: .iPhone,
            at: base
        )
        XCTAssertEqual(
            MacHUDStack.resolve(pipeline: phone, at: base).cards.first?.content,
            .capture(
                source: .iPhone,
                activity: .connecting,
                stageStartedAt: base
            )
        )
    }

    func testMacCourtesyBeatCapsAtHalfASecondWhileIPhoneWaitsForCaptureLive() {
        var mac = MacHUDPipeline()
        let macID = UUID()
        mac.beginCapture(id: macID, ordinal: 1, source: .mac, at: base)
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: mac, after: base),
            base.addingTimeInterval(MacHUDStack.macStartVisibilityCap)
        )
        XCTAssertTrue(
            MacHUDStack.resolve(
                pipeline: mac,
                at: base.addingTimeInterval(MacHUDStack.macStartVisibilityCap)
            ).isEmpty
        )

        mac.updateCapture(
            id: macID,
            activity: .listening,
            at: base.addingTimeInterval(0.2)
        )
        XCTAssertEqual(
            MacHUDStack.resolve(
                pipeline: mac,
                at: base.addingTimeInterval(0.2)
            ).cards.first?.content,
            .capture(
                source: .mac,
                activity: .listening,
                stageStartedAt: base
            )
        )

        var phone = MacHUDPipeline()
        phone.beginCapture(id: UUID(), ordinal: 1, source: .iPhone, at: base)
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: phone, after: base),
            base.addingTimeInterval(MacHUDStack.connectingVisibilityCap)
        )
        XCTAssertFalse(
            MacHUDStack.resolve(
                pipeline: phone,
                at: base.addingTimeInterval(1)
            ).isEmpty
        )
    }

    func testOneFaceKeepsItsIdentityAcrossPauseResumeAndNewSegments() {
        let firstSegment = UUID()
        let secondSegment = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(
            id: firstSegment,
            ordinal: 1,
            source: .mac,
            at: base
        )
        let faceID = pipeline.visibleFaceID

        pipeline.updateCapture(
            id: firstSegment,
            activity: .listening,
            at: base.addingTimeInterval(1)
        )
        pipeline.beginTranscription(
            id: firstSegment,
            ordinal: 1,
            recordingDuration: 3,
            createdAt: base,
            at: base.addingTimeInterval(2)
        )
        pipeline.beginResting(at: base.addingTimeInterval(2))

        let resting = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(30)
        )
        XCTAssertEqual(resting.cards.count, 1)
        XCTAssertEqual(resting.cards.first?.id, faceID)
        XCTAssertEqual(resting.cards.first?.content, .resting)
        XCTAssertFalse(pipeline.isTyping)

        pipeline.beginCapture(
            id: secondSegment,
            ordinal: 2,
            source: .iPhone,
            at: base.addingTimeInterval(31)
        )
        pipeline.updateCapture(
            id: secondSegment,
            activity: .listening,
            at: base.addingTimeInterval(33)
        )

        let resumed = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(33)
        )
        XCTAssertEqual(resumed.cards.count, 1)
        XCTAssertEqual(resumed.cards.first?.id, faceID)
        XCTAssertEqual(
            resumed.cards.first?.content,
            .capture(
                source: .iPhone,
                activity: .listening,
                stageStartedAt: base.addingTimeInterval(33)
            )
        )
    }

    func testBankedSegmentTranscriptionNeverGetsItsOwnFace() {
        let segment = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(
            id: segment,
            ordinal: 1,
            source: .mac,
            at: base
        )
        pipeline.beginTranscription(
            id: segment,
            ordinal: 1,
            recordingDuration: 10,
            createdAt: base,
            at: base.addingTimeInterval(1)
        )
        pipeline.beginResting(at: base.addingTimeInterval(1))

        let stack = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(20)
        )
        XCTAssertEqual(stack.cards.map(\.content), [.resting])
        XCTAssertEqual(stack.cards.count, MacHUDStack.visibleCardBudget)
        XCTAssertFalse(pipeline.isTyping)
    }

    func testWrongSourceNudgeTemporarilyReplacesRatherThanStacksOnFace() {
        let segment = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(
            id: segment,
            ordinal: 1,
            source: .mac,
            at: base
        )
        pipeline.updateCapture(
            id: segment,
            activity: .listening,
            at: base
        )
        pipeline.showWrongSourceNudge(
            attempted: .iPhone,
            live: .mac,
            at: base.addingTimeInterval(1)
        )

        let nudged = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(1.2)
        )
        XCTAssertEqual(nudged.cards.count, 1)
        XCTAssertEqual(nudged.cards.first?.id, pipeline.visibleFaceID)
        XCTAssertEqual(
            nudged.cards.first?.content,
            .sourceNudge(attempted: .iPhone, live: .mac)
        )

        let restored = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(
                1 + MacHUDStack.sourceNudgeVisibilityCap + 0.001
            )
        )
        XCTAssertEqual(
            restored.cards.first?.content,
            .capture(source: .mac, activity: .listening, stageStartedAt: base)
        )
    }

    func testDrainingGroupsEverySegmentIntoOneTypingFace() {
        let first = UUID()
        let second = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(
            id: first,
            ordinal: 1,
            source: .mac,
            at: base
        )
        let faceID = pipeline.visibleFaceID
        pipeline.beginTranscription(
            id: first,
            ordinal: 1,
            recordingDuration: 4,
            createdAt: base,
            at: base.addingTimeInterval(1)
        )
        pipeline.beginResting(at: base.addingTimeInterval(1))
        pipeline.beginCapture(
            id: second,
            ordinal: 2,
            source: .mac,
            at: base.addingTimeInterval(2)
        )
        pipeline.beginTranscription(
            id: second,
            ordinal: 2,
            recordingDuration: 5,
            createdAt: base.addingTimeInterval(2),
            at: base.addingTimeInterval(3)
        )
        pipeline.beginDraining(at: base.addingTimeInterval(3))

        let stack = MacHUDStack.resolve(
            pipeline: pipeline,
            at: base.addingTimeInterval(4)
        )
        XCTAssertEqual(stack.cards, [MacHUDStack.Card(id: faceID!, content: .draining)])
        XCTAssertTrue(pipeline.isTyping)
        XCTAssertFalse(pipeline.finishesDrainingFace(withWorkID: first))
        XCTAssertFalse(pipeline.finishesDrainingFace(withWorkID: second))

        pipeline.finish(id: first)
        XCTAssertTrue(pipeline.finishesDrainingFace(withWorkID: second))
        XCTAssertEqual(pipeline.visibleFaceID, faceID)
        pipeline.finish(id: second)
        XCTAssertNil(pipeline.visibleFaceID)
        XCTAssertFalse(pipeline.isTyping)
    }

    func testNewCaptureAfterHeldAcknowledgmentGetsFreshDictationIdentity() {
        let heldWork = UUID()
        let newCapture = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.markHeld(id: heldWork, at: base)
        let heldFaceID = pipeline.visibleFaceID

        pipeline.beginCapture(
            id: newCapture,
            ordinal: 2,
            source: .mac,
            at: base.addingTimeInterval(1)
        )

        XCTAssertEqual(pipeline.visibleFaceID, newCapture)
        XCTAssertNotEqual(pipeline.visibleFaceID, heldFaceID)
        XCTAssertEqual(pipeline.faceIDs(forWorkIDs: [heldWork]), [heldFaceID!])
    }

    func testRestingNeverExpiresButDrainingAndHeldDo() {
        let segment = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(
            id: segment,
            ordinal: 1,
            source: .mac,
            at: base
        )
        pipeline.beginResting(at: base)
        XCTAssertNil(MacHUDStack.nextExpiry(in: pipeline, after: base))
        XCTAssertFalse(
            MacHUDStack.resolve(
                pipeline: pipeline,
                at: base.addingTimeInterval(10_000)
            ).isEmpty
        )

        pipeline.beginTranscription(
            id: segment,
            ordinal: 1,
            recordingDuration: 2,
            createdAt: base,
            at: base
        )
        pipeline.beginDraining(at: base)
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: pipeline, after: base),
            base.addingTimeInterval(MacHUDStack.drainingVisibilityCap)
        )
        XCTAssertTrue(
            MacHUDStack.resolve(
                pipeline: pipeline,
                at: base.addingTimeInterval(MacHUDStack.drainingVisibilityCap)
            ).isEmpty
        )

        pipeline.markHeld(id: segment, at: base)
        XCTAssertEqual(
            MacHUDStack.nextExpiry(in: pipeline, after: base),
            base.addingTimeInterval(MacHUDStack.heldVisibilityCap)
        )
    }

    func testDismissDetachesWorkSoRecoveryCannotReplayTheHUD() {
        let segment = UUID()
        var pipeline = MacHUDPipeline()
        pipeline.beginCapture(
            id: segment,
            ordinal: 1,
            source: .mac,
            at: base
        )
        pipeline.beginTranscription(
            id: segment,
            ordinal: 1,
            recordingDuration: 2,
            createdAt: base,
            at: base
        )
        let faceID = pipeline.visibleFaceID
        pipeline.dismissFace()

        XCTAssertTrue(MacHUDStack.resolve(pipeline: pipeline, at: base).isEmpty)
        XCTAssertEqual(pipeline.faceIDs(forWorkIDs: [segment]), [])
        pipeline.markHeld(id: segment, at: base.addingTimeInterval(1))
        XCTAssertNil(pipeline.visibleFaceID)
        XCTAssertNotNil(faceID)
    }

    func testPublisherSuppressesDuplicateOneFaceSnapshots() {
        let subject = CurrentValueSubject<MacHUDPipeline, Never>(MacHUDPipeline())
        var received: [MacHUDStack] = []
        let observation = MacHUDStack.publisher(subject).sink { received.append($0) }

        subject.send(MacHUDPipeline())
        var pipeline = MacHUDPipeline()
        let now = Date()
        pipeline.beginCapture(
            id: UUID(),
            ordinal: 1,
            source: .iPhone,
            at: now
        )
        subject.send(pipeline)
        subject.send(pipeline)

        XCTAssertEqual(received.count, 2)
        withExtendedLifetime(observation) {}
    }
}
