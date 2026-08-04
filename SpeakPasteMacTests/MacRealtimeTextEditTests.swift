import XCTest
@testable import SpeakPaste

final class MacRealtimeTextEditTests: XCTestCase {
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
