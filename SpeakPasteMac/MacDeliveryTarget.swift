import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation

/// Where a dictation is meant to land: the application that was frontmost when
/// recording started, plus the exact element that held keyboard focus. Keeping
/// the element — not just the process — is what lets SpeakPaste refuse to
/// deliver into a different field that happens to be focused later.
struct MacDeliveryTarget {
    let processIdentifier: pid_t
    let applicationName: String
    let bundleIdentifier: String?
    /// Narrow, local context harvested at record start. These are candidate
    /// proper nouns/code identifiers for Scribe keyterm biasing, never a dump
    /// of the field or screen contents.
    let contextKeyterms: [String]
    /// The text immediately before the caret when recording began. Formatting
    /// must follow the intended field, not whichever field happens to be
    /// focused when the network request finishes.
    let precedingText: String?
    private let element: AXUIElement?

    init(
        processIdentifier: pid_t,
        applicationName: String,
        bundleIdentifier: String? = nil,
        contextKeyterms: [String] = [],
        precedingText: String? = nil,
        element: AXUIElement?
    ) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.contextKeyterms = contextKeyterms
        self.precedingText = precedingText
        self.element = element
    }

    /// Captures the current destination. Returns nil when SpeakPaste itself is
    /// frontmost, because there is no other app to deliver to.
    @MainActor
    static func captureCurrent(collectContext: Bool = false) -> MacDeliveryTarget? {
        // Secure Event Input is broader than AX secure-field subroles. Terminal
        // apps can enable it while still exposing an ordinary text area, so do
        // not even capture/read a destination until the global state clears.
        guard !IsSecureEventInputEnabled() else { return nil }
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }
        let element = MacAccessibility.systemFocusedElement()
        return MacDeliveryTarget(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? "the previous app",
            bundleIdentifier: application.bundleIdentifier,
            contextKeyterms: collectContext ? element.map {
                MacAccessibility.contextKeyterms(
                    from: $0,
                    applicationName: application.localizedName
                )
            } ?? [] : [],
            precedingText: element.flatMap(MacAccessibility.textBeforeCursor(in:)),
            element: element
        )
    }

    /// Whether an element was resolvable at capture time. Toolkits with weak
    /// accessibility support — Electron among them — often expose nothing, and
    /// the two cases must be treated differently.
    var hasElement: Bool { element != nil }

    /// Revalidation for the explicit "Paste Here" action. Unlike unattended
    /// delivery, an opaque field is allowed when it exposed no AX element both
    /// when invoked and at the side-effect boundary, but the frontmost process
    /// must still be unchanged. When AX identity exists, it must be exact.
    @MainActor
    var matchesCurrentManualDestination: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return false
        }
        let current = MacAccessibility.systemFocusedElement()
        if let element {
            guard let current else { return false }
            return CFEqual(element, current)
        }
        return current == nil
    }

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

    /// Whether it is safe to deliver *right now*. A process match alone is not
    /// enough: changing Slack chats or browser fields keeps the same PID while
    /// changing the destination. Rebuilt accessibility objects are refused:
    /// geometry and labels are not strong enough proof that this is still the
    /// same chat, document, or form field.
    @MainActor
    var canDeliverImmediately: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
            && holdsFocus
            && MacAccessibility.focusedElementAcceptsText()
    }

    /// Whether a transcript held earlier may now be delivered unattended.
    /// Exact AX identity is required. "Same app plus a similar text field" is
    /// deliberately not enough: that can paste a held dictation into the wrong
    /// conversation after Chromium rebuilds its accessibility tree.
    @MainActor
    var canDeliverOnReturn: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
            && holdsFocus
            && MacAccessibility.focusedElementAcceptsText()
    }
}

enum MacAccessibility {
    /// A wedged target — an Electron app mid-render, say — can otherwise block
    /// an accessibility call indefinitely, and these run on the main actor.
    static let messagingTimeout: Float = 1.5

