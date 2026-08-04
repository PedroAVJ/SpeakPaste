import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation

enum MacPasteRoute: String, Equatable {
    /// The target application's own Edit ▸ Paste command was invoked.
    case menuAction = "menu"
    /// A synthesized ⌘V was posted.
    case keystroke = "⌘V"
    /// Unicode keyboard events, for destinations that refuse every paste path.
    case typeOut = "typed"
}

/// Why a transcript was not delivered and must be held instead.
enum MacHoldReason: Equatable {
    case destinationNotFrontmost
    /// A password field or Terminal's Secure Keyboard Entry owns the keyboard.
    case secureInput
    /// Every delivery route failed outright.
    case deliveryFailed

    var explanation: String {
        switch self {
        case .destinationNotFrontmost: "you moved away"
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
        switch self {
        case let .pasted(_, verified):
            !verified
        case .copiedNeedsAccessibility, .copiedNeedsKeyboardOutput, .clipboardFailed:
            true
        case .copied, .held:
            false
        }
    }
}

@MainActor
struct MacPasteController {
    private let deliveryGate = MacPasteDeliveryGate.shared
    private static let heldClipboardClaimType = NSPasteboard.PasteboardType(
        "com.pedro.speakpaste.held-clipboard-claim"
    )

    /// A literal payload preserves the legacy controller API. Prepared chunks
    /// keep their seam open until the delivery transaction owns the gate and
    /// has revalidated the exact focused field.
    private enum Payload {
        case literal(String)
        case prepared([MacPreparedTranscriptChunk], fallbackPrecedingText: String?)

        var fallbackText: String {
            switch self {
            case let .literal(text):
                text
            case let .prepared(chunks, precedingText):
                MacTranscriptPostProcessor.fold(chunks, after: precedingText)
            }
        }

        func resolvedForValidatedDestination() -> String {
            switch self {
            case let .literal(text):
                text
            case let .prepared(chunks, fallbackPrecedingText):
                MacTranscriptPostProcessor.fold(
                    chunks,
                    after: MacAccessibility.focusedTextBeforeCursor()
                        ?? fallbackPrecedingText
                )
            }
        }
    }

    /// Delivers text to `target` when it is safe to do so, and returns `.held`
    /// otherwise. Guessing at a destination is how dictation ends up in the
    /// wrong channel or a password field, so the caller holds instead.
    func deliver(
        _ text: String,
        to target: MacDeliveryTarget?,
        autoPaste: Bool,
        policy: MacDeliveryPolicy? = nil,
        copyOnHold: Bool = true,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        return await deliverAfterAcquiringGate(
            .literal(text),
            to: target,
            autoPaste: autoPaste,
            policy: policy,
            copyOnHold: copyOnHold,
            heldClipboardOwner: heldClipboardOwner
        )
    }

    /// Delivers an intrinsically prepared transcript. Spacing and first-letter
    /// casing are deliberately unresolved until the serialized transaction has
    /// proved the captured AX element is still focused.
    func deliver(
        _ chunk: MacPreparedTranscriptChunk,
        to target: MacDeliveryTarget?,
        autoPaste: Bool,
        policy: MacDeliveryPolicy? = nil,
        copyOnHold: Bool = true,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        return await deliverAfterAcquiringGate(
            .prepared([chunk], fallbackPrecedingText: target?.precedingText),
            to: target,
            autoPaste: autoPaste,
            policy: policy,
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
        guard let manualTarget = MacDeliveryTarget.captureCurrent() else {
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
            activating: false,
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
        guard let manualTarget = MacDeliveryTarget.captureCurrent() else {
            return fallbackResult(
                fallbackText(),
                copyOnHold: copyOnHold,
                copied: .copied,
                notCopied: .held(.deliveryFailed)
            )
        }
        return await paste(
            .prepared(chunks, fallbackPrecedingText: manualTarget.precedingText),
            intoProcess: manualTarget.processIdentifier,
            activating: false,
            method: .automatic,
            typeOutFallback: false,
            expectedTarget: nil,
            manualTarget: manualTarget,
            autoSend: false,
            copyOnHold: copyOnHold
        )
    }

    /// Commits an automatically held transcript back to the exact field it was
    /// captured from. Unlike the explicit "Paste Here" action, this keeps the
    /// target identity all the way through the serialized delivery gate.
    func deliverHeld(
        _ text: String,
        to target: MacDeliveryTarget,
        policy: MacDeliveryPolicy?,
        copyOnHold: Bool = true
    ) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        return await deliverHeldAfterAcquiringGate(
            .literal(text),
            to: target,
            policy: policy,
            copyOnHold: copyOnHold
        )
    }

    /// Releases one exact-field held run in spoken order. Folding happens only
    /// after the target is revalidated, so every seam sees the live caret text
    /// plus the chunks already folded ahead of it.
    func deliverHeld(
        _ chunks: [MacPreparedTranscriptChunk],
        to target: MacDeliveryTarget,
        policy: MacDeliveryPolicy?,
        copyOnHold: Bool = true
    ) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        return await deliverHeldAfterAcquiringGate(
            .prepared(chunks, fallbackPrecedingText: target.precedingText),
            to: target,
            policy: policy,
            copyOnHold: copyOnHold
        )
    }

