import AppKit
@preconcurrency import ApplicationServices
import Foundation

/// Device-dependent modifier bits from IOLLEvent.h. `CGEventFlags.maskCommand`
/// and `NSEvent.ModifierFlags.command` cannot tell the two Command keys apart,
/// and this shortcut deliberately responds to the right one only.
enum MacModifierSide {
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010

    static func rightCommandDown(_ rawFlags: UInt64) -> Bool {
        rawFlags & rightCommand != 0
    }

    static func leftCommandDown(_ rawFlags: UInt64) -> Bool {
        rawFlags & leftCommand != 0
    }
}

struct CommandTapRecognizer {
    private(set) var isCommandDown = false
    private(set) var isTapCandidate = false

    mutating func modifiersChanged(commandDown: Bool, hasOtherModifiers: Bool) -> Bool {
        if commandDown {
            if !isCommandDown {
                isCommandDown = true
                isTapCandidate = !hasOtherModifiers
            } else if hasOtherModifiers {
                isTapCandidate = false
            }
            return false
        }

        guard isCommandDown else { return false }
        let recognizedTap = isTapCandidate && !hasOtherModifiers
        reset()
        return recognizedTap
    }

    mutating func keyPressed() {
        if isCommandDown {
            isTapCandidate = false
        }
    }

    mutating func reset() {
        isCommandDown = false
        isTapCandidate = false
    }
}

private let macReleaseKeyCode: Int64 = 0x09 // V

private func speakPasteEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let address = UInt(bitPattern: userInfo)
    let flags = event.flags
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let hotKey = Unmanaged<MacGlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
        hotKey.handle(type: type, rawFlags: flags.rawValue, keyCode: keyCode)
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class MacGlobalHotKey {
    static let toggleLabel = "right ⌘"
    static let releaseLabel = "⌥⌘V"

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var toggleAction: (() -> Void)?
    private var releaseAction: (() -> Void)?
    private var recognizer = CommandTapRecognizer()

    /// `toggle` starts and stops dictation on a bare right-Command tap.
    /// `release` drops a held transcript at the current caret.
    func install(toggle: @escaping () -> Void, release: @escaping () -> Void) {
        uninstall()
        toggleAction = toggle
        releaseAction = release

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
        toggleAction = nil
        releaseAction = nil
        recognizer.reset()
    }

    fileprivate func handle(type: CGEventType, rawFlags: UInt64, keyCode: Int64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let flags = CGEventFlags(rawValue: rawFlags)
        switch type {
        case .flagsChanged:
            let otherModifiers = flags.intersection([
                .maskAlphaShift,
                .maskShift,
                .maskControl,
                .maskAlternate,
                .maskSecondaryFn,
            ])
            recognizeModifierChange(
                commandDown: MacModifierSide.rightCommandDown(rawFlags),
                // A left Command held alongside the right one means this is a
                // chord, not the bare tap the shortcut responds to.
                hasOtherModifiers: !otherModifiers.isEmpty
                    || MacModifierSide.leftCommandDown(rawFlags)
            )
        case .keyDown:
            if isReleaseChord(flags: flags, keyCode: keyCode) {
                releaseAction?()
            }
            recognizer.keyPressed()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            recognizer.keyPressed()
        default:
            break
        }
    }

    private func isReleaseChord(flags: CGEventFlags, keyCode: Int64) -> Bool {
        guard keyCode == macReleaseKeyCode else { return false }
        guard flags.contains(.maskCommand), flags.contains(.maskAlternate) else { return false }
        return !flags.contains(.maskControl) && !flags.contains(.maskShift)
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
    }

    private func installEventTap() {
        let eventMask = eventMask(for: .flagsChanged)
            | eventMask(for: .keyDown)
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
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleLocal(event)
            return event
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        recognizer.reset()
    }

    private func handleLocal(_ event: NSEvent) {
        // NSEvent keeps the same device-dependent bits in the low half of
        // `rawValue`, so the left/right test is identical to the tap path.
        let rawFlags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .flagsChanged:
            let otherModifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .command])
            recognizeModifierChange(
                commandDown: MacModifierSide.rightCommandDown(rawFlags),
                hasOtherModifiers: !otherModifiers.isEmpty
                    || MacModifierSide.leftCommandDown(rawFlags)
            )
        case .keyDown:
            if
                Int64(event.keyCode) == macReleaseKeyCode,
                event.modifierFlags.contains(.command),
                event.modifierFlags.contains(.option),
                !event.modifierFlags.contains(.control),
                !event.modifierFlags.contains(.shift)
            {
                releaseAction?()
            }
            recognizer.keyPressed()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            recognizer.keyPressed()
        default:
            break
        }
    }

    private func recognizeModifierChange(commandDown: Bool, hasOtherModifiers: Bool) {
        if recognizer.modifiersChanged(
            commandDown: commandDown,
            hasOtherModifiers: hasOtherModifiers
        ) {
            toggleAction?()
        }
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << type.rawValue
    }
}
