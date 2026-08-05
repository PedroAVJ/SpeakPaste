import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation

private let macEscapeKeyCode: Int64 = 0x35
private let macShortcutModifierMask: CGEventFlags = [
    .maskCommand,
    .maskAlternate,
    .maskControl,
    .maskShift,
]

/// Conventional key chords handled alongside the modifier-only dictation keys.
/// Keeping the action, modifiers, key and label together prevents the UI copy
/// from drifting away from what the event tap actually recognizes.
private enum MacShortcutChord {
    case releaseHeld
    case pasteLast
    case copyLast

    var character: Character {
        switch self {
        case .releaseHeld, .pasteLast: "v"
        case .copyLast: "c"
        }
    }

    var modifiers: CGEventFlags {
        switch self {
        case .releaseHeld: [.maskAlternate, .maskCommand]
        case .pasteLast, .copyLast: [.maskControl, .maskCommand]
        }
    }

    var label: String {
        var result = ""
        if modifiers.contains(.maskControl) { result += "⌃" }
        if modifiers.contains(.maskAlternate) { result += "⌥" }
        if modifiers.contains(.maskShift) { result += "⇧" }
        if modifiers.contains(.maskCommand) { result += "⌘" }
        return result + String(character).uppercased()
    }

    func matches(flags: CGEventFlags, keyCode: Int64) -> Bool {
        guard flags.intersection(macShortcutModifierMask) == modifiers else { return false }
        return keyCode == resolvedKeyCode
    }

    /// Match the character produced by the current keyboard layout, rather
    /// than assuming ANSI/QWERTY physical positions. V can reuse the resolver
    /// used by paste delivery; C uses the same Carbon translation directly.
    private var resolvedKeyCode: Int64 {
        switch self {
        case .releaseHeld, .pasteLast:
            Int64(MacKeyboardLayout.pasteKeyCode)
        case .copyLast:
            Int64(MacCopyKeyCode.current)
        }
    }
}

private enum MacCopyKeyCode {
    private static let ansiFallback: CGKeyCode = 0x08

    static var current: CGKeyCode {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return ansiFallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer in
            guard let header = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return ansiFallback
            }
            for keyCode in 0..<CGKeyCode(128) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    header,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    0,
                    UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: characters, count: length) == "c" {
                    return keyCode
                }
            }
            return ansiFallback
        }
    }
}

