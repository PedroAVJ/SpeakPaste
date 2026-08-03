import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation

enum MacPasteRoute: String, Equatable {
    /// The target application's own Edit ▸ Paste command was invoked.
    case menuAction = "menu"
    /// A synthesized ⌘V was posted.
    case keystroke = "⌘V"
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
    case held(MacHoldReason)

    var detail: String {
        switch self {
        case let .pasted(route, verified):
            verified
                ? "Transcribed and pasted (\(route.rawValue), confirmed)"
                : "Transcribed and pasted (\(route.rawValue), unconfirmed)"
        case .copied: "Transcribed and copied"
        case .copiedNeedsAccessibility: "Copied; enable Accessibility for automatic paste"
        case let .held(reason): "Held — \(reason.explanation)"
        }
    }

    /// Whether the transcript can stop being tracked as undelivered.
    var isDelivered: Bool {
        if case .pasted = self { return true }
        return false
    }
}

@MainActor
struct MacPasteController {
    /// Delivers text to `target` when it is safe to do so, and returns `.held`
    /// otherwise. Guessing at a destination is how dictation ends up in the
    /// wrong channel or a password field, so the caller holds instead.
    func deliver(
        _ text: String,
        to target: MacDeliveryTarget?,
        autoPaste: Bool
    ) async -> MacPasteResult {
        guard autoPaste, let target else {
            copyToPasteboard(text)
            return .copied
        }
        guard AXIsProcessTrusted() else {
            copyToPasteboard(text)
            return .copiedNeedsAccessibility
        }
        guard target.canDeliverImmediately else {
            copyToPasteboard(text)
            return .held(.destinationNotFrontmost)
        }
        return await paste(text, intoProcess: target.processIdentifier, activating: true)
    }

    /// Pastes wherever the caret is right now, for the explicit "give it to me
    /// here" shortcut. The user is asking for this destination, so no target
    /// match is required and nothing is activated.
    func pasteAtCurrentFocus(_ text: String) async -> MacPasteResult {
        guard AXIsProcessTrusted() else {
            copyToPasteboard(text)
            return .copiedNeedsAccessibility
        }
        let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return await paste(text, intoProcess: processIdentifier, activating: false)
    }

    // MARK: Delivery

    private func paste(
        _ text: String,
        intoProcess processIdentifier: pid_t?,
        activating: Bool
    ) async -> MacPasteResult {
        // Checked before anything is written to the pasteboard: while secure
        // input is held, the WindowServer discards synthetic keystrokes and
        // CGEvent.post reports nothing, so a paste would look successful and
        // silently vanish.
        guard !IsSecureEventInputEnabled() else {
            copyToPasteboard(text)
            return .held(.secureInput)
        }

        if activating,
           let processIdentifier,
           let application = NSRunningApplication(processIdentifier: processIdentifier),
           !application.isActive {
            application.activate(options: [])
            try? await Task.sleep(for: .milliseconds(140))
        }

        let restore = MacPasteboardSnapshot.capture()
        copyToPasteboard(text)
        let before = MacAccessibility.focusedText()

        // The target's own Paste command first. It is layout-independent and
        // unaffected by Secure Event Input, so it fails in strictly fewer
        // situations than a synthesized keystroke.
        var route: MacPasteRoute?
        if let processIdentifier, MacAccessibility.pressPasteMenuItem(inProcess: processIdentifier) {
            route = .menuAction
        } else if sendPasteKeystroke() {
            route = .keystroke
        }

        guard let route else {
            restore.restore()
            return .held(.deliveryFailed)
        }

        try? await Task.sleep(for: .milliseconds(160))
        let verified = didTextLand(text, before: before)
        restore.restore()
        return .pasted(route: route, verified: verified)
    }

    /// Confirms the transcript reached the field, when the field exposes a
    /// readable value. `nil` before or after means the destination is opaque to
    /// accessibility, which is unverifiable rather than failed.
    private func didTextLand(_ text: String, before: String?) -> Bool {
        guard let after = MacAccessibility.focusedText() else { return false }
        guard let before else { return after.contains(text) }
        guard after != before else { return false }
        return after.contains(text)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func sendPasteKeystroke() -> Bool {
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

    func restore() {
        guard !items.isEmpty else { return }
        let changeCountAfterOurWrite = NSPasteboard.general.changeCount
        // Long enough for the destination to have read the pasteboard; a
        // restore that lands too early pastes the user's old clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard NSPasteboard.general.changeCount == changeCountAfterOurWrite else { return }
            NSPasteboard.general.clearContents()
            let restored = items.map { contents -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            NSPasteboard.general.writeObjects(restored)
        }
    }
}
