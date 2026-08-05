import XCTest
@testable import SpeakPaste

final class MacRealtimeTextEditTests: XCTestCase {
    func testElectronProxyRebindRequiresUnchangedUserInteractionGeneration() {
        XCTAssertTrue(
            MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: true,
                sameElement: false,
                selectionMatches: false,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 12
            )
        )
        XCTAssertFalse(
            MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: true,
                sameElement: false,
                selectionMatches: true,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 13
            )
        )
        XCTAssertFalse(
            MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: true,
                sameElement: true,
                selectionMatches: true,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 13
            )
        )
        XCTAssertFalse(
            MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: false,
                sameElement: true,
                selectionMatches: true,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 12
            )
        )
    }

    func testInitialBindingRejectsAFieldChangeDuringMicrophoneWarmup() {
        XCTAssertFalse(
            MacRealtimeElementOwnershipPolicy.permitsInitialBinding(
                sameElement: false,
                snapshotMatches: true,
                realtimeElementIsCapturedAncestor: false,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 13
            )
        )
        XCTAssertTrue(
            MacRealtimeElementOwnershipPolicy.permitsInitialBinding(
                sameElement: false,
                snapshotMatches: true,
                realtimeElementIsCapturedAncestor: false,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 12
            )
        )
        XCTAssertFalse(
            MacRealtimeElementOwnershipPolicy.permitsInitialBinding(
                sameElement: false,
                snapshotMatches: true,
                realtimeElementIsCapturedAncestor: false,
                capturedInteractionGeneration: nil,
                currentInteractionGeneration: nil
            )
        )
    }

    func testInitialBindingAcceptsOnlyAnUninterruptedCapturedProxyAncestor() {
        XCTAssertTrue(
            MacRealtimeElementOwnershipPolicy.permitsInitialBinding(
                sameElement: false,
                snapshotMatches: false,
                realtimeElementIsCapturedAncestor: true,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 12
            )
        )
        XCTAssertFalse(
            MacRealtimeElementOwnershipPolicy.permitsInitialBinding(
                sameElement: false,
                snapshotMatches: false,
                realtimeElementIsCapturedAncestor: true,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 13
            )
        )
        XCTAssertFalse(
            MacRealtimeElementOwnershipPolicy.permitsInitialBinding(
                sameElement: false,
                snapshotMatches: false,
                realtimeElementIsCapturedAncestor: false,
                capturedInteractionGeneration: 12,
                currentInteractionGeneration: 12
            )
        )
    }

    func testChromiumReadbackRetriesOldSnapshotThenAcceptsExpectedValue() {
        let policy = MacRealtimeReadbackPolicy()
        XCTAssertEqual(
            policy.observe(
                value: "old",
                previousValue: "old",
                expectedValue: "new"
            ),
            .retry
        )
        XCTAssertEqual(
            policy.observe(
                value: "new",
                previousValue: "old",
                expectedValue: "new"
            ),
            .accept
        )
    }

    func testChromiumReadbackRejectsConflictingUserText() {
        let policy = MacRealtimeReadbackPolicy()
        XCTAssertEqual(
            policy.observe(
                value: "old",
                previousValue: "old",
                expectedValue: "new"
            ),
            .retry
        )
        XCTAssertEqual(
            policy.observe(
                value: "user edit",
                previousValue: "old",
                expectedValue: "new"
            ),
            .reject
        )
    }

    func testRealtimeCandidateSkipsUnusableProxyAndAcceptsTextAreaContract() {
        XCTAssertFalse(
            MacRealtimeWritableCandidatePolicy.accepts(
                isSecure: false,
                isEnabled: true,
                hasReadableSnapshot: true,
                hasSettableTextRange: false
            )
        )
        XCTAssertTrue(
            MacRealtimeWritableCandidatePolicy.accepts(
                isSecure: false,
                isEnabled: true,
                hasReadableSnapshot: true,
                hasSettableTextRange: true
            )
        )
        XCTAssertFalse(
            MacRealtimeWritableCandidatePolicy.accepts(
                isSecure: true,
                isEnabled: true,
                hasReadableSnapshot: true,
                hasSettableTextRange: true
            )
        )
    }

    func testStrictOwnershipStillWorksWithoutInteractionMonitor() {
        XCTAssertTrue(
            MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: true,
                sameElement: true,
                selectionMatches: true,
                capturedInteractionGeneration: nil,
                currentInteractionGeneration: nil
            )
        )
        XCTAssertFalse(
            MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: true,
                sameElement: false,
                selectionMatches: true,
                capturedInteractionGeneration: nil,
                currentInteractionGeneration: nil
            )
        )
    }

    func testPartialCorrectionsReplaceOnlyTheOwnedCaretRangeAndRollbackExactly() throws {
        let original = MacRealtimeTextSnapshot(
            value: "Start  end",
            selection: MacRealtimeTextRange(location: 6, length: 0)
        )
        var reconciler = try XCTUnwrap(
            MacRealtimeTextReconciler(originalSnapshot: original)
        )
        XCTAssertEqual(reconciler.exactDeliverySnapshot, original)

        let first = try XCTUnwrap(
            reconciler.planUpdate(currentSnapshot: original, text: "hel")
        )
        XCTAssertEqual(first.resultingSnapshot.value, "Start hel end")
        reconciler.accept(first)
        XCTAssertTrue(reconciler.alreadyOwns(text: "hel"))
        XCTAssertFalse(reconciler.alreadyOwns(text: "hello"))
        XCTAssertNil(reconciler.exactDeliverySnapshot)

        let corrected = try XCTUnwrap(
            reconciler.planUpdate(
                currentSnapshot: first.resultingSnapshot,
                text: "hello"
            )
        )
        XCTAssertEqual(corrected.resultingSnapshot.value, "Start hello end")
        XCTAssertEqual(corrected.replacementRange, first.resultingOwnedRange)
        reconciler.accept(corrected)

        let rollback = try XCTUnwrap(
            reconciler.planRollback(currentSnapshot: corrected.resultingSnapshot)
        )
        XCTAssertEqual(rollback.resultingSnapshot, original)
        XCTAssertEqual(rollback.replacementText, "")
        reconciler.accept(rollback)
        XCTAssertEqual(reconciler.exactDeliverySnapshot, original)
    }

    func testExternalTypingOrCaretMovementRefusesAnotherMutation() throws {
        let original = MacRealtimeTextSnapshot(
            value: "Draft: ",
            selection: MacRealtimeTextRange(location: 7, length: 0)
        )
        var reconciler = try XCTUnwrap(
            MacRealtimeTextReconciler(originalSnapshot: original)
        )
        let first = try XCTUnwrap(
            reconciler.planUpdate(currentSnapshot: original, text: "hello")
        )
        reconciler.accept(first)

        let externallyEdited = MacRealtimeTextSnapshot(
            value: "Draft: hello!",
            selection: MacRealtimeTextRange(location: 13, length: 0)
        )
        XCTAssertNil(
            reconciler.planUpdate(
                currentSnapshot: externallyEdited,
                text: "hello there"
            )
        )
        XCTAssertNil(
            reconciler.planRollback(currentSnapshot: externallyEdited)
        )
    }

    func testUTF16OwnershipHandlesEmojiHypothesisWithoutTouchingSuffix() throws {
        let original = MacRealtimeTextSnapshot(
            value: "A  Z",
            selection: MacRealtimeTextRange(location: 2, length: 0)
        )
        var reconciler = try XCTUnwrap(
            MacRealtimeTextReconciler(originalSnapshot: original)
        )
        let mutation = try XCTUnwrap(
            reconciler.planUpdate(currentSnapshot: original, text: "👩🏽‍💻")
        )
        XCTAssertEqual(mutation.resultingSnapshot.value, "A 👩🏽‍💻 Z")
        XCTAssertEqual(
            mutation.resultingOwnedRange?.length,
            "👩🏽‍💻".utf16.count
        )
        reconciler.accept(mutation)

        let rollback = try XCTUnwrap(
            reconciler.planRollback(currentSnapshot: mutation.resultingSnapshot)
        )
        XCTAssertEqual(rollback.resultingSnapshot.value, "A  Z")
    }

    func testNonemptyOriginalSelectionIsIneligibleForRealtimeEditing() {
        let original = MacRealtimeTextSnapshot(
            value: "keep me",
            selection: MacRealtimeTextRange(location: 0, length: 4)
        )
        XCTAssertNil(MacRealtimeTextReconciler(originalSnapshot: original))
    }

    func testMovedCaretRefusesRollbackEvenBeforeAnyHypothesis() throws {
        let original = MacRealtimeTextSnapshot(
            value: "Keep this",
            selection: MacRealtimeTextRange(location: 4, length: 0)
        )
        let reconciler = try XCTUnwrap(
            MacRealtimeTextReconciler(originalSnapshot: original)
        )
        let movedCaret = MacRealtimeTextSnapshot(
            value: original.value,
            selection: MacRealtimeTextRange(location: 9, length: 0)
        )

        XCTAssertNil(reconciler.planRollback(currentSnapshot: movedCaret))
    }

    func testOrdinaryBatchDeliveryIgnoresRecordStartIdentity() {
        XCTAssertTrue(
            MacRealtimeFinalDeliveryGuardPolicy.permitsAutomaticDelivery(
                requiresExactSnapshot: false,
                sameProcess: false,
                sameElement: false,
                snapshotMatches: false
            )
        )
    }

    func testRealtimeFinalDeliveryRequiresTheExactRollbackSnapshot() {
        XCTAssertTrue(
            MacRealtimeFinalDeliveryGuardPolicy.permitsAutomaticDelivery(
                requiresExactSnapshot: true,
                sameProcess: true,
                sameElement: true,
                snapshotMatches: true
            )
        )
        XCTAssertFalse(
            MacRealtimeFinalDeliveryGuardPolicy.permitsAutomaticDelivery(
                requiresExactSnapshot: true,
                sameProcess: true,
                sameElement: true,
                snapshotMatches: false
            )
        )
        XCTAssertFalse(
            MacRealtimeFinalDeliveryGuardPolicy.permitsAutomaticDelivery(
                requiresExactSnapshot: true,
                sameProcess: true,
                sameElement: false,
                snapshotMatches: true
            )
        )
    }
}