private func speakPasteEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let isRepeat = type == .keyDown
        && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let hotKey = Unmanaged<MacGlobalHotKey>.fromOpaque(userInfo).takeUnretainedValue()

    // The tap source is installed on the main run loop, so its callback is a
    // synchronous main-thread commit point. We must decide here whether to
    // suppress the event; dispatching the action later always lets the host app
    // see ⌥⌘V/Escape first.
    guard Thread.isMainThread else {
        DispatchQueue.main.async {
            hotKey.handle(
                type: type,
                rawFlags: flags.rawValue,
                keyCode: keyCode,
                isRepeat: isRepeat
            )
        }
        return Unmanaged.passUnretained(event)
    }
    let handled = MainActor.assumeIsolated {
        hotKey.handle(
            type: type,
            rawFlags: flags.rawValue,
            keyCode: keyCode,
            isRepeat: isRepeat
        )
    }
    return handled ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class MacGlobalHotKey {
    static var releaseLabel: String { MacShortcutChord.releaseHeld.label }
    static var pasteLastLabel: String { MacShortcutChord.pasteLast.label }
    static var copyLastLabel: String { MacShortcutChord.copyLast.label }

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var keyAction: ((MacDictationKey) -> Void)?
    private var isDictationOpen: (() -> Bool)?
    private var releaseAction: (() -> Void)?
    private var pasteLastAction: (() -> Void)?
    private var copyLastAction: (() -> Void)?
    private var recognizer = MacDictationKeyRecognizer()
    private var consumedKeyUps = Set<Int64>()

    /// `key` receives one bare tap of right Command, right Option, or fn, and
    /// Escape while `isDictationOpen` confirms there is an open dictation to
    /// discard. Every tap is instantaneous: there is no double-tap window, so
    /// no press is ever deferred and no verb can arrive late.
    /// `release` drops a held transcript at the current caret.
    /// `pasteLast` and `copyLast` recover the most recent finished transcript.
    func install(
        key: @escaping (MacDictationKey) -> Void,
        isDictationOpen: @escaping () -> Bool,
        release: @escaping () -> Void,
        pasteLast: @escaping () -> Void,
        copyLast: @escaping () -> Void
    ) {
        uninstall()
        keyAction = key
        self.isDictationOpen = isDictationOpen
        releaseAction = release
        pasteLastAction = pasteLast
        copyLastAction = copyLast

        // Superwhisper and Wispr Flow use an Accessibility-authorized CGEventTap
        // for modifier-only/global shortcuts. The event is always passed through
        // unchanged, so ordinary Command shortcuts keep their native behavior.
        // Never interrupt launch with a system permission dialog. The installed
        // app is granted Accessibility once, after its stable signature exists.
        refreshMonitor()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMonitor()
            }
        }
    }

    func uninstall() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        eventTap = nil
        eventTapSource = nil
        localMonitor = nil
        activationObserver = nil
        keyAction = nil
        isDictationOpen = nil
        releaseAction = nil
        pasteLastAction = nil
        copyLastAction = nil
        recognizer.reset()
        consumedKeyUps.removeAll()
    }

    @discardableResult
    fileprivate func handle(
        type: CGEventType,
        rawFlags: UInt64,
        keyCode: Int64,
        isRepeat: Bool = false
    ) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        let flags = CGEventFlags(rawValue: rawFlags)
        switch type {
        case .flagsChanged:
            recognizeModifierChange(rawFlags: rawFlags)
        case .keyDown:
            if isRepeat {
                recognizer.otherInputArrived()
                return consumedKeyUps.contains(keyCode)
            }
            let consumed = handleShortcutKeyDown(flags: flags, keyCode: keyCode)
            recognizer.otherInputArrived()
            if consumed { consumedKeyUps.insert(keyCode) }
            return consumed
        case .keyUp:
            return consumedKeyUps.remove(keyCode) != nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            recognizer.otherInputArrived()
        default:
            break
        }
        return false
    }

    /// Idempotent in BOTH directions.
    ///
    /// The previous version only ever installed. Revoking Accessibility left a
    /// dead CFMachPort in `eventTap`, so on re-granting, the `eventTap == nil`
    /// test was false and nothing was reinstalled — the global shortcut stayed
    /// dead until the app was relaunched, silently.
    func refreshMonitor() {
        if AXIsProcessTrusted() {
            guard eventTap == nil else { return }
            removeLocalMonitor()
            installEventTap()
        } else {
            removeEventTap()
            if localMonitor == nil { installLocalMonitor() }
        }
    }

    /// True when the shortcut works from any app, rather than only while
    /// SpeakPaste itself is frontmost.
    var isGlobal: Bool { eventTap != nil }

    private func removeEventTap() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTapSource = nil
        eventTap = nil
        recognizer.reset()
        consumedKeyUps.removeAll()
    }

    private func installEventTap() {
        let eventMask = eventMask(for: .flagsChanged)
            | eventMask(for: .keyDown)
            | eventMask(for: .keyUp)
            | eventMask(for: .leftMouseDown)
            | eventMask(for: .rightMouseDown)
            | eventMask(for: .otherMouseDown)
            | eventMask(for: .scrollWheel)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: speakPasteEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            installLocalMonitor()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installLocalMonitor() {
        let eventMask: NSEvent.EventTypeMask = [
            .flagsChanged,
            .keyDown,
            .keyUp,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleLocal(event) == true ? nil : event
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        recognizer.reset()
        consumedKeyUps.removeAll()
    }

    private func handleLocal(_ event: NSEvent) -> Bool {
        // NSEvent keeps the same device-dependent bits in the low half of
        // `rawValue`, so the decoding is identical to the tap path.
        let rawFlags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .flagsChanged:
            recognizeModifierChange(rawFlags: rawFlags)
        case .keyDown:
            if event.isARepeat {
                recognizer.otherInputArrived()
                return consumedKeyUps.contains(Int64(event.keyCode))
            }
            let consumed = handleShortcutKeyDown(
                flags: CGEventFlags(rawValue: rawFlags),
                keyCode: Int64(event.keyCode)
            )
            recognizer.otherInputArrived()
            if consumed { consumedKeyUps.insert(Int64(event.keyCode)) }
            return consumed
        case .keyUp:
            return consumedKeyUps.remove(Int64(event.keyCode)) != nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            recognizer.otherInputArrived()
        default:
            break
        }
        return false
    }

    private func handleShortcutKeyDown(flags: CGEventFlags, keyCode: Int64) -> Bool {
        if MacShortcutChord.releaseHeld.matches(flags: flags, keyCode: keyCode) {
            releaseAction?()
            return true
        } else if MacShortcutChord.pasteLast.matches(flags: flags, keyCode: keyCode) {
            pasteLastAction?()
            return true
        } else if MacShortcutChord.copyLast.matches(flags: flags, keyCode: keyCode) {
            copyLastAction?()
            return true
        } else if
            keyCode == macEscapeKeyCode,
            flags.intersection(macShortcutModifierMask).isEmpty,
            isDictationOpen?() == true
        {
            // The model remains authoritative and may still decline the
            // cancellation if its phase changed before this callback ran.
            keyAction?(.cancel)
            return true
        }
        return false
    }

    /// The modifier taps are never consumed. Suppressing a modifier's
    /// flagsChanged would tell every other app that the key was never pressed,
    /// which breaks ⌘, ⌥, and fn for their normal purposes; the verbs here ride
    /// alongside those keys rather than replacing them.
    private func recognizeModifierChange(rawFlags: UInt64) {
        guard let key = recognizer.modifiersChanged(
            MacModifierSide.snapshot(rawFlags: rawFlags)
        ) else {
            return
        }
        keyAction?(key)
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << type.rawValue
    }
}
