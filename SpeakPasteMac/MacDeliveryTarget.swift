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

    /// Whether it is safe to deliver *right now*, seconds after the user
    /// stopped speaking. Still being the frontmost application is the bar here:
    /// the user never went anywhere, and that is exactly the case that must
    /// paste instantly. Requiring element identity instead is too strict to be
    /// usable — Chromium rebuilds its accessibility nodes across renders, so a
    /// composer that never lost focus can still fail an identity check.
    ///
    /// This allowance is deliberately not extended to unattended delivery
    /// later on, where "same app" is far weaker evidence of "same field".
    @MainActor
    var canDeliverImmediately: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    /// Whether a transcript held earlier may now be delivered unattended.
    /// Strict element identity is the strongest signal, but Chromium rebuilds
    /// its nodes across renders, so identity alone would leave text stranded in
    /// exactly the apps that matter most. Failing that, the destination must be
    /// frontmost *and* focus must sit on something that takes typed text and is
    /// not a password field.
    @MainActor
    var canDeliverOnReturn: Bool {
        if holdsFocus { return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return false
        }
        return MacAccessibility.focusedElementAcceptsText()
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

    /// Whether whatever holds focus right now is somewhere a paste belongs.
    /// Secure fields are excluded outright — a dictation must never be pushed
    /// into a password box.
    static func focusedElementAcceptsText() -> Bool {
        guard let element = systemFocusedElement() else { return false }
        guard let role = stringAttribute(kAXRoleAttribute, of: element) else { return false }
        guard role != (kAXSecureTextFieldSubrole as String) else { return false }
        if let subrole = stringAttribute(kAXSubroleAttribute, of: element),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return false
        }
        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFStringGetTypeID()
        else {
            return nil
        }
        return (value as! CFString) as String
    }
}
