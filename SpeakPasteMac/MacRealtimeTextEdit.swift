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
    static func permitsInitialBinding(
        sameElement: Bool,
        snapshotMatches: Bool,
        realtimeElementIsCapturedAncestor: Bool,
        capturedInteractionGeneration: UInt64?,
        currentInteractionGeneration: UInt64?
    ) -> Bool {
        guard
            sameElement || snapshotMatches || realtimeElementIsCapturedAncestor
        else {
            return false
        }
        if let capturedInteractionGeneration,
           let currentInteractionGeneration {
            return capturedInteractionGeneration == currentInteractionGeneration
        }
        // Without a complete interaction monitor boundary, only the exact AX
        // object captured before microphone warmup is a safe destination.
        return sameElement
    }

    static func permitsResolution(
        valueMatches: Bool,
        sameElement: Bool,
        selectionMatches: Bool,
        capturedInteractionGeneration: UInt64?,
        currentInteractionGeneration: UInt64?
    ) -> Bool {
        guard valueMatches else { return false }
        if let capturedInteractionGeneration,
           let currentInteractionGeneration {
            return capturedInteractionGeneration == currentInteractionGeneration
        }
        // If monitoring was unavailable at either boundary, do not infer that
        // an Electron proxy replacement or normalized caret is app-owned.
        return sameElement && selectionMatches
    }
}

enum MacRealtimeReadbackDecision: Equatable {
    case accept
    case retry
    case reject
}

/// A successful AX text setter can precede Chromium's readable AX update by a
/// render tick. Retry only an unchanged/nil readback, never the text mutation;
/// any third value is an external edit and fails closed immediately.
struct MacRealtimeReadbackPolicy {
    /// Up to 140 ms covers a busy Chromium render turn while remaining fully
    /// asynchronous and serializing later hypotheses behind this one write.
    static let maximumAttempts = 8
    static let retryDelay: Duration = .milliseconds(20)

