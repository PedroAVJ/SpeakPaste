import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation

enum MacPasteRoute: String, Equatable {
    /// The realtime editor replaced and read back its exact owned AX range.
    case realtime = "realtime"
    /// The target application's own Edit ▸ Paste command was invoked.
    case menuAction = "menu"
    /// A synthesized ⌘V was posted.
    case keystroke = "⌘V"
    /// Unicode keyboard events, for destinations that refuse every paste path.
    case typeOut = "typed"
}

/// Why a transcript was not delivered and must be held instead.
enum MacHoldReason: Equatable {
    /// No writable, non-secure editor owns focus at the delivery boundary.
    case noWritableEditor
    case destinationNotFrontmost
    /// Realtime rolled its provisional text back, but the exact field value or
    /// collapsed caret changed before the durable final paste could begin.
    case realtimeDestinationChanged
    /// A password field or Terminal's Secure Keyboard Entry owns the keyboard.
    case secureInput
    /// Every delivery route failed outright.
    case deliveryFailed

    var explanation: String {
        switch self {
        case .noWritableEditor: "no writable editor is focused"
        case .destinationNotFrontmost: "you moved away"
        case .realtimeDestinationChanged:
            "the realtime field or caret changed before final delivery"
        case .secureInput: "a password field is capturing the keyboard"
        case .deliveryFailed: "the destination refused it"
        }
    }
}

enum MacPasteResult: Equatable {
    /// `verified` means SpeakPaste read the destination back and saw the text.
    /// Unverified is not the same as failed — many fields expose no readable
    /// value — but it must never be reported as if it were confirmed.
    case pasted(route: MacPasteRoute, verified: Bool)
    case copied
    /// Automatic insertion had no safe live destination, so the exact newest
    /// transcript is the intentional Command-V handoff.
    case clipboardFallback(MacHoldReason)
    case copiedNeedsAccessibility
    case copiedNeedsKeyboardOutput
    /// The system pasteboard rejected the only attempted output. Callers must
    /// keep the durable transcript escrow instead of treating this as copied.
    case clipboardFailed
    case held(MacHoldReason)

    var detail: String {
        switch self {
        case let .pasted(route, verified):
            if verified {
                "Transcribed and pasted (\(route.rawValue), confirmed)"
            } else {
                "Paste sent (\(route.rawValue)) but unconfirmed; saved recovery entry kept"
            }
        case .copied: "Transcribed and copied"
        case let .clipboardFallback(reason):
            "Clipboard fallback — \(reason.explanation); newest transcript copied"
        case .copiedNeedsAccessibility: "Copied; enable Accessibility for automatic paste"
        case .copiedNeedsKeyboardOutput: "Copied; enable Keyboard Output for synthetic typing"
        case .clipboardFailed: "Clipboard refused the transcript; saved recovery entry kept"
        case let .held(reason): "Held — \(reason.explanation)"
        }
    }

    /// Whether the transcript can stop being tracked as undelivered.
    var isDelivered: Bool {
        if case let .pasted(_, verified) = self { return verified }
        return false
    }

    var permitsAutoSend: Bool {
        if case let .pasted(_, verified) = self { return verified }
        return false
    }

    /// The transcript is preserved, but the requested unattended delivery was
    /// not proven. These outcomes need visible attention and must not inflate
    /// the reliability dashboard's success rate.
    var requiresDeliveryAttention: Bool {
        let state: MacDeliveryAttentionState = switch self {
        case let .pasted(_, verified):
            verified ? .verifiedPaste : .unverifiedPaste
        case .copiedNeedsAccessibility, .copiedNeedsKeyboardOutput,
             .clipboardFailed:
            .unavailable
        case .held:
            .held
        case .copied:
            .copied
        case .clipboardFallback:
            .clipboardFallback
        }
        return MacDeliveryAttentionPolicy.requiresAttention(state)
    }
}

struct MacPasteDeliveryOutcome {
    let result: MacPasteResult
    /// The live delivery-time target, never the record-start context target.
    let target: MacDeliveryTarget?
}

@MainActor
struct MacPasteController {
    private let deliveryGate = MacPasteDeliveryGate.shared
    private static let heldClipboardClaimType = NSPasteboard.PasteboardType(
        "com.pedro.speakpaste.held-clipboard-claim"
    )

