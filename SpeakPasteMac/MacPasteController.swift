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
                "Paste sent (\(route.rawValue)) but unconfirmed; transcript kept on clipboard"
            }
        case .copied: "Transcribed and copied"
        case .copiedNeedsAccessibility: "Copied; enable Accessibility for automatic paste"
        case .copiedNeedsKeyboardOutput: "Copied; enable Keyboard Output for synthetic typing"
        case .clipboardFailed: "Clipboard refused the transcript; recovery copy kept"
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

    /// Delivers text to `target` when it is safe to do so, and returns `.held`
    /// otherwise. Guessing at a destination is how dictation ends up in the
    /// wrong channel or a password field, so the caller holds instead.
    func deliver(
        _ text: String,
        to target: MacDeliveryTarget?,
        autoPaste: Bool,
        policy: MacDeliveryPolicy? = nil
    ) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        guard autoPaste, let target else {
            return copyToPasteboard(text) ? .copied : .clipboardFailed
        }
        guard AXIsProcessTrusted() else {
            return copyToPasteboard(text) ? .copiedNeedsAccessibility : .clipboardFailed
        }
        guard target.canDeliverImmediately else {
            return copyToPasteboard(text)
                ? .held(.destinationNotFrontmost)
                : .clipboardFailed
        }
        if policy?.deliveryMethod == .clipboardOnly {
            return copyToPasteboard(text) ? .copied : .clipboardFailed
        }
        let result = await paste(
            text,
            intoProcess: target.processIdentifier,
            activating: true,
            method: policy?.deliveryMethod ?? .automatic,
            typeOutFallback: policy?.typeOutFallback ?? false,
            expectedTarget: target,
            autoSend: policy?.autoSend ?? false
        )
        return result
    }

    /// Pastes wherever the caret is right now, for the explicit "give it to me
    /// here" shortcut. The user is asking for this destination, so no target
    /// match is required and nothing is activated.
    func pasteAtCurrentFocus(_ text: String) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        guard AXIsProcessTrusted() else {
            return copyToPasteboard(text) ? .copiedNeedsAccessibility : .clipboardFailed
        }
        guard !MacAccessibility.focusedElementIsSecureText() else {
            return copyToPasteboard(text) ? .held(.secureInput) : .clipboardFailed
        }
        guard let manualTarget = MacDeliveryTarget.captureCurrent() else {
            // Clicking a control in SpeakPaste makes SpeakPaste frontmost. Do
            // not paste a transcript into its own editor/search field by
            // accident; preserve it on the clipboard for the user instead.
            return copyToPasteboard(text) ? .copied : .clipboardFailed
        }
        return await paste(
            text,
            intoProcess: manualTarget.processIdentifier,
            activating: false,
            method: .automatic,
            typeOutFallback: false,
            expectedTarget: nil,
            manualTarget: manualTarget,
            autoSend: false
        )
    }

    /// Commits an automatically held transcript back to the exact field it was
    /// captured from. Unlike the explicit "Paste Here" action, this keeps the
    /// target identity all the way through the serialized delivery gate.
    func deliverHeld(
        _ text: String,
        to target: MacDeliveryTarget,
        policy: MacDeliveryPolicy?
    ) async -> MacPasteResult {
        await deliveryGate.acquire()
        defer { deliveryGate.release() }
        guard AXIsProcessTrusted() else {
            return copyToPasteboard(text) ? .copiedNeedsAccessibility : .clipboardFailed
        }
        guard target.canDeliverOnReturn else {
            return copyToPasteboard(text)
                ? .held(.destinationNotFrontmost)
                : .clipboardFailed
        }
        guard policy?.deliveryMethod != .clipboardOnly else {
            return copyToPasteboard(text) ? .held(.deliveryFailed) : .clipboardFailed
        }
        return await paste(
            text,
            intoProcess: target.processIdentifier,
            activating: false,
            method: policy?.deliveryMethod ?? .automatic,
            typeOutFallback: policy?.typeOutFallback ?? false,
            expectedTarget: target,
            // Returning to a field should restore the text, never surprise-send
            // a message that finished while the user was elsewhere.
            autoSend: false
        )
    }

    // MARK: Delivery

    private func paste(
        _ text: String,
        intoProcess processIdentifier: pid_t?,
        activating: Bool,
        method: MacDeliveryMethod,
        typeOutFallback: Bool,
        expectedTarget: MacDeliveryTarget?,
        manualTarget: MacDeliveryTarget? = nil,
        autoSend: Bool
    ) async -> MacPasteResult {
        // Checked before anything is written to the pasteboard: while secure
        // input is held, the WindowServer discards synthetic keystrokes and
        // CGEvent.post reports nothing, so a paste would look successful and
        // silently vanish.
        guard !IsSecureEventInputEnabled() else {
            return copyToPasteboard(text) ? .held(.secureInput) : .clipboardFailed
        }

        if let manualTarget, !manualTarget.matchesCurrentManualDestination {
            return copyToPasteboard(text)
                ? .held(.destinationNotFrontmost)
                : .clipboardFailed
        }

        // An explicit Paste Here has no archived target by design, so recheck
        // the live AX subrole after waiting for another delivery transaction.
        // Browser password fields do not always enable global Secure Event
        // Input, but they still must never receive a retained transcript.
        if expectedTarget == nil, MacAccessibility.focusedElementIsSecureText() {
            return copyToPasteboard(text) ? .held(.secureInput) : .clipboardFailed
        }

        // The delivery gate may have queued us behind another dictation. The
        // destination must still be the exact field captured at record start
        // after that wait, not merely when `deliver` was first called.
        if let expectedTarget, !expectedTarget.canDeliverImmediately {
            return copyToPasteboard(text)
                ? .held(.destinationNotFrontmost)
                : .clipboardFailed
        }

        if activating,
           let processIdentifier,
           let application = NSRunningApplication(processIdentifier: processIdentifier),
           !application.isActive {
            application.activate(options: [])
            try? await Task.sleep(for: .milliseconds(140))
        }


        if method == .typeOut {
            let result = await typeOut(text, expectedTarget: expectedTarget)
            return await finishAutoSend(
                after: result,
                requested: autoSend,
                target: expectedTarget
            )
        }

        let restore = MacPasteboardSnapshot.capture()
        guard copyToPasteboard(text) else { return .clipboardFailed }
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
            guard copyToPasteboard(text) else { return .clipboardFailed }
            let secure = IsSecureEventInputEnabled()
                || MacAccessibility.focusedElementIsSecureText()
            return .held(secure ? .secureInput : .destinationNotFrontmost)
        }

        var route: MacPasteRoute?
        if let expectedTarget, !expectedTarget.canDeliverImmediately {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            return copyToPasteboard(text)
                ? .held(.destinationNotFrontmost)
                : .clipboardFailed
        } else if let manualTarget, !manualTarget.matchesCurrentManualDestination {
            restore.restore(ifUnchangedSince: ourPasteboardChange)
            return copyToPasteboard(text)
                ? .held(.destinationNotFrontmost)
                : .clipboardFailed
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
                let result = await typeOut(text, expectedTarget: expectedTarget)
                return await finishAutoSend(
                    after: result,
                    requested: autoSend,
                    target: expectedTarget
                )
            }
            if method != .menuPaste, !CGPreflightPostEventAccess() {
                return copyToPasteboard(text)
                    ? .copiedNeedsKeyboardOutput
                    : .clipboardFailed
            }
            return .held(.deliveryFailed)
        }

        try? await Task.sleep(for: .milliseconds(160))
        let verified = didTextLand(text, before: before)
        if !verified {
            // Neither a successful menu action nor CGEvent.post proves the
            // destination consumed the text. If the field exposes no readable
            // AX value, keep the full transcript on the clipboard instead of
            // restoring over the only guaranteed copy.
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

    @discardableResult
    func copyToPasteboardIfIdle(_ text: String) -> Bool {
        guard deliveryGate.tryAcquire() else { return false }
        defer { deliveryGate.release() }
        return copyToPasteboard(text)
    }

    @discardableResult
    private func copyToPasteboard(_ text: String) -> Bool {
        let original = MacPasteboardSnapshot.capture()
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            // Clearing and writing are separate pasteboard operations. If the
            // second one is refused, put back the user's prior clipboard rather
            // than turning a reported failure into unrelated clipboard loss.
            original.restore(ifUnchangedSince: NSPasteboard.general.changeCount)
            return false
        }
        return true
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
        expectedTarget: MacDeliveryTarget?
    ) async -> MacPasteResult {
        guard CGPreflightPostEventAccess() else {
            return copyToPasteboard(text)
                ? .copiedNeedsKeyboardOutput
                : .clipboardFailed
        }
        let before = MacAccessibility.focusedText()
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return copyToPasteboard(text) ? .held(.deliveryFailed) : .clipboardFailed
        }

        // Short chunks are accepted consistently by Chromium, native AppKit,
        // terminals, and web views. One huge Unicode event is silently
        // truncated by some destinations.
        let characters = Array(text)
        var offset = 0
        while offset < characters.count {
            if let expectedTarget, !expectedTarget.canDeliverImmediately {
                let copied = copyToPasteboard(text)
                // Once even one chunk was posted, retrying the full transcript
                // automatically would duplicate that prefix. Report an
                // unconfirmed side effect so the text stays visible/clipboard-
                // backed but automatic held delivery is suspended.
                if offset > 0 { return .pasted(route: .typeOut, verified: false) }
                return copied ? .held(.destinationNotFrontmost) : .clipboardFailed
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
                let copied = copyToPasteboard(text)
                if offset > 0 { return .pasted(route: .typeOut, verified: false) }
                return copied ? .held(.deliveryFailed) : .clipboardFailed
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
        if !verified { copyToPasteboard(text) }
        return .pasted(route: .typeOut, verified: verified)
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