    func observe(
        value: String?,
        previousValue: String,
        expectedValue: String
    ) -> MacRealtimeReadbackDecision {
        guard let value else { return .retry }
        if value == expectedValue { return .accept }
        return value == previousValue ? .retry : .reject
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
    private(set) var isClosed = false
    /// AX setters are synchronous, but Chromium publishes their result on a
    /// later render turn. Serialize callers while yielding the main actor so
    /// focus/input monitors remain responsive during bounded readback.
    private var operationIsActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

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
        processIdentifier: pid_t,
        capturedInteractionGeneration: UInt64?
    ) -> MacRealtimeInlineTextSession? {
        let currentInteractionGeneration = MacUserInteractionTracker.shared.snapshot
        guard
            !IsSecureEventInputEnabled(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier,
            let focused = MacAccessibility.focusedRealtimeWritableElement(
                preferred: capturedElement,
                processIdentifier: processIdentifier
            ),
            let snapshot = MacAccessibility.realtimeTextSnapshot(of: focused)
        else {
            return nil
        }
        let sameElement = CFEqual(capturedElement, focused)
        let capturedSnapshotMatches = sameElement
            || MacAccessibility.realtimeTextSnapshot(of: capturedElement) == snapshot
        let realtimeElementIsCapturedAncestor = MacAccessibility.isAncestor(
            focused,
            of: capturedElement,
            processIdentifier: processIdentifier
        )
        guard
            MacRealtimeElementOwnershipPolicy.permitsInitialBinding(
                sameElement: sameElement,
                snapshotMatches: capturedSnapshotMatches,
                realtimeElementIsCapturedAncestor: realtimeElementIsCapturedAncestor,
                capturedInteractionGeneration: capturedInteractionGeneration,
                currentInteractionGeneration: currentInteractionGeneration
            ),
            snapshot.selection.length == 0,
            let reconciler = MacRealtimeTextReconciler(originalSnapshot: snapshot),
            currentInteractionGeneration == MacUserInteractionTracker.shared.snapshot
        else {
            return nil
        }
        return MacRealtimeInlineTextSession(
            element: focused,
            processIdentifier: processIdentifier,
            interactionGeneration: capturedInteractionGeneration,
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
    func update(text: String) async -> Bool {
        await withExclusiveOperation {
            await updateWhileExclusive(text: text)
        }
    }

    private func updateWhileExclusive(text: String) async -> Bool {
        guard !isDetached, !isClosed else { return false }
        if text.isEmpty, !reconciler.hasProvisionalOutput { return true }
        // Committed and final frames frequently repeat the last full partial.
        // Verify ownership, but do not make Electron process another identical
        // AXSelectedText mutation.
        if reconciler.alreadyOwns(text: text) {
            guard await verifiedCurrentSnapshot() != nil else {
                isDetached = true
                return false
            }
            return true
        }
        guard
            let current = await verifiedCurrentSnapshot(),
            let mutation = reconciler.planUpdate(
                currentSnapshot: current,
                text: text
            )
        else {
            isDetached = true
            return false
        }
        return await apply(mutation)
    }

    /// Replaces the owned provisional span with the exact post-processed final
    /// transcript and relinquishes it in place. This is the verified realtime
    /// delivery boundary; it deliberately avoids erasing visible text and then
    /// asking an Electron Paste menu to put the same words back.
    @discardableResult
    func finalize(text: String) async -> Bool {
        await withExclusiveOperation {
            guard
                !isDetached,
                !isClosed,
                await updateWhileExclusive(text: text)
            else {
                return false
            }
            isFinalized = true
            isClosed = true
            return true
        }
    }

    /// Removes only the exact text this session still proves it owns and
    /// restores the pre-dictation caret. If the user typed, moved the caret,
    /// or changed focus, rollback is refused and nothing is touched.
    @discardableResult
    func rollback() async -> Bool {
        await withExclusiveOperation {
            await rollbackWhileExclusive()
        }
    }

    private func rollbackWhileExclusive() async -> Bool {
        guard !isDetached, !isClosed else { return false }
        guard let current = await verifiedCurrentSnapshot() else {
            isDetached = true
            return false
        }
        guard reconciler.hasProvisionalOutput else {
            guard current == reconciler.expectedSnapshot else {
                isDetached = true
                return false
            }
            isClosed = true
            return true
        }
        guard
            let mutation = reconciler.planRollback(currentSnapshot: current)
        else {
            isDetached = true
            return false
        }
        guard await apply(mutation) else { return false }
        isClosed = true
        return true
    }

    /// `willTerminate` cannot await. Normal Quit has already used the async
    /// rollback path; this is a final best-effort exact check for abnormal
    /// lifecycle exits and never polls or repeats a text mutation.
    @discardableResult
    func rollbackImmediately() -> Bool {
        guard !operationIsActive, !isDetached, !isClosed else { return false }
        operationIsActive = true
        defer { releaseExclusiveOperation() }
        guard
            let current = resolveElementImmediately(
                requiring: reconciler.expectedSnapshot
            )
        else {
            isDetached = true
            return false
        }
        guard reconciler.hasProvisionalOutput else {
            isClosed = true
            return true
        }
        guard let mutation = reconciler.planRollback(currentSnapshot: current) else {
            isDetached = true
            return false
        }
        guard applyImmediately(mutation) else { return false }
        isClosed = true
        return true
    }

    var caretFrame: CGRect? {
        guard !isDetached else { return nil }
        return MacAccessibility.realtimeBounds(
            for: reconciler.expectedSnapshot.selection,
            in: element
        )
    }

    private func verifiedCurrentSnapshot() async -> MacRealtimeTextSnapshot? {
        await resolveElement(requiring: reconciler.expectedSnapshot)
    }

    private func apply(_ mutation: MacRealtimeTextMutation) async -> Bool {
        let expectedBeforeMutation = reconciler.expectedSnapshot
        guard await resolveElement(requiring: expectedBeforeMutation) != nil else {
            isDetached = true
            return false
        }
        guard MacAccessibility.setRealtimeSelection(
            mutation.replacementRange,
            on: element
        ) else {
            isDetached = true
            return false
        }
        guard await resolveElement(
                requiring: MacRealtimeTextSnapshot(
                    value: expectedBeforeMutation.value,
                    selection: mutation.replacementRange
                )
            ) != nil
        else {
            isDetached = true
            return false
        }
        guard MacAccessibility.replaceRealtimeSelection(
            with: mutation.replacementText,
            on: element
        ) else {
            isDetached = true
            return false
        }
        guard await resolveElement(
            requiring: mutation.resultingSnapshot,
            transientPreviousValue: expectedBeforeMutation.value
        ) != nil else {
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
        requiring expected: MacRealtimeTextSnapshot,
        transientPreviousValue: String? = nil
    ) async -> MacRealtimeTextSnapshot? {
        let readbackPolicy = MacRealtimeReadbackPolicy()
        let attemptCount = transientPreviousValue == nil
            ? 1
            : MacRealtimeReadbackPolicy.maximumAttempts

        for attempt in 0..<attemptCount {
            guard let observation = currentObservation() else {
                guard transientPreviousValue != nil, attempt + 1 < attemptCount else {
                    return nil
                }
                await waitForChromiumReadback()
                continue
            }
            let focused = observation.element
            let observed = observation.snapshot
            let currentGeneration = observation.interactionGeneration
            let sameElement = CFEqual(element, focused)

            if let transientPreviousValue {
                switch readbackPolicy.observe(
                    value: observed.value,
                    previousValue: transientPreviousValue,
                    expectedValue: expected.value
                ) {
                case .accept:
                    break
                case .retry:
                    if attempt + 1 < attemptCount {
                        await waitForChromiumReadback()
                        continue
                    }
                    return nil
                case .reject:
                    return nil
                }
            } else if observed.value != expected.value {
                return nil
            }

            let selectionMatches = observed.selection == expected.selection
            guard MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: observed.value == expected.value,
                sameElement: sameElement,
                selectionMatches: selectionMatches,
                capturedInteractionGeneration: interactionGeneration,
                currentInteractionGeneration: currentGeneration
            ) else {
                return nil
            }

            element = focused
            if selectionMatches { return observed }
            guard MacAccessibility.setRealtimeSelection(expected.selection, on: element) else {
                return nil
            }
            return await waitForSelectionRepair(
                expected,
                initialInteractionGeneration: currentGeneration
            )
        }
        return nil
    }

    private func waitForSelectionRepair(
        _ expected: MacRealtimeTextSnapshot,
        initialInteractionGeneration: UInt64?
    ) async -> MacRealtimeTextSnapshot? {
        for attempt in 0..<MacRealtimeReadbackPolicy.maximumAttempts {
            guard let observation = currentObservation() else {
                guard attempt + 1 < MacRealtimeReadbackPolicy.maximumAttempts else {
                    return nil
                }
                await waitForChromiumReadback()
                continue
            }
            let sameElement = CFEqual(element, observation.element)
            guard MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: observation.snapshot.value == expected.value,
                sameElement: sameElement,
                selectionMatches: observation.snapshot.selection == expected.selection,
                capturedInteractionGeneration: interactionGeneration,
                currentInteractionGeneration: observation.interactionGeneration
            ), observation.interactionGeneration == initialInteractionGeneration
            else {
                return nil
            }
            guard observation.snapshot.value == expected.value else { return nil }
            if observation.snapshot == expected {
                element = observation.element
                return observation.snapshot
            }
            guard attempt + 1 < MacRealtimeReadbackPolicy.maximumAttempts else {
                return nil
            }
            await waitForChromiumReadback()
        }
        return nil
    }

    private func currentObservation() -> (
        element: AXUIElement,
        snapshot: MacRealtimeTextSnapshot,
        interactionGeneration: UInt64?
    )? {
        guard
            !IsSecureEventInputEnabled(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier,
            let focused = MacAccessibility.focusedRealtimeWritableElement(
                preferred: element,
                processIdentifier: processIdentifier
            ),
            let snapshot = MacAccessibility.realtimeTextSnapshot(of: focused)
        else {
            return nil
        }
        return (
            focused,
            snapshot,
            MacUserInteractionTracker.shared.snapshot
        )
    }

    private func waitForChromiumReadback() async {
        try? await Task.sleep(for: MacRealtimeReadbackPolicy.retryDelay)
    }

    private func resolveElementImmediately(
        requiring expected: MacRealtimeTextSnapshot
    ) -> MacRealtimeTextSnapshot? {
        guard let observation = currentObservation() else { return nil }
        let sameElement = CFEqual(element, observation.element)
        guard
            observation.snapshot == expected,
            MacRealtimeElementOwnershipPolicy.permitsResolution(
                valueMatches: true,
                sameElement: sameElement,
                selectionMatches: true,
                capturedInteractionGeneration: interactionGeneration,
                currentInteractionGeneration: observation.interactionGeneration
            )
        else {
            return nil
        }
        element = observation.element
        return observation.snapshot
    }

    private func applyImmediately(_ mutation: MacRealtimeTextMutation) -> Bool {
        let expectedBeforeMutation = reconciler.expectedSnapshot
        guard
            resolveElementImmediately(requiring: expectedBeforeMutation) != nil,
            MacAccessibility.setRealtimeSelection(
                mutation.replacementRange,
                on: element
            ),
            resolveElementImmediately(
                requiring: MacRealtimeTextSnapshot(
                    value: expectedBeforeMutation.value,
                    selection: mutation.replacementRange
                )
            ) != nil,
            MacAccessibility.replaceRealtimeSelection(
                with: mutation.replacementText,
                on: element
            ),
            MacAccessibility.setRealtimeSelection(
                mutation.resultingSnapshot.selection,
                on: element
            ),
            resolveElementImmediately(requiring: mutation.resultingSnapshot) != nil
        else {
            isDetached = true
            return false
        }
        reconciler.accept(mutation)
        return true
    }

    private func withExclusiveOperation<Result>(
        _ operation: () async -> Result
    ) async -> Result {
        await acquireExclusiveOperation()
        defer { releaseExclusiveOperation() }
        return await operation()
    }

    private func acquireExclusiveOperation() async {
        guard operationIsActive else {
            operationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseExclusiveOperation() {
        guard !operationWaiters.isEmpty else {
            operationIsActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}
