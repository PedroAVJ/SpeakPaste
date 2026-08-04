import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation

/// Identifies the unmodified Command-V menu item without depending on the
/// application's localization or on AppKit's accelerator letter casing.
/// Electron currently exposes the Paste accelerator as uppercase `V`, while
/// some native applications expose lowercase `v`.
enum MacPasteMenuShortcut {
    static func isPlainPaste(
        commandCharacter: String?,
        commandModifiers: Int?,
        isEnabled: Bool
    ) -> Bool {
        guard
            isEnabled,
            commandModifiers == 0,
            let commandCharacter
        else {
            return false
        }
        return commandCharacter.caseInsensitiveCompare("v") == .orderedSame
    }
}

enum MacPasteMenuActionResult: Equatable {
    /// No menu side effect was reached; another insertion route is safe.
    case unavailable
    /// Focus stopped being a writable control before the menu action.
    case focusChanged
    /// AXPress was invoked. Its return status cannot prove whether the target
    /// consumed the paste, so no second insertion route may be attempted.
    case invoked

    var permitsAnotherInsertionRoute: Bool { self == .unavailable }
}

/// Counts user actions that can move focus or the insertion point without
/// observing their contents. SpeakPaste's own marked CGEvents are excluded so
/// a chunked insertion can distinguish its output from intervening user input.
final class MacUserInteractionTracker: @unchecked Sendable {
    static let shared = MacUserInteractionTracker()
    static let syntheticEventMarker: Int64 = 0x5350_4541_4B

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
        ) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                == Self.syntheticEventMarker {
                return
            }
            self?.recordInteraction()
        }
    }

    var snapshot: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard monitor != nil else { return nil }
        return generation
    }

    static func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: syntheticEventMarker
        )
    }

    private func recordInteraction() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

/// Application/context metadata captured for recognition and History. Delivery
/// deliberately resolves the live focused editor later: Electron and Chromium
/// may rebuild or proxy their Accessibility nodes while the user stays put, so
/// a record-start AX object is not a universal destination identity.
struct MacDeliveryTarget {
    let processIdentifier: pid_t
    let applicationName: String
    let bundleIdentifier: String?
    /// Narrow, local context harvested at record start. These are candidate
    /// proper nouns/code identifiers for Scribe keyterm biasing, never a dump
    /// of the field or screen contents.
    let contextKeyterms: [String]
    /// The text immediately before the caret at this snapshot. A live delivery
    /// capture uses it only if a second caret-local read is unavailable.
    let precedingText: String?
    private let element: AXUIElement?
    /// This is captured at the delivery boundary, not at record start. It is
    /// used only to keep a multi-step side effect from following later input.
    private let interactionGeneration: UInt64?

    init(
        processIdentifier: pid_t,
        applicationName: String,
        bundleIdentifier: String? = nil,
        contextKeyterms: [String] = [],
        precedingText: String? = nil,
        element: AXUIElement?,
        interactionGeneration: UInt64? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.contextKeyterms = contextKeyterms
        self.precedingText = precedingText
        self.element = element
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
        let interactionBeforeCapture = MacUserInteractionTracker.shared.snapshot
        let element = MacAccessibility.focusedWritableElement()
        let contextKeyterms = collectContext ? element.map {
            MacAccessibility.contextKeyterms(
                from: $0,
                applicationName: application.localizedName
            )
        } ?? [] : []
        let precedingText = element.flatMap(MacAccessibility.textBeforeCursor(in:))
        let interactionAfterCapture = MacUserInteractionTracker.shared.snapshot
        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier,
            interactionBeforeCapture == interactionAfterCapture
        else {
            return nil
        }
        return MacDeliveryTarget(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName ?? "the previous app",
            bundleIdentifier: application.bundleIdentifier,
            contextKeyterms: contextKeyterms,
            precedingText: precedingText,
            element: element,
            interactionGeneration: interactionAfterCapture
        )
    }

    /// Resolves the output destination at delivery time. A missing writable,
    /// non-secure focus deliberately selects clipboard fallback instead.
    @MainActor
    static func captureCurrentWritable() -> MacDeliveryTarget? {
        guard let target = captureCurrent(), target.hasElement else { return nil }
        return target
    }

    /// Whether an element was resolvable at capture time. Toolkits with weak
    /// accessibility support — Electron among them — often expose nothing, and
    /// the two cases must be treated differently.
    var hasElement: Bool { element != nil }

    /// Revalidation for explicit output. A replacement AX node is valid when
    /// the same live application still owns a writable, non-secure focus and
    /// no user action moved the insertion point after capture.
    @MainActor
    var matchesCurrentManualDestination: Bool {
        canContinueMultistepInsertion
    }

    /// Strictly links an optional follow-up side effect to the editor selected
    /// for this one delivery. It is intentionally short-lived and must not be
    /// used as a record-start continuity requirement.
    func isSameUninterruptedOutputBoundary(as other: MacDeliveryTarget) -> Bool {
        guard
            processIdentifier == other.processIdentifier,
            let interactionGeneration,
            let otherInteractionGeneration = other.interactionGeneration,
            interactionGeneration == otherInteractionGeneration,
            let element,
            let otherElement = other.element
        else {
            return false
        }
        return CFEqual(element, otherElement)
    }

    /// A transcript may start in any live writable node, including a rebuilt AX
    /// proxy. Once chunked output has begun, however, user input must not move
    /// the remaining chunks elsewhere. If event monitoring is unavailable,
    /// exact short-lived node identity is the fail-closed fallback.
    @MainActor
    var canContinueMultistepInsertion: Bool {
        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
            !MacAccessibility.focusedElementIsSecureText(),
            let current = MacAccessibility.focusedWritableElement()
        else {
            return false
        }
        return MacOutputContinuationPolicy.canContinueMultistepInsertion(
            processIsCurrent: true,
            currentIsWritable: true,
            currentIsSecure: false,
            sameElement: element.map { CFEqual($0, current) } ?? false,
            interactionGeneration: interactionGeneration,
            currentInteractionGeneration: MacUserInteractionTracker.shared.snapshot
        )
    }