    /// Prepared chunks keep their seam open until the delivery transaction owns
    /// the gate and resolves the live focused editor.
    private enum Payload {
        case literal(String)
        case prepared([MacPreparedTranscriptChunk])

        var fallbackText: String {
            switch self {
            case let .literal(text):
                return text
            case let .prepared(chunks):
                if chunks.count == 1, let newestTranscript = chunks.first?.text {
                    return MacDeliveryTextPolicy.clipboardFallback(
                        newestTranscript: newestTranscript
                    )
                }
                return MacDeliveryTextPolicy.clipboardFallback(
                    newestTranscript: MacTranscriptPostProcessor.fold(chunks, after: nil)
                )
            }
        }

        func resolvedForValidatedDestination(
            fallbackPrecedingText: String?
        ) -> String {
            switch self {
            case let .literal(text):
                text
            case let .prepared(chunks):
                MacTranscriptPostProcessor.fold(
                    chunks,
                    after: MacAccessibility.focusedTextBeforeCursor()
                        ?? fallbackPrecedingText
                )
            }
        }
    }

    /// Delivers to the writable editor resolved after the serialized gate is
    /// acquired. `capturedTarget` remains context only and never wins over the
    /// live focus.
    func deliver(
        _ text: String,
        capturedTarget: MacDeliveryTarget?,
        autoPaste: Bool,
        policyForTarget: (MacDeliveryTarget) -> MacDeliveryPolicy? = { _ in nil },
        copyOnHold: Bool = true,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteDeliveryOutcome {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        return await deliverAfterAcquiringGate(
            .literal(text),
            capturedTarget: capturedTarget,
            autoPaste: autoPaste,
            policyForTarget: policyForTarget,
            copyOnHold: copyOnHold,
            heldClipboardOwner: heldClipboardOwner
        )
    }

    /// Finalizes the exact AX range already owned by a realtime session. The
    /// shared gate prevents an older clipboard/menu delivery from interleaving
    /// with this compare-and-swap write. Losing ownership fails closed and
    /// leaves the final text on the clipboard for explicit placement.
    func deliverRealtime(
        _ text: String,
        editor: MacRealtimeInlineTextSession,
        target: MacDeliveryTarget,
        heldClipboardOwner: MacHeldClipboardIdentity
    ) async -> MacPasteDeliveryOutcome {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        guard await editor.finalize(text: text) else {
            return MacPasteDeliveryOutcome(
                result: heldResult(
                    .realtimeDestinationChanged,
                    text: text,
                    copyOnHold: true,
                    heldClipboardOwner: heldClipboardOwner
                ),
                target: target
            )
        }
        return MacPasteDeliveryOutcome(
            result: .pasted(route: .realtime, verified: true),
            target: target
        )
    }

    /// Delivers an intrinsically prepared transcript. Spacing and first-letter
    /// casing are deliberately unresolved until the serialized transaction has
    /// resolved the current writable editor.
    func deliver(
        _ chunk: MacPreparedTranscriptChunk,
        capturedTarget: MacDeliveryTarget?,
        autoPaste: Bool,
        policyForTarget: (MacDeliveryTarget) -> MacDeliveryPolicy? = { _ in nil },
        copyOnHold: Bool = true,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteDeliveryOutcome {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        return await deliverAfterAcquiringGate(
            .prepared([chunk]),
            capturedTarget: capturedTarget,
            autoPaste: autoPaste,
            policyForTarget: policyForTarget,
            copyOnHold: copyOnHold,
            heldClipboardOwner: heldClipboardOwner
        )
    }

    /// Pastes wherever the caret is right now, for the explicit "give it to me
    /// here" shortcut. The user is asking for this destination, so no target
    /// match is required and nothing is activated.
    func pasteAtCurrentFocus(_ text: String) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        guard AXIsProcessTrusted() else {
            return fallbackResult(
                text,
                copyOnHold: true,
                copied: .copiedNeedsAccessibility,
                notCopied: .held(.deliveryFailed)
            )
        }
        guard !MacAccessibility.focusedElementIsSecureText() else {
            return heldResult(.secureInput, text: text, copyOnHold: true)
        }
        guard let manualTarget = MacDeliveryTarget.captureCurrentWritable() else {
            // Clicking a control in SpeakPaste makes SpeakPaste frontmost. Do
            // not paste a transcript into its own editor/search field by
            // accident; preserve it on the clipboard for the user instead.
            return fallbackResult(
                text,
                copyOnHold: true,
                copied: .copied,
                notCopied: .held(.deliveryFailed)
            )
        }
        return await paste(
            .literal(text),
            intoProcess: manualTarget.processIdentifier,
            method: .automatic,
            typeOutFallback: false,
            expectedTarget: nil,
            manualTarget: manualTarget,
            autoSend: false,
            copyOnHold: true
        )
    }

    /// Explicitly releases an ordered prepared run at the current caret. The
    /// target is captured after the delivery gate is acquired and revalidated
    /// again inside `paste`; only then are live seams folded for insertion.
    func pasteAtCurrentFocus(
        _ chunks: [MacPreparedTranscriptChunk],
        copyOnHold: Bool = true
    ) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        func fallbackText() -> String {
            MacTranscriptPostProcessor.fold(chunks, after: nil)
        }
        guard AXIsProcessTrusted() else {
            return fallbackResult(
                fallbackText(),
                copyOnHold: copyOnHold,
                copied: .copiedNeedsAccessibility,
                notCopied: .held(.deliveryFailed)
            )
        }
        guard !MacAccessibility.focusedElementIsSecureText() else {
            return heldResult(
                .secureInput,
                text: fallbackText(),
                copyOnHold: copyOnHold
            )
        }
        guard let manualTarget = MacDeliveryTarget.captureCurrentWritable() else {
            return fallbackResult(
                fallbackText(),
                copyOnHold: copyOnHold,
                copied: .copied,
                notCopied: .held(.deliveryFailed)
            )
        }
        return await paste(
            .prepared(chunks),
            intoProcess: manualTarget.processIdentifier,
            method: .automatic,
            typeOutFallback: false,
            expectedTarget: nil,
            manualTarget: manualTarget,
            autoSend: false,
            copyOnHold: copyOnHold
        )
    }

