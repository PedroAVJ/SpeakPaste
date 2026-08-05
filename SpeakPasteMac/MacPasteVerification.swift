import Foundation

enum MacDeliveryAttentionState {
    case verifiedPaste
    case unverifiedPaste
    case copied
    case clipboardFallback
    case unavailable
    case held
}

enum MacDeliveryAttentionPolicy {
    static func requiresAttention(_ state: MacDeliveryAttentionState) -> Bool {
        switch state {
        case .verifiedPaste, .copied, .clipboardFallback:
            false
        case .unverifiedPaste, .unavailable, .held:
            true
        }
    }
}

/// Pure verification for accessibility-readable paste destinations.
///
/// Seeing the dictated text somewhere in the final value is not proof that the
/// paste succeeded: the field may already contain that phrase while an
/// unrelated autocorrection changes something else. We only call delivery
/// confirmed when the final UTF-16 value is exactly the original value plus one
/// insertion of the requested text.
enum MacPasteVerification {
    static func isExactInsertion(
        _ insertedText: String,
        before: String?,
        after: String?
    ) -> Bool {
        guard
            !insertedText.isEmpty,
            let before,
            let after
        else {
            return false
        }

        let inserted = Array(insertedText.utf16)
        let original = Array(before.utf16)
        let final = Array(after.utf16)
        guard final.count == original.count + inserted.count else { return false }

        for offset in 0...original.count {
            guard final[offset..<(offset + inserted.count)].elementsEqual(inserted) else {
                continue
            }
            guard final[..<offset].elementsEqual(original[..<offset]) else {
                continue
            }
            guard final[(offset + inserted.count)...].elementsEqual(original[offset...]) else {
                continue
            }
            return true
        }

        return false
    }

    static func hasExactInsertion(
        _ insertedText: String,
        before: String?,
        afterSamples: [String?]
    ) -> Bool {
        afterSamples.contains { after in
            isExactInsertion(insertedText, before: before, after: after)
        }
    }
}

enum MacDeliveryTargetDecision<Token: Equatable>: Equatable {
    case focusedApplication(Token)
    case clipboardFallback
}

/// The record-start target is recognition/history metadata, not delivery
/// identity. Only the application focused at the output boundary wins.
enum MacDeliveryTargeting {
    static func decide<Token: Equatable>(
        captured _: Token?,
        current: Token?
    ) -> MacDeliveryTargetDecision<Token> {
        guard let current else { return .clipboardFallback }
        return .focusedApplication(current)
    }
}

enum MacDeliveryTextPolicy {
    /// Existing recovery text never outranks the just-finished transcript for
    /// the Command-V fallback.
    static func clipboardFallback(
        newestTranscript: String,
        existingRecoveryTranscripts _: [String] = []
    ) -> String {
        newestTranscript
    }
}

/// Decides whether SpeakPaste may restore the clipboard it borrowed for a
/// delivery attempt. A posted but unreadable paste is not a success receipt:
/// terminals and Electron editors often expose no AX value, and the user must
/// still be able to press Command-V when that event was swallowed.
enum MacPasteboardRecoveryPolicy {
    static func shouldKeepTranscript(
        deliveryReachedOutputBoundary: Bool,
        pasteWasVerified: Bool
    ) -> Bool {
        deliveryReachedOutputBoundary && !pasteWasVerified
    }

    /// Once an insertion side effect may have happened, replaying it is never
    /// safe. The durable uncertain entry remains explicit-user-action only.
    static func shouldSuspendAutomaticRetry(
        deliveryReachedOutputBoundary: Bool,
        pasteWasVerified: Bool
    ) -> Bool {
        deliveryReachedOutputBoundary && !pasteWasVerified
    }
}
