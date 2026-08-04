import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation

/// A UTF-16 range matching the units used by macOS Accessibility text APIs.
/// Keeping it value-backed makes the ownership rules independently testable
/// without an AX process or a real destination application.
struct MacRealtimeTextRange: Equatable, Sendable {
    let location: Int
    let length: Int

    var upperBound: Int { location + length }
    var asNSRange: NSRange { NSRange(location: location, length: length) }
    var asCFRange: CFRange { CFRange(location: location, length: length) }
}

struct MacRealtimeTextSnapshot: Equatable, Sendable {
    let value: String
    let selection: MacRealtimeTextRange
}

struct MacRealtimeTextMutation: Equatable, Sendable {
    let replacementRange: MacRealtimeTextRange
    let replacementText: String
    let resultingSnapshot: MacRealtimeTextSnapshot
    let resultingOwnedRange: MacRealtimeTextRange?
}

enum MacRealtimeElementOwnershipPolicy {
    static func permitsResolution(
        valueMatches: Bool,
        sameElement: Bool,
        selectionMatches: Bool,
        capturedInteractionGeneration: UInt64?,
        currentInteractionGeneration: UInt64?
    ) -> Bool {
        guard valueMatches else { return false }
        if sameElement && selectionMatches { return true }
        guard
            let capturedInteractionGeneration,
            let currentInteractionGeneration
        else {
            return false
        }
        return capturedInteractionGeneration == currentInteractionGeneration
    }
}

/// Pure compare-and-swap state for one realtime dictation span.
///
/// A partial transcript is never a delta. Each update may replace only the
/// exact range produced by the preceding update, and only while the entire
/// field value and caret remain byte-for-byte (UTF-16) equal to the expected
/// snapshot. Any mismatch belongs to the user or target app, so the caller must
/// detach instead of guessing at a destructive edit.
struct MacRealtimeTextReconciler: Sendable {
    let originalSnapshot: MacRealtimeTextSnapshot
    let originalSelectedText: String

    private(set) var expectedSnapshot: MacRealtimeTextSnapshot
    private(set) var ownedRange: MacRealtimeTextRange?
    private(set) var provisionalText = ""

    init?(originalSnapshot: MacRealtimeTextSnapshot) {
        guard
            originalSnapshot.selection.length == 0,
            let selected = Self.substring(
                of: originalSnapshot.value,
                in: originalSnapshot.selection
            )
        else {
            return nil
        }
        self.originalSnapshot = originalSnapshot
        originalSelectedText = selected
        expectedSnapshot = originalSnapshot
    }

    var hasProvisionalOutput: Bool { ownedRange != nil }

    func alreadyOwns(text: String) -> Bool {
        ownedRange != nil && provisionalText == text
    }

    /// Available only at the exact post-rollback state. Carrying this snapshot
    /// into durable delivery prevents a later paste from following a caret move
    /// or replacing a new selection in the same field.
    var exactDeliverySnapshot: MacRealtimeTextSnapshot? {
        guard
            ownedRange == nil,
            expectedSnapshot == originalSnapshot
        else {
            return nil
        }
        return originalSnapshot
    }

    func planUpdate(
        currentSnapshot: MacRealtimeTextSnapshot,
        text: String
    ) -> MacRealtimeTextMutation? {
        guard currentSnapshot == expectedSnapshot else { return nil }
        let replacementRange = ownedRange ?? originalSnapshot.selection
        guard
            let resultingValue = Self.replacing(
                currentSnapshot.value,
                range: replacementRange,
                with: text
            )
        else {
            return nil
        }
        let resultingOwnedRange = MacRealtimeTextRange(
            location: originalSnapshot.selection.location,
            length: text.utf16.count
        )
        return MacRealtimeTextMutation(
            replacementRange: replacementRange,
            replacementText: text,
            resultingSnapshot: MacRealtimeTextSnapshot(
                value: resultingValue,
                selection: MacRealtimeTextRange(
                    location: resultingOwnedRange.upperBound,
                    length: 0
                )
            ),
            resultingOwnedRange: resultingOwnedRange
        )
    }

