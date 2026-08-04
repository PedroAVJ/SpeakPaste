import Foundation

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
    case focusedWritable(Token)
    case clipboardFallback
}

/// The record-start target is recognition/history metadata, not delivery
/// identity. Only the writable focus observed at the output boundary wins.
enum MacDeliveryTargeting {
    static func decide<Token: Equatable>(
        captured _: Token?,
        current: Token?,
        currentIsWritable: Bool
    ) -> MacDeliveryTargetDecision<Token> {
        guard currentIsWritable, let current else { return .clipboardFallback }
        return .focusedWritable(current)
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

/// Safety boundary for side effects that follow the initial delivery target
/// selection. AX replacement is allowed during chunked insertion when no user
/// action occurred; a separate Return is stricter and requires the same live
/// node that was captured after paste confirmation.
enum MacOutputContinuationPolicy {
    static func canContinueMultistepInsertion(
        processIsCurrent: Bool,
        currentIsWritable: Bool,
        currentIsSecure: Bool,
        sameElement: Bool,
        interactionGeneration: UInt64?,
        currentInteractionGeneration: UInt64?
    ) -> Bool {
        guard processIsCurrent, currentIsWritable, !currentIsSecure else {
            return false
        }
        if let interactionGeneration, let currentInteractionGeneration {
            return interactionGeneration == currentInteractionGeneration
        }
        return sameElement
    }

    static func canSendFollowUpReturn(
        processIsCurrent: Bool,
        currentIsWritable: Bool,
        currentIsSecure: Bool,
        sameElement: Bool,
        interactionGeneration: UInt64?,
        currentInteractionGeneration: UInt64?
    ) -> Bool {
        guard sameElement else { return false }
        return canContinueMultistepInsertion(
            processIsCurrent: processIsCurrent,
            currentIsWritable: currentIsWritable,
            currentIsSecure: currentIsSecure,
            sameElement: sameElement,
            interactionGeneration: interactionGeneration,
            currentInteractionGeneration: currentInteractionGeneration
        )
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
