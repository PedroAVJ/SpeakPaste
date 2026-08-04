import AppKit
@preconcurrency import ApplicationServices
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
    private let element: AXUIElement
    private let processIdentifier: pid_t
    private var reconciler: MacRealtimeTextReconciler
    private(set) var isDetached = false
    private(set) var isFinalized = false

    private init(
        element: AXUIElement,
        processIdentifier: pid_t,
        reconciler: MacRealtimeTextReconciler
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.reconciler = reconciler
    }

    static func make(
        element: AXUIElement,
        processIdentifier: pid_t
    ) -> MacRealtimeInlineTextSession? {
        guard
            MacAccessibility.exactElementHoldsFocus(
                element,
                processIdentifier: processIdentifier
            ),
            MacAccessibility.realtimeTextAttributesAreSettable(on: element),
            let snapshot = MacAccessibility.realtimeTextSnapshot(of: element),
            snapshot.selection.length == 0,
            let reconciler = MacRealtimeTextReconciler(originalSnapshot: snapshot)
        else {
            return nil
        }
        return MacRealtimeInlineTextSession(
            element: element,
            processIdentifier: processIdentifier,
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
        guard
            MacAccessibility.exactElementHoldsFocus(
                element,
                processIdentifier: processIdentifier
            )
        else {
            return nil
        }
        return MacAccessibility.realtimeTextSnapshot(of: element)
    }

    private func apply(_ mutation: MacRealtimeTextMutation) -> Bool {
        let expectedBeforeMutation = reconciler.expectedSnapshot
        guard
            MacAccessibility.setRealtimeSelection(
                mutation.replacementRange,
                on: element
            ),
            MacAccessibility.exactElementHoldsFocus(
                element,
                processIdentifier: processIdentifier
            ),
            MacAccessibility.realtimeTextSnapshot(of: element)
                == MacRealtimeTextSnapshot(
                    value: expectedBeforeMutation.value,
                    selection: mutation.replacementRange
                ),
            MacAccessibility.replaceRealtimeSelection(
                with: mutation.replacementText,
                on: element
            ),
            MacAccessibility.setRealtimeSelection(
                mutation.resultingSnapshot.selection,
                on: element
            ),
            MacAccessibility.exactElementHoldsFocus(
                element,
                processIdentifier: processIdentifier
            ),
            MacAccessibility.realtimeTextSnapshot(of: element)
                == mutation.resultingSnapshot
        else {
            // A setter may have succeeded before a later readback failed. That
            // ambiguity is precisely when another edit would be dangerous.
            isDetached = true
            return false
        }
        reconciler.accept(mutation)
        return true
    }
}
