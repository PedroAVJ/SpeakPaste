import AppKit
@preconcurrency import ApplicationServices
import Foundation

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

private func speakPasteEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let address = UInt(bitPattern: userInfo)
    let flags = event.flags
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let hotKey = Unmanaged<MacGlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
        hotKey.handle(type: type, flags: flags)
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class MacGlobalHotKey {
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var action: (() -> Void)?
    private var recognizer = CommandTapRecognizer()

    func install(action: @escaping () -> Void) {
        uninstall()
        self.action = action

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
        action = nil
        recognizer.reset()
    }

    fileprivate func handle(type: CGEventType, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

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
                commandDown: flags.contains(.maskCommand),
                hasOtherModifiers: !otherModifiers.isEmpty
            )
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            recognizer.keyPressed()
        default:
            break
        }
    }

    private func refreshMonitor() {
        if AXIsProcessTrusted() {
            if eventTap == nil {
                removeLocalMonitor()
                installEventTap()
            }
        } else if localMonitor == nil {
            installLocalMonitor()
        }
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
        switch event.type {
        case .flagsChanged:
            let activeModifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            let otherModifiers = activeModifiers.subtracting(.command)
            recognizeModifierChange(
                commandDown: activeModifiers.contains(.command),
                hasOtherModifiers: !otherModifiers.isEmpty
            )
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
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
            action?()
        }
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << type.rawValue
    }
}
