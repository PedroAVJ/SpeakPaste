import AppKit
@preconcurrency import ApplicationServices
import Foundation

/// Where a dictation is meant to land: the application that was frontmost when
/// recording started, plus the exact element that held keyboard focus. Keeping
/// the element — not just the process — is what lets SpeakPaste refuse to
/// deliver into a different field that happens to be focused later.
struct MacDeliveryTarget {
    let processIdentifier: pid_t
    let applicationName: String
    private let element: AXUIElement?

    init(processIdentifier: pid_t, applicationName: String, element: AXUIElement?) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.element = element
    }

    /// Captures the current destination. Returns nil when SpeakPaste itself is
    /// frontmost, because there is no other app to deliver to.
    @MainActor
    static func captureCurrent() -> MacDeliveryTarget? {
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }
        return MacDeliveryTarget(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? "the previous app",
            element: MacAccessibility.systemFocusedElement()
        )
    }

    /// Whether an element was resolvable at capture time. Toolkits with weak
    /// accessibility support — Electron among them — often expose nothing, and
    /// the two cases must be treated differently.
    var hasElement: Bool { element != nil }

    /// True only when the very element captured at record time holds focus
    /// right now. A different field in the same app does not qualify. This is
    /// the only condition under which text is delivered unattended.
    var holdsFocus: Bool {
        guard
            let element,
            let current = MacAccessibility.systemFocusedElement()
        else {
            return false
        }
        return CFEqual(element, current)
    }

    /// Whether it is safe to deliver *right now*, immediately after
    /// transcription. With no element to match, being the frontmost app is
    /// accepted — the user has not gone anywhere, and refusing here would make
    /// every Electron dictation require a manual release. That allowance is
    /// deliberately not extended to unattended delivery later on, where "same
    /// app" is far weaker evidence of "same field".
    @MainActor
    var canDeliverImmediately: Bool {
        if hasElement { return holdsFocus }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    /// Writes into the captured element without activating the app or moving
    /// focus. Returns false when the element is gone or refuses the write, in
    /// which case the caller must fall back rather than assume success.
    func insertWithoutFocusing(_ text: String) -> Bool {
        guard let element else { return false }
        return MacAccessibility.insert(text, into: element)
    }
}

enum MacAccessibility {
    static func systemFocusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard
            status == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Replaces the element's selected text, which inserts at the caret when
    /// nothing is selected. Checked for settability first: several toolkits —
    /// Electron among them — expose the attribute read-only and would otherwise
    /// report success while dropping the text.
    static func insert(_ text: String, into element: AXUIElement) -> Bool {
        var isSettable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        guard settableStatus == .success, isSettable.boolValue else { return false }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }
}
