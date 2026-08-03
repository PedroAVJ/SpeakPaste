import AppKit
@preconcurrency import ApplicationServices
import Foundation

enum MacPasteResult: Equatable {
    /// ⌘V was delivered to the destination.
    case pasted
    /// On the clipboard only, because there was no target to deliver to.
    case copied
    case copiedNeedsAccessibility
    /// The target exists but is not focused. The caller must hold the text.
    case held

    var detail: String {
        switch self {
        case .pasted: "Transcribed and pasted"
        case .copied: "Transcribed and copied"
        case .copiedNeedsAccessibility: "Copied; enable Accessibility for automatic paste"
        case .held: "Held until you return"
        }
    }
}

@MainActor
struct MacPasteController {
    /// Delivers text to `target` when it is safe to do so, and returns `.held`
    /// otherwise. Guessing at a destination is how dictation ends up in the
    /// wrong channel or a password field, so the caller holds instead.
    ///
    /// Delivery is always a real ⌘V. Writing `kAXSelectedText` directly looked
    /// tidier — no activation, no synthetic keystroke — but toolkits that own
    /// their text state ignore it: a React-controlled composer never sees the
    /// input event, so the write reports success and the text never lands. The
    /// paste pipeline is the one path every app honors.
    func deliver(
        _ text: String,
        to target: MacDeliveryTarget?,
        autoPaste: Bool
    ) async -> MacPasteResult {
        copyToPasteboard(text)

        guard autoPaste, let target else { return .copied }
        guard AXIsProcessTrusted() else { return .copiedNeedsAccessibility }
        guard target.canDeliverImmediately else { return .held }

        return await activateAndPaste(target) ? .pasted : .copied
    }

    /// Pastes wherever the caret is right now, for the explicit "give it to me
    /// here" shortcut. The user is asking for this destination, so no target
    /// match is required and nothing is activated.
    func pasteAtCurrentFocus(_ text: String) -> MacPasteResult {
        copyToPasteboard(text)
        guard AXIsProcessTrusted() else { return .copiedNeedsAccessibility }
        return sendPasteKeystroke() ? .pasted : .copied
    }

    /// Brings the destination forward before pasting. The delay lets the
    /// activation settle; posting ⌘V into an app that is still coming forward
    /// drops the keystroke.
    private func activateAndPaste(_ target: MacDeliveryTarget) async -> Bool {
        if let application = NSRunningApplication(processIdentifier: target.processIdentifier),
           !application.isActive {
            application.activate(options: [])
            try? await Task.sleep(for: .milliseconds(140))
        }
        return sendPasteKeystroke()
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func sendPasteKeystroke() -> Bool {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