    private func deliverAfterAcquiringGate(
        _ payload: Payload,
        capturedTarget: MacDeliveryTarget?,
        autoPaste: Bool,
        policyForTarget: (MacDeliveryTarget) -> MacDeliveryPolicy?,
        copyOnHold: Bool,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteDeliveryOutcome {
        func outcome(
            _ result: MacPasteResult,
            target: MacDeliveryTarget? = nil
        ) -> MacPasteDeliveryOutcome {
            MacPasteDeliveryOutcome(result: result, target: target)
        }

        guard autoPaste else {
            return outcome(
                fallbackResult(
                    payload.fallbackText,
                    copyOnHold: copyOnHold,
                    copied: .copied,
                    notCopied: .held(.deliveryFailed),
                    heldClipboardOwner: heldClipboardOwner
                )
            )
        }
        guard AXIsProcessTrusted() else {
            return outcome(
                fallbackResult(
                    payload.fallbackText,
                    copyOnHold: true,
                    copied: .copiedNeedsAccessibility,
                    notCopied: .held(.deliveryFailed)
                )
            )
        }

        if MacAccessibility.focusedElementIsSecureText() {
            return outcome(
                fallbackResult(
                    payload.fallbackText,
                    copyOnHold: true,
                    copied: .clipboardFallback(.secureInput),
                    notCopied: .clipboardFailed
                )
            )
        }

        let currentTarget = MacDeliveryTarget.captureCurrentWritable()
        let targetDecision = MacDeliveryTargeting.decide(
            captured: capturedTarget?.processIdentifier,
            current: currentTarget?.processIdentifier,
            currentIsWritable: currentTarget != nil
        )
        guard
            case .focusedWritable = targetDecision,
            let target = currentTarget
        else {
            return outcome(
                fallbackResult(
                    payload.fallbackText,
                    copyOnHold: true,
                    copied: .clipboardFallback(.noWritableEditor),
                    notCopied: .clipboardFailed
                )
            )
        }

        // The record-start target is metadata for ordinary batch delivery and
        // never outranks this live editor. A realtime-finalized target is the
        // sole exception: its provisional range was rolled back only after an
        // exact full-field/caret snapshot, which must still hold now.
        guard capturedTarget?.permitsAutomaticDelivery(to: target) ?? true else {
            return outcome(
                fallbackResult(
                    payload.fallbackText,
                    copyOnHold: true,
                    copied: .clipboardFallback(.realtimeDestinationChanged),
                    notCopied: .clipboardFailed
                )
            )
        }

        let policy = policyForTarget(target)
        if policy?.deliveryMethod == .clipboardOnly {
            return outcome(
                fallbackResult(
                    payload.fallbackText,
                    copyOnHold: true,
                    copied: .copied,
                    notCopied: .clipboardFailed
                ),
                target: target
            )
        }
        return outcome(
            await paste(
                payload,
                intoProcess: target.processIdentifier,
                method: policy?.deliveryMethod ?? .automatic,
                typeOutFallback: policy?.typeOutFallback ?? false,
                expectedTarget: target,
                autoSend: policy?.autoSend ?? false,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            ),
            target: target
        )
    }

    // MARK: Delivery

    private func paste(
        _ payload: Payload,
        intoProcess processIdentifier: pid_t?,
        method: MacDeliveryMethod,
        typeOutFallback: Bool,
        expectedTarget: MacDeliveryTarget?,
        manualTarget: MacDeliveryTarget? = nil,
        autoSend: Bool,
        copyOnHold: Bool,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteResult {
        func currentUnavailableReason() -> MacHoldReason {
            if IsSecureEventInputEnabled()
                || MacAccessibility.focusedElementIsSecureText() {
                return .secureInput
            }
            return MacAccessibility.focusedElementAcceptsText()
                ? .destinationNotFrontmost
                : .noWritableEditor
        }
        func fallbackBeforeInsertion(_ reason: MacHoldReason) -> MacPasteResult {
            if expectedTarget != nil {
                return fallbackResult(
                    payload.fallbackText,
                    copyOnHold: true,
                    copied: .clipboardFallback(reason),
                    notCopied: .clipboardFailed
                )
            }
            return heldResult(
                reason,
                text: payload.fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        // Checked before anything is written to the pasteboard: while secure
        // input is held, the WindowServer discards synthetic keystrokes and
        // CGEvent.post reports nothing, so a paste would look successful and
        // silently vanish.
        guard !IsSecureEventInputEnabled() else {
            return fallbackBeforeInsertion(.secureInput)
        }

        // An explicit Paste Here has no archived target by design, so recheck
        // the live AX subrole after waiting for another delivery transaction.
        // Browser password fields do not always enable global Secure Event
        // Input, but they still must never receive a retained transcript.
        if expectedTarget == nil, MacAccessibility.focusedElementIsSecureText() {
            return fallbackBeforeInsertion(.secureInput)
        }

        // This is the seam decision boundary. The gate is held and the live
        // destination is checked one final time before reading caret-local
        // text. The application must still own a writable focus, but AX object
        // identity is deliberately irrelevant. If AX cannot expose caret text,
        // use the live capture's snapshot.
        if let expectedTarget, !expectedTarget.canContinueMultistepInsertion {
            return fallbackBeforeInsertion(currentUnavailableReason())
        }
        if let manualTarget, !manualTarget.matchesCurrentManualDestination {
            return fallbackBeforeInsertion(currentUnavailableReason())
        }
        let text = payload.resolvedForValidatedDestination(
            fallbackPrecedingText: expectedTarget?.precedingText
                ?? manualTarget?.precedingText
        )

        if method == .typeOut {
            let result = await typeOut(
                text,
                fallbackText: payload.fallbackText,
                expectedTarget: expectedTarget,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
            let returnTarget = autoSend && result.permitsAutoSend
                ? MacDeliveryTarget.captureCurrentWritable()
                : nil
            return await finishAutoSend(
                after: result,
                requested: autoSend,
                pasteTarget: expectedTarget,
                returnTarget: returnTarget
            )
        }

        let restore = MacPasteboardSnapshot.capture()
        guard copyToPasteboard(text) else {
            return copyOnHold ? .clipboardFailed : .held(.deliveryFailed)
        }
        let ourPasteboardChange = NSPasteboard.general.changeCount
        let before = MacAccessibility.focusedText()

        // The target's own Paste command first. It is layout-independent and
        // unaffected by Secure Event Input, so it fails in strictly fewer
        // situations than a synthesized keystroke.
        let targetIsStillValid: () -> Bool = {
            guard !IsSecureEventInputEnabled() else { return false }
            if let expectedTarget {
                return expectedTarget.canContinueMultistepInsertion
            }
            if let manualTarget {
                return manualTarget.matchesCurrentManualDestination
                    && !MacAccessibility.focusedElementIsSecureText()
            }
            return !MacAccessibility.focusedElementIsSecureText()
        }
        func heldAfterLateTargetChange() -> MacPasteResult {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            return fallbackBeforeInsertion(currentUnavailableReason())
        }

        var route: MacPasteRoute?
        var permitsAlternativeInsertionRoute = true
        if let expectedTarget, !expectedTarget.canContinueMultistepInsertion {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            return fallbackBeforeInsertion(currentUnavailableReason())
        } else if let manualTarget, !manualTarget.matchesCurrentManualDestination {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            return fallbackBeforeInsertion(currentUnavailableReason())
        }
        if let processIdentifier {
            let menuResult = MacAccessibility.pressPasteMenuItem(
                inProcess: processIdentifier,
                validating: targetIsStillValid
            )
            permitsAlternativeInsertionRoute = menuResult.permitsAnotherInsertionRoute
            switch menuResult {
            case .invoked:
                route = .menuAction
            case .focusChanged:
                return heldAfterLateTargetChange()
            case .unavailable:
                break
            }
        }
        if route == nil,
           permitsAlternativeInsertionRoute,
           method != .menuPaste {
            guard targetIsStillValid() else { return heldAfterLateTargetChange() }
            if sendPasteKeystroke() { route = .keystroke }
        }

        guard let route else {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            if typeOutFallback {
                let result = await typeOut(
                    text,
                    fallbackText: payload.fallbackText,
                    expectedTarget: expectedTarget,
                    copyOnHold: copyOnHold,
                    heldClipboardOwner: heldClipboardOwner
                )
                let returnTarget = autoSend && result.permitsAutoSend
                    ? MacDeliveryTarget.captureCurrentWritable()
                    : nil
                return await finishAutoSend(
                    after: result,
                    requested: autoSend,
                    pasteTarget: expectedTarget,
                    returnTarget: returnTarget
                )
            }
            if method != .menuPaste, !CGPreflightPostEventAccess() {
                return fallbackResult(
                    payload.fallbackText,
                    // The live destination was valid and delivery reached
                    // its output boundary. A refused synthetic route must
                    // leave this transcript ready for the user's Command-V,
                    // even when an older recovery entry already exists.
                    copyOnHold: true,
                    copied: .copiedNeedsKeyboardOutput,
                    notCopied: .held(.deliveryFailed),
                    heldClipboardOwner: heldClipboardOwner
                )
            }
            return heldResult(
                .deliveryFailed,
                text: payload.fallbackText,
                copyOnHold: true,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        let verified = await waitForTextToLand(text, before: before)
        if !verified {
            // Neither a successful menu action nor CGEvent.post proves the
            // destination consumed the text. Terminals and Electron editors
            // commonly expose no readable AX value, so every unconfirmed
            // attempt refreshes the clipboard with this exact transcript. An
            // older held item must never make the newest fallback disappear.
            if MacPasteboardRecoveryPolicy.shouldKeepTranscript(
                deliveryReachedOutputBoundary: true,
                pasteWasVerified: verified
            ) {
                _ = copyToPasteboard(
                    payload.fallbackText,
                    heldClipboardOwner: heldClipboardOwner
                )
            }
            return .pasted(route: route, verified: false)
        }
        // Capture the just-confirmed field before the pasteboard restoration
        // delay. A same-app focus switch during that delay must suppress Return,
        // not establish a new baseline in the second editor.
        let returnTarget = autoSend
            ? MacDeliveryTarget.captureCurrentWritable()
            : nil
        // Preserve the old timing guarantee while keeping the transaction
        // serialized: destinations have ample time to consume the pasteboard,
        // but another SpeakPaste delivery cannot interleave with the restore.
        try? await Task.sleep(for: .milliseconds(540))
        restore.restore(ifUnchangedSince: ourPasteboardChange)
        return await finishAutoSend(
            after: .pasted(route: route, verified: verified),
            requested: autoSend,
            pasteTarget: expectedTarget,
            returnTarget: returnTarget
        )
    }

    /// Runs while `deliveryGate` is still held, so another dictation cannot
    /// paste between this transcript and its Return. The live application,
    /// writable focus, and secure-input state are checked at the boundary.
    private func finishAutoSend(
        after result: MacPasteResult,
        requested: Bool,
        pasteTarget: MacDeliveryTarget?,
        returnTarget: MacDeliveryTarget?
    ) async -> MacPasteResult {
        guard
            requested,
            result.permitsAutoSend,
            let pasteTarget,
            let returnTarget,
            pasteTarget.isSameUninterruptedOutputBoundary(as: returnTarget)
        else {
            return result
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard returnTarget.canReceiveFollowUpReturn else { return result }
        _ = sendReturnKeystroke()
        return result
    }

    /// Confirms one exact insertion into a readable field. A bounded poll lets
    /// asynchronous native and Chromium editors publish their AX value without
    /// turning one insertion attempt into a second side effect.
    private func waitForTextToLand(_ text: String, before: String?) async -> Bool {
        var samples: [String?] = []
        for delay in [80, 120, 180] {
            try? await Task.sleep(for: .milliseconds(delay))
            samples.append(MacAccessibility.focusedText())
            if MacPasteVerification.hasExactInsertion(
                text,
                before: before,
                afterSamples: samples
            ) {
                return true
            }
        }
        return false
    }

    /// The one policy boundary for recovery clipboard writes. `copyOnHold`
    /// makes clipboard ownership explicit for manual recovery paths. New live
    /// output always gives the newest transcript precedence separately.
    private func fallbackResult(
        _ text: String,
        copyOnHold: Bool,
        copied: MacPasteResult,
        notCopied: MacPasteResult,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) -> MacPasteResult {
        guard copyOnHold else { return notCopied }
        let claimOwner: MacHeldClipboardIdentity?
        if case .held = copied {
            claimOwner = heldClipboardOwner
        } else {
            claimOwner = nil
        }
        return copyToPasteboard(text, heldClipboardOwner: claimOwner)
            ? copied
            : .clipboardFailed
    }

    private func heldResult(
        _ reason: MacHoldReason,
        text: String,
        copyOnHold: Bool,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) -> MacPasteResult {
        fallbackResult(
            text,
            copyOnHold: copyOnHold,
            copied: .held(reason),
            notCopied: .held(reason),
            heldClipboardOwner: heldClipboardOwner
        )
    }

    @discardableResult
    func copyToPasteboardIfIdle(
        _ text: String,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) -> Bool {
        guard deliveryGate.tryAcquire() else { return false }
        defer { deliveryGate.release() }
        return copyToPasteboard(text, heldClipboardOwner: heldClipboardOwner)
    }

    @discardableResult
    private func copyToPasteboard(
        _ text: String,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) -> Bool {
        let original = MacPasteboardSnapshot.capture()
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        if let heldClipboardOwner {
            let claim = MacHeldClipboardClaim(
                owner: heldClipboardOwner,
                clipboardPayload: text
            )
            guard
                let claimData = try? JSONEncoder().encode(claim),
                item.setData(claimData, forType: Self.heldClipboardClaimType)
            else {
                return false
            }
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([item]) else {
            // Clearing and writing are separate pasteboard operations. If the
            // second one is refused, put back the user's prior clipboard rather
            // than turning a reported failure into unrelated clipboard loss.
            original.restore(ifUnchangedSince: NSPasteboard.general.changeCount)
            return false
        }
        return true
    }

    /// Live pasteboard provenance, validated against the exact string payload.
    /// Copying anything in another app strips this private type, including an
    /// identical-looking string, so the HUD never infers ownership from text.
    func heldClipboardClaim() -> MacHeldClipboardClaim? {
        guard
            let data = NSPasteboard.general.pasteboardItems?.first?.data(
                forType: Self.heldClipboardClaimType
            ),
            let claim = try? JSONDecoder().decode(
                MacHeldClipboardClaim.self,
                from: data
            ),
            NSPasteboard.general.string(forType: .string)
                == claim.clipboardPayload
        else {
            return nil
        }
        return claim
    }

    private func sendPasteKeystroke() -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        let keyCode = MacKeyboardLayout.pasteKeyCode
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        MacUserInteractionTracker.markSynthetic(keyDown)
        MacUserInteractionTracker.markSynthetic(keyUp)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func typeOut(
        _ text: String,
        fallbackText: String,
        expectedTarget: MacDeliveryTarget?,
        copyOnHold: Bool,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteResult {
        guard CGPreflightPostEventAccess() else {
            return fallbackResult(
                fallbackText,
                copyOnHold: copyOnHold,
                copied: .copiedNeedsKeyboardOutput,
                notCopied: .held(.deliveryFailed),
                heldClipboardOwner: heldClipboardOwner
            )
        }
        guard
            let continuationTarget = MacDeliveryTarget.captureCurrentWritable(),
            expectedTarget.map({
                $0.processIdentifier == continuationTarget.processIdentifier
            }) ?? true
        else {
            return heldResult(
                .destinationNotFrontmost,
                text: fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }
        let before = MacAccessibility.focusedText()
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return heldResult(
                .deliveryFailed,
                text: fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        // Short chunks are accepted consistently by Chromium, native AppKit,
        // terminals, and web views. One huge Unicode event is silently
        // truncated by some destinations.
        let characters = Array(text)
        var offset = 0
        while offset < characters.count {
            if !continuationTarget.canContinueMultistepInsertion {
                // Once even one chunk was posted, retrying the full transcript
                // automatically would duplicate that prefix. Report an
                // unconfirmed side effect and preserve the exact newest source
                // transcript for explicit recovery.
                if offset > 0 {
                    preserveUnverifiedTypedOutput(
                        fallbackText,
                        copyOnHold: copyOnHold,
                        heldClipboardOwner: heldClipboardOwner
                    )
                    return .pasted(route: .typeOut, verified: false)
                }
                return heldResult(
                    .destinationNotFrontmost,
                    text: fallbackText,
                    copyOnHold: copyOnHold,
                    heldClipboardOwner: heldClipboardOwner
                )
            }
            let end = min(offset + 16, characters.count)
            let chunk = String(characters[offset..<end])
            guard
                let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: true
                ),
                let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: false
                )
            else {
                if offset > 0 {
                    preserveUnverifiedTypedOutput(
                        fallbackText,
                        copyOnHold: copyOnHold,
                        heldClipboardOwner: heldClipboardOwner
                    )
                    return .pasted(route: .typeOut, verified: false)
                }
                return heldResult(
                    .deliveryFailed,
                    text: fallbackText,
                    copyOnHold: copyOnHold,
                    heldClipboardOwner: heldClipboardOwner
                )
            }
            keyDown.keyboardSetUnicodeString(stringLength: chunk.utf16.count, unicodeString: Array(chunk.utf16))
            keyUp.keyboardSetUnicodeString(stringLength: chunk.utf16.count, unicodeString: Array(chunk.utf16))
            MacUserInteractionTracker.markSynthetic(keyDown)
            MacUserInteractionTracker.markSynthetic(keyUp)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            offset = end
            if offset < characters.count { try? await Task.sleep(for: .milliseconds(4)) }
        }

        let verified = await waitForTextToLand(text, before: before)
        if !verified {
            preserveUnverifiedTypedOutput(
                fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }
        return .pasted(route: .typeOut, verified: verified)
    }

    private func preserveUnverifiedTypedOutput(
        _ text: String,
        copyOnHold _: Bool,
        heldClipboardOwner: MacHeldClipboardIdentity?
    ) {
        // `copyOnHold` controls passive holds before an output attempt. Once
        // typing began, an unverified partial or complete side effect always
        // needs a manual Command-V fallback.
        _ = copyToPasteboard(text, heldClipboardOwner: heldClipboardOwner)
    }

    private func sendReturnKeystroke() -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else {
            return false
        }
        MacUserInteractionTracker.markSynthetic(keyDown)
        MacUserInteractionTracker.markSynthetic(keyUp)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

/// Puts the user's clipboard back after SpeakPaste borrows it to paste.
///
/// Dictation should not cost you whatever you had copied. The restore is
/// skipped when something else has written to the pasteboard in the meantime,
/// so a race cannot clobber a newer copy.
private struct MacPasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> MacPasteboardSnapshot {
        let saved = NSPasteboard.general.pasteboardItems?.map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
        return MacPasteboardSnapshot(items: saved ?? [])
    }

    func restore(ifUnchangedSince changeCount: Int) {
        guard NSPasteboard.general.changeCount == changeCount else { return }
        NSPasteboard.general.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        NSPasteboard.general.writeObjects(restored)
    }
}

/// A tiny async mutex scoped to SpeakPaste's own deliveries. It deliberately
/// lives on the main actor with AppKit instead of blocking a thread with a
/// semaphore while the destination consumes the pasteboard.
@MainActor
private final class MacPasteDeliveryGate {
    static let shared = MacPasteDeliveryGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func tryAcquire() -> Bool {
        guard !isHeld else { return false }
        isHeld = true
        return true
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}