    /// Return is a separate side effect after paste confirmation. Suppress it
    /// unless the just-confirmed node still owns focus and no user action has
    /// occurred during the delay. This strict, short-lived check does not make
    /// AX identity a requirement for selecting the transcript destination.
    @MainActor
    var canReceiveFollowUpReturn: Bool {
        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
            !MacAccessibility.focusedElementIsSecureText(),
            let element,
            let current = MacAccessibility.focusedWritableElement()
        else {
            return false
        }
        return MacOutputContinuationPolicy.canSendFollowUpReturn(
            processIsCurrent: true,
            currentIsWritable: true,
            currentIsSecure: false,
            sameElement: CFEqual(element, current),
            interactionGeneration: interactionGeneration,
            currentInteractionGeneration: MacUserInteractionTracker.shared.snapshot
        )
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
    /// into a password box. Browser and Electron editors sometimes focus a
    /// proxy child, so resolve a bounded parent chain to the writable control.
    static func focusedElementAcceptsText() -> Bool {
        focusedWritableElement() != nil
    }

    static func focusedWritableElement(maximumAncestorDepth: Int = 6) -> AXUIElement? {
        guard let focused = systemFocusedElement() else { return nil }
        var candidate = focused
        var visited: [AXUIElement] = []
        var firstWritableCandidate: AXUIElement?

        for _ in 0...maximumAncestorDepth {
            if visited.contains(where: { CFEqual($0, candidate) }) { return nil }
            visited.append(candidate)
            AXUIElementSetMessagingTimeout(candidate, messagingTimeout)
            if isSecureTextElement(candidate) { return nil }
            if firstWritableCandidate == nil, elementAcceptsText(candidate) {
                firstWritableCandidate = candidate
            }
            guard let parent = elementAttribute(kAXParentAttribute, of: candidate) else {
                return firstWritableCandidate
            }
            candidate = parent
        }
        return firstWritableCandidate
    }

    /// Pure role boundary kept separate so the deployment regression suite can
    /// cover native and Chromium-style editable ancestors without live UI.
    static func roleAcceptsText(
        _ role: String?,
        explicitlyEditable: Bool,
        valueIsSettable: Bool? = nil
    ) -> Bool {
        if explicitlyEditable { return true }
        let isKnownTextRole = role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
        guard isKnownTextRole else { return false }
        return valueIsSettable != false
    }

    private static func elementAcceptsText(_ element: AXUIElement) -> Bool {
        guard isEnabled(element) else { return false }
        let editable = booleanAttribute("AXEditable", of: element)
        guard editable != false else { return false }
        return roleAcceptsText(
            stringAttribute(kAXRoleAttribute, of: element),
            explicitlyEditable: editable == true,
            valueIsSettable: valueIsSettable(element)
        )
    }

    /// Browser and Electron password controls may expose an AX secure subrole
    /// without enabling process-wide Secure Event Input. Manual paste/release
    /// paths have no archived destination, so they use this live gate before
    /// and after waiting for the serialized delivery transaction.
    static func focusedElementIsSecureText() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let focused = systemFocusedElement() else { return false }
        var candidate = focused
        var visited: [AXUIElement] = []
        for _ in 0...6 {
            if visited.contains(where: { CFEqual($0, candidate) }) { return false }
            visited.append(candidate)
            if isSecureTextElement(candidate) { return true }
            guard let parent = elementAttribute(kAXParentAttribute, of: candidate) else {
                return false
            }
            candidate = parent
        }
        return false
    }

    /// The text currently in the focused field, when it exposes one. Used to
    /// confirm a paste actually landed rather than trusting that a synthesized
    /// keystroke was delivered.
    static func focusedText() -> String? {
        guard let element = focusedWritableElement() else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return stringAttribute(kAXValueAttribute, of: element)
    }

    /// Text before the insertion point, not the whole field. Smart spacing and
    /// capitalization are wrong for a mid-field caret when they inspect the
    /// field's final character instead of the character immediately before the
    /// selection.
    static func focusedTextBeforeCursor() -> String? {
        guard let element = focusedWritableElement() else { return nil }
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
    ) -> MacPasteMenuActionResult {
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
            return .unavailable
        }
        let menuBar = menuBarValue as! AXUIElement

        for topLevel in children(of: menuBar) {
            for menu in children(of: topLevel) {
                for item in children(of: menu) {
                    guard MacPasteMenuShortcut.isPlainPaste(
                        commandCharacter: stringAttribute(
                            kAXMenuItemCmdCharAttribute,
                            of: item
                        ),
                        // ⌘V carries no extra modifier; ⇧⌘V is Paste and Match
                        // Style, which would reformat the user's text.
                        commandModifiers: numberAttribute(
                            kAXMenuItemCmdModifiersAttribute,
                            of: item
                        ),
                        isEnabled: isEnabled(item)
                    ) else {
                        continue
                    }
                    // Menu-tree traversal can take up to the AX messaging
                    // timeout. Revalidate at the exact side-effect boundary so
                    // a focus switch during that traversal cannot paste into a
                    // different field or a newly focused password control.
                    guard targetIsStillValid() else { return .focusChanged }
                    _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return .invoked
                }
            }
        }
        return .unavailable
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

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        booleanAttribute(kAXEnabledAttribute, of: element) ?? true
    }

    private static func booleanAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func valueIsSettable(_ element: AXUIElement) -> Bool? {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        guard status == .success else { return nil }
        return settable.boolValue
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