    static func systemFocusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
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
        guard !isSecureTextElement(element) else { return false }
        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    /// Browser and Electron password controls may expose an AX secure subrole
    /// without enabling process-wide Secure Event Input. Manual paste/release
    /// paths have no archived destination, so they use this live gate before
    /// and after waiting for the serialized delivery transaction.
    static func focusedElementIsSecureText() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let element = systemFocusedElement() else { return false }
        return isSecureTextElement(element)
    }

    /// The text currently in the focused field, when it exposes one. Used to
    /// confirm a paste actually landed rather than trusting that a synthesized
    /// keystroke was delivered.
    static func focusedText() -> String? {
        guard let element = systemFocusedElement() else { return nil }
        guard !isSecureTextElement(element) else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return stringAttribute(kAXValueAttribute, of: element)
    }

    /// Text before the insertion point, not the whole field. Smart spacing and
    /// capitalization are wrong for a mid-field caret when they inspect the
    /// field's final character instead of the character immediately before the
    /// selection.
    static func focusedTextBeforeCursor() -> String? {
        guard let element = systemFocusedElement() else { return nil }
        return textBeforeCursor(in: element)
    }

    static func textBeforeCursor(in element: AXUIElement) -> String? {
        // Check role/subrole before any value access. Even when recognition
        // context is disabled, cursor-aware formatting must never read a
        // password field into process memory.
        guard !IsSecureEventInputEnabled(), !isSecureTextElement(element) else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard let text = stringAttribute(kAXValueAttribute, of: element) else { return nil }
        guard let range = selectedTextRange(in: element) else { return nil }
        let utf16Offset = min(range.location, text.utf16.count)
        let cursor = String.Index(utf16Offset: utf16Offset, in: text)
        return String(text[..<cursor].suffix(256))
    }

    /// Extracts only recognition hints rather than transmitting free-form
    /// context. Password fields are refused before any value read, and the
    /// result is capped to Scribe's per-keyterm constraints.
    static func contextKeyterms(
        from element: AXUIElement,
        applicationName: String?
    ) -> [String] {
        guard !IsSecureEventInputEnabled(), !isSecureTextElement(element) else { return [] }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var sources: [String] = []
        // Only inspect a small caret-local window. Reading the first several
        // thousand characters of a document both biased recognition with stale
        // text and exceeded the privacy promise shown in Settings.
        if let nearby = textNearCursor(in: element, before: 600, after: 200) {
            sources.append(nearby)
        }
        if let selected = stringAttribute(kAXSelectedTextAttribute, of: element) {
            sources.append(String(selected.prefix(500)))
        }
        if let title = windowTitle(of: element) { sources.append(title) }
        if let applicationName { sources.append(applicationName) }

        var results: [String] = []
        var seen = Set<String>()
        for source in sources {
            let words = source.split { character in
                !(character.isLetter || character.isNumber || character == "_" || character == "-")
            }
            var index = 0
            while index < words.count, results.count < 40 {
                let word = String(words[index])
                if isUsefulContextToken(word) {
                    appendContextTerm(word, to: &results, seen: &seen)
                    if index + 1 < words.count {
                        let next = String(words[index + 1])
                        if isTitleCasedName(word), isTitleCasedName(next) {
                            appendContextTerm("\(word) \(next)", to: &results, seen: &seen)
                        }
                    }
                }
                index += 1
            }
            if results.count >= 40 { break }
        }
        return results
    }

    private static func textNearCursor(
        in element: AXUIElement,
        before: Int,
        after: Int
    ) -> String? {
        guard !IsSecureEventInputEnabled(), !isSecureTextElement(element) else { return nil }
        guard
            let text = stringAttribute(kAXValueAttribute, of: element),
            let range = selectedTextRange(in: element)
        else {
            return nil
        }
        let utf16Count = text.utf16.count
        let selectionStart = min(max(0, range.location), utf16Count)
        let selectionEnd = min(max(selectionStart, range.location + range.length), utf16Count)
        let lowerOffset = max(0, selectionStart - before)
        let upperOffset = min(utf16Count, selectionEnd + after)
        let lower = String.Index(utf16Offset: lowerOffset, in: text)
        let upper = String.Index(utf16Offset: upperOffset, in: text)
        return String(text[lower..<upper])
    }

    private static func selectedTextRange(in element: AXUIElement) -> CFRange? {
        guard !IsSecureEventInputEnabled(), !isSecureTextElement(element) else { return nil }
        var rangeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &rangeValue
            ) == .success,
            let rangeValue,
            CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = rangeValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard
            AXValueGetValue(axValue, .cfRange, &range),
            range.location >= 0,
            range.length >= 0
        else {
            return nil
        }
        return range
    }

    /// Invokes the target application's own Edit ▸ Paste menu item.
    ///
    /// This is the delivery path superwhisper tries first, and it is better
    /// than a synthesized ⌘V on three counts: it is independent of keyboard
    /// layout, it is unaffected by Secure Event Input, and it needs no
    /// post-event grant. The item is matched on its command character rather
    /// than the title "Paste", so a localized menu still resolves.
    @MainActor
    static func pressPasteMenuItem(
        inProcess processIdentifier: pid_t,
        validating targetIsStillValid: () -> Bool
    ) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        var menuBarValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application,
                kAXMenuBarAttribute as CFString,
                &menuBarValue
            ) == .success,
            let menuBarValue,
            CFGetTypeID(menuBarValue) == AXUIElementGetTypeID()
        else {
            return false
        }
        let menuBar = menuBarValue as! AXUIElement

        for topLevel in children(of: menuBar) {
            for menu in children(of: topLevel) {
                for item in children(of: menu) {
                    guard
                        stringAttribute(kAXMenuItemCmdCharAttribute, of: item) == "v",
                        // ⌘V carries no extra modifier; ⇧⌘V is Paste and Match
                        // Style, which would reformat the user's text.
                        numberAttribute(kAXMenuItemCmdModifiersAttribute, of: item) == 0,
                        isEnabled(item)
                    else {
                        continue
                    }
                    // Menu-tree traversal can take up to the AX messaging
                    // timeout. Revalidate at the exact side-effect boundary so
                    // a focus switch during that traversal cannot paste into a
                    // different field or a newly focused password control.
                    guard targetIsStillValid() else { return false }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFArrayGetTypeID()
        else {
            return []
        }
        return (value as! CFArray) as? [AXUIElement] ?? []
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFBooleanGetTypeID()
        else {
            return true
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute, of: element) == (kAXSecureTextFieldSubrole as String)
            || stringAttribute(kAXSubroleAttribute, of: element) == (kAXSecureTextFieldSubrole as String)
    }

    private static func isUsefulContextToken(_ token: String) -> Bool {
        guard token.count >= 2, token.count <= 50 else { return false }
        let letters = token.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let hasInnerCapital = token.dropFirst().contains(where: \.isUppercase)
        let isAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
        let hasCodeShape = token.contains("_") || token.contains("-")
            || (token.contains(where: \.isNumber) && token.contains(where: \.isLetter))
        return hasInnerCapital || isAcronym || hasCodeShape || isTitleCasedName(token)
    }

    private static func isTitleCasedName(_ token: String) -> Bool {
        guard let first = token.first, first.isUppercase, token.count > 2 else { return false }
        return token.dropFirst().contains(where: \.isLowercase)
    }

    private static func appendContextTerm(
        _ term: String,
        to results: inout [String],
        seen: inout Set<String>
    ) {
        let normalized = term.lowercased()
        guard seen.insert(normalized).inserted else { return }
        results.append(term)
    }

    private static func numberAttribute(_ attribute: String, of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFNumberGetTypeID()
        else {
            return nil
        }
        return ((value as! NSNumber)).intValue
    }

    private static func windowTitle(of element: AXUIElement) -> String? {
        guard !IsSecureEventInputEnabled() else { return nil }
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return stringAttribute(kAXTitleAttribute, of: value as! AXUIElement)
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
