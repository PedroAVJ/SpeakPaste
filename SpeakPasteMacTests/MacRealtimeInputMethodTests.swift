import XCTest
@testable import SpeakPaste

final class MacRealtimeInputMethodTests: XCTestCase {
    func testAttachmentRequiresTheClaimedSessionAndExactActiveClient() {
        let receipt = makeReceipt(
            action: "begin",
            result: "ready",
            sessionID: "session-a",
            clientBundleID: "com.openai.codex"
        )
        XCTAssertTrue(
            MacRealtimeInputMethodReceiptPolicy.acceptsAttachment(
                receipt,
                sessionID: "session-a",
                targetBundleID: "com.openai.codex"
            )
        )
        XCTAssertFalse(
            MacRealtimeInputMethodReceiptPolicy.acceptsAttachment(
                receipt,
                sessionID: "session-b",
                targetBundleID: "com.openai.codex"
            )
        )
        XCTAssertFalse(
            MacRealtimeInputMethodReceiptPolicy.acceptsAttachment(
                receipt,
                sessionID: "session-a",
                targetBundleID: "com.anthropic.claudefordesktop"
            )
        )
    }

    func testUpdateRequiresAppliedReceiptForExactRevision() {
        let applied = makeReceipt(
            action: "update",
            result: "applied",
            sessionID: "session-a",
            revision: 7
        )
        XCTAssertTrue(
            MacRealtimeInputMethodReceiptPolicy.acceptsUpdate(
                applied,
                sessionID: "session-a",
                revision: 7
            )
        )
        XCTAssertFalse(
            MacRealtimeInputMethodReceiptPolicy.acceptsUpdate(
                applied,
                sessionID: "session-a",
                revision: 8
            )
        )
        XCTAssertFalse(
            MacRealtimeInputMethodReceiptPolicy.acceptsUpdate(
                makeReceipt(
                    action: "update",
                    result: "range_mismatch",
                    sessionID: "session-a",
                    revision: 7
                ),
                sessionID: "session-a",
                revision: 7
            )
        )
    }

    func testCommitDistinguishesExactReadbackFromAmbiguousOneShotInsertion() {
        XCTAssertEqual(
            MacRealtimeInputMethodReceiptPolicy.commitResult(
                makeReceipt(
                    action: "finish",
                    result: "committed",
                    sessionID: "session-a",
                    revision: 12
                ),
                sessionID: "session-a",
                revision: 12
            ),
            .verified
        )
        XCTAssertEqual(
            MacRealtimeInputMethodReceiptPolicy.commitResult(
                makeReceipt(
                    action: "finish",
                    result: "committed_unverified",
                    sessionID: "session-a",
                    revision: 12
                ),
                sessionID: "session-a",
                revision: 12
            ),
            .unverified
        )
        XCTAssertEqual(
            MacRealtimeInputMethodReceiptPolicy.commitResult(
                nil,
                sessionID: "session-a",
                revision: 12
            ),
            .unverified
        )
    }

    func testCommitRejectsStaleOrForeignReceipts() {
        let receipt = makeReceipt(
            action: "finish",
            result: "committed",
            sessionID: "session-a",
            revision: 11
        )
        XCTAssertEqual(
            MacRealtimeInputMethodReceiptPolicy.commitResult(
                receipt,
                sessionID: "session-a",
                revision: 12
            ),
            .failed
        )
        XCTAssertEqual(
            MacRealtimeInputMethodReceiptPolicy.commitResult(
                receipt,
                sessionID: "session-b",
                revision: 11
            ),
            .failed
        )
    }

    private func makeReceipt(
        action: String,
        result: String,
        sessionID: String,
        clientBundleID: String? = nil,
        revision: UInt64 = 0
    ) -> MacRealtimeInputMethodReceipt {
        MacRealtimeInputMethodReceipt(
            action: action,
            result: result,
            requestID: UUID().uuidString,
            sessionID: sessionID,
            clientBundleID: clientBundleID,
            revision: revision,
            controllerGeneration: 3
        )
    }
}