    func planRollback(
        currentSnapshot: MacRealtimeTextSnapshot
    ) -> MacRealtimeTextMutation? {
        guard currentSnapshot == expectedSnapshot else { return nil }
        guard let ownedRange else {
            return MacRealtimeTextMutation(
                replacementRange: originalSnapshot.selection,
                replacementText: originalSelectedText,
                resultingSnapshot: originalSnapshot,
                resultingOwnedRange: nil
            )
        }
        guard
            let resultingValue = Self.replacing(
                currentSnapshot.value,
                range: ownedRange,
                with: originalSelectedText
            ),
            resultingValue == originalSnapshot.value
        else {
            return nil
        }
        return MacRealtimeTextMutation(
            replacementRange: ownedRange,
            replacementText: originalSelectedText,
            resultingSnapshot: originalSnapshot,
            resultingOwnedRange: nil
        )
    }

    mutating func accept(_ mutation: MacRealtimeTextMutation) {
        expectedSnapshot = mutation.resultingSnapshot
        ownedRange = mutation.resultingOwnedRange
        provisionalText = mutation.resultingOwnedRange == nil
            ? ""
            : mutation.replacementText
    }

    private static func substring(
        of value: String,
        in range: MacRealtimeTextRange
    ) -> String? {
        guard let swiftRange = Range(range.asNSRange, in: value) else { return nil }
        return String(value[swiftRange])
    }

    private static func replacing(
        _ value: String,
        range: MacRealtimeTextRange,
        with replacement: String
    ) -> String? {
        guard let swiftRange = Range(range.asNSRange, in: value) else { return nil }
        var result = value
        result.replaceSubrange(swiftRange, with: replacement)
        return result
    }
}

/// Owns the one live AX range used by a realtime capture. Direct AX replacement
/// keeps partial hypotheses out of the clipboard and out of the append-once
/// delivery pipeline. Accessibility has no atomic text transaction, so every
/// write is surrounded by exact focus/value/range checks and an ambiguous
/// result permanently detaches the session.
@MainActor
final class MacRealtimeInlineTextSession {
    private var element: AXUIElement
    private let processIdentifier: pid_t
    /// Right-Command arrives as flagsChanged and does not increment this
    /// tracker. Real typing/clicking does, which lets us distinguish a user's
    /// caret move from Electron rebuilding its focused AX proxy.
    private let interactionGeneration: UInt64?
    private var reconciler: MacRealtimeTextReconciler
    private(set) var isDetached = false
    private(set) var isFinalized = false

    private init(
        element: AXUIElement,
        processIdentifier: pid_t,
        interactionGeneration: UInt64?,
        reconciler: MacRealtimeTextReconciler
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.interactionGeneration = interactionGeneration
        self.reconciler = reconciler
    }

