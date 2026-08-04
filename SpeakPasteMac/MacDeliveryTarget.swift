import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation

/// A privacy-neutral snapshot of an editable Accessibility element. It stores
/// structure and geometry, never the field's value or selected text.
struct MacAccessibilityTargetFingerprint: Equatable, Sendable {
    let role: String
    let subrole: String?
    let stableIdentifiers: Set<String>
    let placeholder: String?
    let frame: CGRect?

    /// Chromium can replace an AX proxy while leaving the same editor focused.
    /// A replacement is accepted only in the same window, with no intervening
    /// user input, and with a strong structural or geometric match.
    func safelyMatchesRebuilt(
        _ other: MacAccessibilityTargetFingerprint,
        sameWindow: Bool,
        noInterveningUserInput: Bool
    ) -> Bool {
        guard sameWindow, noInterveningUserInput else { return false }
        guard role == other.role, subrole == other.subrole else { return false }

        if !stableIdentifiers.isEmpty,
           !stableIdentifiers.isDisjoint(with: other.stableIdentifiers) {
            return true
        }

        let placeholdersMatch = placeholder?.isEmpty == false
            && placeholder == other.placeholder
        guard placeholdersMatch || framesSubstantiallyOverlap(other) else {
            return false
        }
        return framesSubstantiallyOverlap(other)
    }

    private func framesSubstantiallyOverlap(
        _ other: MacAccessibilityTargetFingerprint
    ) -> Bool {
        guard let frame, let otherFrame = other.frame else { return false }
        let smallerArea = min(frame.width * frame.height, otherFrame.width * otherFrame.height)
        guard smallerArea > 0 else { return false }
        let intersection = frame.intersection(otherFrame)
        guard !intersection.isNull else { return false }
        return (intersection.width * intersection.height) / smallerArea >= 0.85
    }
}

/// Counts focus-changing user actions without observing their contents. Bare
/// Command taps are flags-changed events and deliberately do not increment it.
private final class MacUserInteractionTracker: @unchecked Sendable {
    static let shared = MacUserInteractionTracker()

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .keyDown,
                .scrollWheel,
            ]
        ) { [weak self] _ in
            self?.recordInteraction()
        }
    }

    var snapshot: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard monitor != nil else { return nil }
        return generation
    }

    private func recordInteraction() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

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
    private let window: AXUIElement?
    private let fingerprint: MacAccessibilityTargetFingerprint?
    private let interactionGeneration: UInt64?

    init(
        processIdentifier: pid_t,
        applicationName: String,
        bundleIdentifier: String? = nil,
        contextKeyterms: [String] = [],
        precedingText: String? = nil,
        element: AXUIElement?,
        window: AXUIElement? = nil,
        fingerprint: MacAccessibilityTargetFingerprint? = nil,
        interactionGeneration: UInt64? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.contextKeyterms = contextKeyterms
        self.precedingText = precedingText
        self.element = element
        self.window = window
        self.fingerprint = fingerprint
        self.interactionGeneration = interactionGeneration
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
            element: element,
            window: element.flatMap(MacAccessibility.window(of:)),
            fingerprint: element.flatMap(MacAccessibility.targetFingerprint(of:)),
            interactionGeneration: MacUserInteractionTracker.shared.snapshot
        )
    }

    /// Whether an element was resolvable at capture time. Toolkits with weak
    /// accessibility support — Electron among them — often expose nothing, and
    /// the two cases must be treated differently.
    var hasElement: Bool { element != nil }

    /// Whether two queued dictations were captured for the exact same field.
    /// A process match alone is not identity: changing chats, browser tabs, or
    /// form controls commonly keeps the same PID. Opaque captures deliberately
    /// never compare equal because there is no AX object proving continuity.
    func refersToSameElement(as other: MacDeliveryTarget) -> Bool {
        guard processIdentifier == other.processIdentifier else { return false }
        guard let element, let otherElement = other.element else { return false }
        if CFEqual(element, otherElement) { return true }
        return safelyMatchesRebuiltElement(
            otherElement,
            otherWindow: other.window,
            otherFingerprint: other.fingerprint,
            currentInteractionGeneration: other.interactionGeneration
        )
    }

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
        if CFEqual(element, current) { return true }
        return safelyMatchesRebuiltElement(
            current,
            otherWindow: MacAccessibility.window(of: current),
            otherFingerprint: MacAccessibility.targetFingerprint(of: current),
            currentInteractionGeneration: MacUserInteractionTracker.shared.snapshot
        )
    }

    private func safelyMatchesRebuiltElement(
        _ otherElement: AXUIElement,
        otherWindow: AXUIElement?,
        otherFingerprint: MacAccessibilityTargetFingerprint?,
        currentInteractionGeneration: UInt64?
    ) -> Bool {
        guard let window, let otherWindow, CFEqual(window, otherWindow) else {
            return false
        }
        guard
            let interactionGeneration,
            interactionGeneration == currentInteractionGeneration,
            let fingerprint,
            let otherFingerprint
        else {
            return false
        }
        return fingerprint.safelyMatchesRebuilt(
            otherFingerprint,
            sameWindow: true,
            noInterveningUserInput: true
        )
    }

    /// Whether it is safe to deliver *right now*. A process match alone is not
    /// enough: changing Slack chats or browser fields keeps the same PID while
    /// changing the destination. A rebuilt Accessibility proxy is accepted
    /// only with same-window structural continuity and no intervening input.
    @MainActor
    var canDeliverImmediately: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
            && holdsFocus
            && MacAccessibility.focusedElementAcceptsText()
    }

    /// Whether a transcript held earlier may now be delivered unattended. A
    /// direct AX identity or the same narrow rebuilt-proxy proof is required;
    /// merely returning to the same app is never sufficient.
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

    static func window(of element: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXWindowAttribute, of: element)
    }

    static func targetFingerprint(
        of element: AXUIElement
    ) -> MacAccessibilityTargetFingerprint? {
        guard let role = stringAttribute(kAXRoleAttribute, of: element) else {
            return nil
        }
        var stableIdentifiers = Set<String>()
        if let identifier = nonemptyStringAttribute(kAXIdentifierAttribute, of: element) {
            stableIdentifiers.insert("ax:\(identifier)")
        }
        if let identifier = nonemptyStringAttribute("AXDOMIdentifier", of: element) {
            stableIdentifiers.insert("dom:\(identifier)")
        }
        let placeholder = nonemptyStringAttribute(kAXPlaceholderValueAttribute, of: element)
            ?? nonemptyStringAttribute(kAXDescriptionAttribute, of: element)
        return MacAccessibilityTargetFingerprint(
            role: role,
            subrole: stringAttribute(kAXSubroleAttribute, of: element),
            stableIdentifiers: stableIdentifiers,
            placeholder: placeholder,
            frame: frame(of: element)
        )
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

    private static func elementAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let origin = pointAttribute(kAXPositionAttribute, of: element),
            let size = sizeAttribute(kAXSizeAttribute, of: element)
        else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func pointAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
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

    private static func nonemptyStringAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> String? {
        guard let value = stringAttribute(attribute, of: element) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