    private func deliverAfterAcquiringGate(
        _ payload: Payload,
        to target: MacDeliveryTarget?,
        autoPaste: Bool,
        policy: MacDeliveryPolicy?,
        copyOnHold: Bool,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteResult {
        guard autoPaste, let target else {
            return fallbackResult(
                payload.fallbackText,
                copyOnHold: copyOnHold,
                copied: .copied,
                notCopied: .held(.deliveryFailed),
                heldClipboardOwner: heldClipboardOwner
            )
        }
        guard AXIsProcessTrusted() else {
            return fallbackResult(
                payload.fallbackText,
                copyOnHold: copyOnHold,
                copied: .copiedNeedsAccessibility,
                notCopied: .held(.deliveryFailed),
                heldClipboardOwner: heldClipboardOwner
            )
        }
        guard await targetBecomesDeliverable(target) else {
            return heldResult(
                .destinationNotFrontmost,
                text: payload.fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }
        if policy?.deliveryMethod == .clipboardOnly {
            return fallbackResult(
                payload.fallbackText,
                copyOnHold: copyOnHold,
                copied: .copied,
                notCopied: .held(.deliveryFailed),
                heldClipboardOwner: heldClipboardOwner
            )
        }
        return await paste(
            payload,
            intoProcess: target.processIdentifier,
            activating: true,
            method: policy?.deliveryMethod ?? .automatic,
            typeOutFallback: policy?.typeOutFallback ?? false,
            expectedTarget: target,
            autoSend: policy?.autoSend ?? false,
            copyOnHold: copyOnHold,
            heldClipboardOwner: heldClipboardOwner
        )
    }

    /// A renderer can replace its Accessibility proxy during the same frame in
    /// which transcription completes. Give that exact destination a short
    /// settling window before declaring that the user moved away.
    private func targetBecomesDeliverable(
        _ target: MacDeliveryTarget
    ) async -> Bool {
        if target.canDeliverImmediately { return true }
        for delay in [80, 120, 180] {
            try? await Task.sleep(for: .milliseconds(delay))
            if target.canDeliverImmediately { return true }
        }
        return false
    }

    private func deliverHeldAfterAcquiringGate(
        _ payload: Payload,
        to target: MacDeliveryTarget,
        policy: MacDeliveryPolicy?,
        copyOnHold: Bool
    ) async -> MacPasteResult {
        guard AXIsProcessTrusted() else {
            return fallbackResult(
                payload.fallbackText,
                copyOnHold: copyOnHold,
                copied: .copiedNeedsAccessibility,
                notCopied: .held(.deliveryFailed)
            )
        }
        guard target.canDeliverOnReturn else {
            return heldResult(
                .destinationNotFrontmost,
                text: payload.fallbackText,
                copyOnHold: copyOnHold
            )
        }
        guard policy?.deliveryMethod != .clipboardOnly else {
            return heldResult(
                .deliveryFailed,
                text: payload.fallbackText,
                copyOnHold: copyOnHold
            )
        }
        return await paste(
            payload,
            intoProcess: target.processIdentifier,
            activating: false,
            method: policy?.deliveryMethod ?? .automatic,
            typeOutFallback: policy?.typeOutFallback ?? false,
            expectedTarget: target,
            // Returning to a field should restore the text, never surprise-send
            // a message that finished while the user was elsewhere.
            autoSend: false,
            copyOnHold: copyOnHold
        )
    }

    // MARK: Delivery

    private func paste(
        _ payload: Payload,
        intoProcess processIdentifier: pid_t?,
        activating: Bool,
        method: MacDeliveryMethod,
        typeOutFallback: Bool,
        expectedTarget: MacDeliveryTarget?,
        manualTarget: MacDeliveryTarget? = nil,
        autoSend: Bool,
        copyOnHold: Bool,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteResult {
        // Checked before anything is written to the pasteboard: while secure
        // input is held, the WindowServer discards synthetic keystrokes and
        // CGEvent.post reports nothing, so a paste would look successful and
        // silently vanish.
        guard !IsSecureEventInputEnabled() else {
            return heldResult(
                .secureInput,
                text: payload.fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        if let manualTarget, !manualTarget.matchesCurrentManualDestination {
            return heldResult(
                .destinationNotFrontmost,
                text: payload.fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        // An explicit Paste Here has no archived target by design, so recheck
        // the live AX subrole after waiting for another delivery transaction.
        // Browser password fields do not always enable global Secure Event
        // Input, but they still must never receive a retained transcript.
        if expectedTarget == nil, MacAccessibility.focusedElementIsSecureText() {
            return heldResult(
                .secureInput,
                text: payload.fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        // The delivery gate may have queued us behind another dictation. The
        // destination must still be the exact field captured at record start
        // after that wait, not merely when `deliver` was first called.
        if let expectedTarget, !expectedTarget.canDeliverImmediately {
            return heldResult(
                .destinationNotFrontmost,
                text: payload.fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        if activating,
           let processIdentifier,
           let application = NSRunningApplication(processIdentifier: processIdentifier),
           !application.isActive {
            application.activate(options: [])
            try? await Task.sleep(for: .milliseconds(140))
        }

        // This is the seam decision boundary. The gate is held, activation has
        // settled, and the exact destination is checked one final time before
        // reading its caret-local text. If AX cannot expose that text, the
        // record-start snapshot is the conservative fallback.
        if let expectedTarget, !expectedTarget.canDeliverImmediately {
            return heldResult(
                .destinationNotFrontmost,
                text: payload.fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }
        if let manualTarget, !manualTarget.matchesCurrentManualDestination {
            return heldResult(
                .destinationNotFrontmost,
                text: payload.fallbackText,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }
        let text = payload.resolvedForValidatedDestination()

        if method == .typeOut {
            let result = await typeOut(
                text,
                expectedTarget: expectedTarget,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
            return await finishAutoSend(
                after: result,
                requested: autoSend,
                target: expectedTarget
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
            if let expectedTarget { return expectedTarget.canDeliverImmediately }
            if let manualTarget {
                return manualTarget.matchesCurrentManualDestination
                    && !MacAccessibility.focusedElementIsSecureText()
            }
            return !MacAccessibility.focusedElementIsSecureText()
        }
        func heldAfterLateTargetChange() -> MacPasteResult {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            let secure = IsSecureEventInputEnabled()
                || MacAccessibility.focusedElementIsSecureText()
            return heldResult(
                secure ? .secureInput : .destinationNotFrontmost,
                text: text,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        var route: MacPasteRoute?
        if let expectedTarget, !expectedTarget.canDeliverImmediately {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            return heldResult(
                .destinationNotFrontmost,
                text: text,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        } else if let manualTarget, !manualTarget.matchesCurrentManualDestination {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            return heldResult(
                .destinationNotFrontmost,
                text: text,
                copyOnHold: copyOnHold,
                heldClipboardOwner: heldClipboardOwner
            )
        }
        if let processIdentifier {
            if MacAccessibility.pressPasteMenuItem(
                inProcess: processIdentifier,
                validating: targetIsStillValid
            ) {
                route = .menuAction
            } else if !targetIsStillValid() {
                return heldAfterLateTargetChange()
            }
        }
        if route == nil, method != .menuPaste {
            guard targetIsStillValid() else { return heldAfterLateTargetChange() }
            if sendPasteKeystroke() { route = .keystroke }
        }

        guard let route else {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            if typeOutFallback {
                let result = await typeOut(
                    text,
                    expectedTarget: expectedTarget,
                    copyOnHold: copyOnHold,
                    heldClipboardOwner: heldClipboardOwner
                )
                return await finishAutoSend(
                    after: result,
                    requested: autoSend,
                    target: expectedTarget
                )
            }
            if method != .menuPaste, !CGPreflightPostEventAccess() {
                return fallbackResult(
                    text,
                    // The exact destination was valid and delivery reached
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
                text: text,
                copyOnHold: true,
                heldClipboardOwner: heldClipboardOwner
            )
        }

        try? await Task.sleep(for: .milliseconds(160))
        let verified = didTextLand(text, before: before)
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
                    text,
                    heldClipboardOwner: heldClipboardOwner
                )
            }
            return .pasted(route: route, verified: false)
        }
        // Preserve the old timing guarantee while keeping the transaction
        // serialized: destinations have ample time to consume the pasteboard,
        // but another SpeakPaste delivery cannot interleave with the restore.
        try? await Task.sleep(for: .milliseconds(540))
        restore.restore(ifUnchangedSince: ourPasteboardChange)
        return await finishAutoSend(
            after: .pasted(route: route, verified: verified),
            requested: autoSend,
            target: expectedTarget
        )
    }

    /// Runs while `deliveryGate` is still held, so another dictation cannot
    /// paste between this transcript and its Return. The exact field and secure
    /// input state are checked at the final side-effect boundary.
    private func finishAutoSend(
        after result: MacPasteResult,
        requested: Bool,
        target: MacDeliveryTarget?
    ) async -> MacPasteResult {
        guard requested, result.permitsAutoSend, let target else { return result }
        try? await Task.sleep(for: .milliseconds(120))
        guard target.canDeliverOnReturn, !IsSecureEventInputEnabled() else { return result }
        _ = sendReturnKeystroke()
        return result
    }

    /// Confirms one exact insertion into a readable field. Merely finding the
    /// transcript somewhere in the result is unsafe: it could have already
    /// existed while an unrelated asynchronous edit changed the value. A
    /// missing baseline or any concurrent mutation stays unverified, which
    /// also prevents app-rule auto-send.
    private func didTextLand(_ text: String, before: String?) -> Bool {
        MacPasteVerification.isExactInsertion(
            text,
            before: before,
            after: MacAccessibility.focusedText()
        )
    }

    /// The one policy boundary for recovery clipboard writes. `copyOnHold`
    /// makes clipboard ownership explicit: the first held chunk can become the
    /// recovery copy, while every later held chunk remains durable in-app and
    /// returns `notCopied` without touching the user's current pasteboard.
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

    /// Serializes a required recovery copy behind any paste already consuming
    /// the shared pasteboard. Unlike explicit dashboard copy actions, a newly
    /// completed dictation cannot simply fail because another delivery held
    /// the gate for a few hundred milliseconds.
    @discardableResult
    func copyToPasteboardAfterWaiting(
        _ text: String,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> Bool {
        await deliveryGate.acquire()
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
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func typeOut(
        _ text: String,
        expectedTarget: MacDeliveryTarget?,
        copyOnHold: Bool,
        heldClipboardOwner: MacHeldClipboardIdentity? = nil
    ) async -> MacPasteResult {
        guard CGPreflightPostEventAccess() else {
            return fallbackResult(
                text,
                copyOnHold: copyOnHold,
                copied: .copiedNeedsKeyboardOutput,
                notCopied: .held(.deliveryFailed),
                heldClipboardOwner: heldClipboardOwner
            )
        }
        let before = MacAccessibility.focusedText()
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return heldResult(
                .deliveryFailed,
                text: text,
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
            if let expectedTarget, !expectedTarget.canDeliverImmediately {
                // Once even one chunk was posted, retrying the full transcript
                // automatically would duplicate that prefix. Report an
                // unconfirmed side effect so automatic held delivery is
                // suspended. Only the first outstanding recovery may replace
                // the clipboard.
                if offset > 0 {
                    preserveUnverifiedTypedOutput(
                        text,
                        copyOnHold: copyOnHold,
                        heldClipboardOwner: heldClipboardOwner
                    )
                    return .pasted(route: .typeOut, verified: false)
                }
                return heldResult(
                    .destinationNotFrontmost,
                    text: text,
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
                        text,
                        copyOnHold: copyOnHold,
                        heldClipboardOwner: heldClipboardOwner
                    )
                    return .pasted(route: .typeOut, verified: false)
                }
                return heldResult(
                    .deliveryFailed,
                    text: text,
                    copyOnHold: copyOnHold,
                    heldClipboardOwner: heldClipboardOwner
                )
            }
            keyDown.keyboardSetUnicodeString(stringLength: chunk.utf16.count, unicodeString: Array(chunk.utf16))
            keyUp.keyboardSetUnicodeString(stringLength: chunk.utf16.count, unicodeString: Array(chunk.utf16))
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            offset = end
            if offset < characters.count { try? await Task.sleep(for: .milliseconds(4)) }
        }

        try? await Task.sleep(for: .milliseconds(120))
        let verified = didTextLand(text, before: before)
        if !verified {
            preserveUnverifiedTypedOutput(
                text,
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