    static func make(
        element capturedElement: AXUIElement,
        processIdentifier: pid_t
    ) -> MacRealtimeInlineTextSession? {
        let interactionGeneration = MacUserInteractionTracker.shared.snapshot
        guard
            !IsSecureEventInputEnabled(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier,
            let focused = MacAccessibility.focusedWritableElement(),
            let capturedSnapshot = MacAccessibility.realtimeTextSnapshot(
                of: capturedElement
            ),
            MacAccessibility.realtimeTextAttributesAreSettable(on: focused),
            let snapshot = MacAccessibility.realtimeTextSnapshot(of: focused),
            (CFEqual(capturedElement, focused) || snapshot == capturedSnapshot),
            snapshot.selection.length == 0,
            let reconciler = MacRealtimeTextReconciler(originalSnapshot: snapshot),
            interactionGeneration == MacUserInteractionTracker.shared.snapshot
        else {
            return nil
        }
        return MacRealtimeInlineTextSession(
            element: focused,
            processIdentifier: processIdentifier,
            interactionGeneration: interactionGeneration,
            reconciler: reconciler
        )
    }

    var hasProvisionalOutput: Bool { reconciler.hasProvisionalOutput }

    var exactDeliverySnapshot: MacRealtimeTextSnapshot? {
        guard !isDetached else { return nil }
        return reconciler.exactDeliverySnapshot
    }

    /// Replaces the complete display hypothesis. Empty messages before the first
    /// real hypothesis are no-ops so the captured caret is not touched merely
    /// because the service emitted an empty partial.
    @discardableResult
    func update(text: String) -> Bool {
        guard !isDetached, !isFinalized else { return false }
        if text.isEmpty, !reconciler.hasProvisionalOutput { return true }
        // Committed and final frames frequently repeat the last full partial.
        // Verify ownership, but do not make Electron process another identical
        // AXSelectedText mutation.
        if reconciler.alreadyOwns(text: text) {
            guard verifiedCurrentSnapshot() != nil else {
                isDetached = true
                return false
            }
            return true
        }
        guard
            let current = verifiedCurrentSnapshot(),
            let mutation = reconciler.planUpdate(
                currentSnapshot: current,
                text: text
            )
        else {
            isDetached = true
            return false
        }
        return apply(mutation)
    }

    /// Replaces the owned provisional span with the exact post-processed final
    /// transcript and relinquishes it in place. This is the verified realtime
    /// delivery boundary; it deliberately avoids erasing visible text and then
    /// asking an Electron Paste menu to put the same words back.
    @discardableResult
    func finalize(text: String) -> Bool {
        guard !isDetached, !isFinalized, update(text: text) else { return false }
        isFinalized = true
        return true
    }

    /// Removes only the exact text this session still proves it owns and
    /// restores the pre-dictation caret. If the user typed, moved the caret,
    /// or changed focus, rollback is refused and nothing is touched.
    @discardableResult
    func rollback() -> Bool {
        guard !isDetached, !isFinalized else { return false }
        guard let current = verifiedCurrentSnapshot() else {
            isDetached = true
            return false
        }
        guard reconciler.hasProvisionalOutput else {
            guard current == reconciler.expectedSnapshot else {
                isDetached = true
                return false
            }
            return true
        }
        guard
            let mutation = reconciler.planRollback(currentSnapshot: current)
        else {
            isDetached = true
            return false
        }
        return apply(mutation)
    }

    var caretFrame: CGRect? {
        guard !isDetached else { return nil }
        return MacAccessibility.realtimeBounds(
            for: reconciler.expectedSnapshot.selection,
            in: element
        )
    }

    private func verifiedCurrentSnapshot() -> MacRealtimeTextSnapshot? {
        resolveElement(requiring: reconciler.expectedSnapshot)
    }

    private func apply(_ mutation: MacRealtimeTextMutation) -> Bool {
        let expectedBeforeMutation = reconciler.expectedSnapshot
        guard
            resolveElement(requiring: expectedBeforeMutation) != nil,
            MacAccessibility.setRealtimeSelection(
                mutation.replacementRange,
                on: element
            ),
            resolveElement(
                requiring: MacRealtimeTextSnapshot(
                    value: expectedBeforeMutation.value,
                    selection: mutation.replacementRange
                )
            ) != nil,
            MacAccessibility.replaceRealtimeSelection(
                with: mutation.replacementText,
                on: element
            ),
            resolveElement(requiring: mutation.resultingSnapshot) != nil
        else {
            // A setter may have succeeded before a later readback failed. That
            // ambiguity is precisely when another edit would be dangerous.
            isDetached = true
            return false
        }
        reconciler.accept(mutation)
        return true
    }

    /// Electron/Chromium may swap the focused AX object or normalize its
    /// selection after a successful setter. Rebind only when the same process
    /// remains frontmost, the complete field value is exactly what we own, and
    /// the global interaction generation proves the user did not type/click.
    /// When monitoring is unavailable, retain the older strict object/range
    /// behavior.
    private func resolveElement(
        requiring expected: MacRealtimeTextSnapshot
    ) -> MacRealtimeTextSnapshot? {
        guard
            !IsSecureEventInputEnabled(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier,
            let focused = MacAccessibility.focusedWritableElement(),
            MacAccessibility.realtimeTextAttributesAreSettable(on: focused),
            var snapshot = MacAccessibility.realtimeTextSnapshot(of: focused),
            snapshot.value == expected.value
        else {
            return nil
        }

        let sameElement = CFEqual(element, focused)
        let selectionMatches = snapshot.selection == expected.selection
        guard MacRealtimeElementOwnershipPolicy.permitsResolution(
            valueMatches: true,
            sameElement: sameElement,
            selectionMatches: selectionMatches,
            capturedInteractionGeneration: interactionGeneration,
            currentInteractionGeneration: MacUserInteractionTracker.shared.snapshot
        ) else {
            return nil
        }
        if !sameElement || !selectionMatches {
            element = focused
            if !selectionMatches {
                guard
                    MacAccessibility.setRealtimeSelection(
                        expected.selection,
                        on: element
                    ),
                    let repaired = MacAccessibility.realtimeTextSnapshot(of: element),
                    repaired == expected
                else {
                    return nil
                }
                snapshot = repaired
            }
        }
        element = focused
        return snapshot == expected ? snapshot : nil
    }
}
