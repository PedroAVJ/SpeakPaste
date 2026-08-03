import AppKit
@preconcurrency import ApplicationServices
import Foundation

enum MacPasteResult: Equatable {
    /// Written straight into the captured element. No focus change, no keystroke.
    case inserted
    /// The target held focus but refused a direct write, so ⌘V was sent to it.
    case pasted
    /// On the clipboard only, because there was no target to deliver to.
    case copied
    case copiedNeedsAccessibility
    /// The target exists but is not focused. The caller must hold the text.
    case held

    var detail: String {
        switch self {
        case .inserted: "Transcribed and inserted"
        case .pasted: "Transcribed and pasted"
        case .copied: "Transcribed and copied"
        case .copiedNeedsAccessibility: "Copied; enable Accessibility for automatic paste"
        case .held: "Held until you return"
        }
    }
}

@MainActor
struct MacPasteController {
    /// Delivers text to `target` only when that exact element still holds
    /// focus. Anything else returns `.held`: guessing at a destination is how
    /// dictation ends up in the wrong channel or a password field.
    func deliver(
        _ text: String,
        to target: MacDeliveryTarget?,
        autoPaste: Bool
    ) async -> MacPasteResult {
        copyToPasteboard(text)

        guard autoPaste, let target else { return .copied }
        guard AXIsProcessTrusted() else { return .copiedNeedsAccessibility }
        guard target.canDeliverImmediately else { return .held }

        if target.insertWithoutFocusing(text) { return .inserted }
        return sendPasteKeystroke() ? .pasted : .copied
    }

    /// Inserts wherever the caret is right now, for the explicit "give it to me
    /// here" shortcut. The user is asking for this destination, so no target
    /// match is required.
    func insertAtCurrentFocus(_ text: String) -> MacPasteResult {
        copyToPasteboard(text)

        guard AXIsProcessTrusted() else { return .copiedNeedsAccessibility }
        if
            let element = MacAccessibility.systemFocusedElement(),
            MacAccessibility.insert(text, into: element)
        {
            return .inserted
        }
        return sendPasteKeystroke() ? .pasted : .copied
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
