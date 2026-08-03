import AppKit
@preconcurrency import ApplicationServices
import Foundation

enum MacPasteResult: Equatable {
    case copied
    case pasted
    case copiedNeedsAccessibility
}

@MainActor
struct MacPasteController {
    func deliver(_ text: String, pasteInto processIdentifier: pid_t?, autoPaste: Bool) async -> MacPasteResult {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        guard autoPaste, let processIdentifier else {
            return .copied
        }

        guard AXIsProcessTrusted() else {
            return .copiedNeedsAccessibility
        }

        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return .copied
        }
        application.activate(options: [])
        try? await Task.sleep(for: .milliseconds(140))

        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            return .copied
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return .pasted
    }
}
