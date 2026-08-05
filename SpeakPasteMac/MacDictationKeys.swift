import Foundation

/// The lifecycle of one dictation. `paused` is the state the whole control
/// surface is built around: the microphone is back in the user's hands, every
/// segment spoken so far is banked and transcribing, and nothing has been
/// delivered. A dictation rests there indefinitely; only `fn` or `Esc` leaves.
enum MacCapturePhase: Equatable {
    case ready
    case connecting
    case recording
    case finalizing
    case paused
    case succeeded(String)
    case failed(String)

    /// The whole capture surface is occupied — no device change, no import, and
    /// no terminal success or failure may overwrite what is happening.
    var isBusy: Bool {
        switch self {
        case .connecting, .recording, .finalizing, .paused: true
        case .ready, .succeeded, .failed: false
        }
    }

    /// SpeakPaste owns (or is acquiring or releasing) the microphone. A resting
    /// dictation deliberately does not: the iPhone is handed back at every
    /// pause, not only at the end.
    var holdsMicrophone: Bool {
        switch self {
        case .connecting, .recording, .finalizing: true
        case .ready, .paused, .succeeded, .failed: false
        }
    }

    /// A dictation is open. Nothing may reach the cursor until it closes.
    var dictationIsOpen: Bool { isBusy }
}

/// Where an in-flight finalization should leave the dictation. The source keys
/// can only ever choose `rest`; `close` is reachable only from `fn`.
enum MacFinalizationOutcome: Equatable {
    /// Bank the segment and rest. Nothing is delivered and nothing is destroyed.
    case rest
    /// Bank the segment, close the dictation, and deliver everything banked.
    case close
    /// Abandon the segment without transcribing it, then apply the safe floor.
    case discard
}

/// The four keys that drive a dictation. Each one owns exactly one verb, and
/// the verb never depends on how fast the key is tapped: there are no double
/// taps and no timing windows anywhere in this control surface.
///
/// The two source keys can only start, pause, or resume — they can never
/// deliver text and never destroy it. `end` always delivers; `cancel` always
/// discards. That asymmetry is the whole safety story, so it is expressed here
/// rather than rediscovered at each call site.
enum MacDictationKey: String, CaseIterable, Identifiable, Sendable {
    /// Right Command: capture on this Mac's own microphone.
    case macSource
    /// Right Option: capture on the Continuity iPhone microphone.
    case iPhoneSource
    /// fn: close the dictation and deliver everything banked.
    case end
    /// Escape: discard.
    case cancel

    var id: String { rawValue }

    /// The subset recognized as a bare modifier press-and-release. Escape is an
    /// ordinary key and is matched by key code instead.
    static let modifierKeys: [MacDictationKey] = [.macSource, .iPhoneSource, .end]

    var isModifierKey: Bool { Self.modifierKeys.contains(self) }

    /// Keycap text, as printed on the physical key.
    var label: String {
        switch self {
        case .macSource: "⌘"
        case .iPhoneSource: "⌥"
        case .end: "fn"
        case .cancel: "esc"
        }
    }

    /// How the shortcut is written in prose and in the dashboard's shortcut
    /// tables. The side matters for the two modifiers that exist twice.
    var shortcutLabel: String {
        switch self {
        case .macSource: "right ⌘"
        case .iPhoneSource: "right ⌥"
        case .end: "fn"
        case .cancel: "Esc"
        }
    }

    /// Spoken form for VoiceOver, which reads "⌘" as "command" only by luck.
    var spokenLabel: String {
        switch self {
        case .macSource: "Right Command key"
        case .iPhoneSource: "Right Option key"
        case .end: "Function key"
        case .cancel: "Escape key"
        }
    }

    /// The semantic capture source a source key selects, or nil for the two
    /// keys that are not sources.
    var inputMode: MacInputMode? {
        switch self {
        case .macSource: .mac
        case .iPhoneSource: .iPhone
        case .end, .cancel: nil
        }
    }

    static func sourceKey(for mode: MacInputMode) -> MacDictationKey {
        switch mode {
        case .mac: .macSource
        case .iPhone: .iPhoneSource
        }
    }
}

/// The single description of what each key does, so the Settings table, the
/// dashboard's shortcut table, and the onboarding copy cannot drift apart.
struct MacDictationShortcut: Identifiable {
    let dictationKey: MacDictationKey
    let purpose: String

    var id: String { dictationKey.rawValue }
    var key: String { dictationKey.shortcutLabel }
    var spokenKey: String { dictationKey.spokenLabel }

    static let all: [MacDictationShortcut] = [
        MacDictationShortcut(
            dictationKey: .macSource,
            purpose: "Mac microphone — start, pause, or resume"
        ),
        MacDictationShortcut(
            dictationKey: .iPhoneSource,
            purpose: "iPhone microphone — start, pause, or resume"
        ),
        MacDictationShortcut(
            dictationKey: .end,
            purpose: "End the dictation and deliver everything banked"
        ),
        MacDictationShortcut(
            dictationKey: .cancel,
            purpose: "Discard — the live segment, or a resting dictation's banked text"
        ),
    ]
}

/// Device-dependent modifier bits from IOLLEvent.h. `CGEventFlags.maskCommand`
/// and `NSEvent.ModifierFlags.command` cannot tell the two Command keys apart,
/// and these shortcuts deliberately respond to the right-hand keys only. The
/// same bits appear in the low half of `NSEvent.modifierFlags.rawValue`, so one
/// decoder serves both the event tap and the local monitor.
enum MacModifierSide {
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000

    /// fn has no left/right form; this is `CGEventFlags.maskSecondaryFn`, which
    /// `NSEvent.ModifierFlags.function` shares bit-for-bit.
    static let function: UInt64 = 0x0080_0000

    /// Modifiers that make any watched press a chord rather than a bare tap.
    /// Caps Lock is included deliberately: a latched modifier changes what the
    /// rest of the keyboard means, so it must not be part of a bare gesture.
    private static let disqualifying: UInt64 = leftControl
        | leftShift
        | rightShift
        | leftCommand
        | leftOption
        | rightControl
        | 0x0001_0000 // maskAlphaShift
        | 0x0002_0000 // maskShift
        | 0x0004_0000 // maskControl

    static func snapshot(rawFlags: UInt64) -> MacModifierSnapshot {
        MacModifierSnapshot(
            rightCommand: rawFlags & rightCommand != 0,
            rightOption: rawFlags & rightOption != 0,
            function: rawFlags & function != 0,
            otherModifiers: rawFlags & disqualifying != 0
        )
    }
}

/// One sample of the modifier keyboard, reduced to what the recognizer needs.
/// Everything above the event tap is a pure value, so regression tests can
/// drive the whole gesture without an Accessibility grant or a real keyboard.
struct MacModifierSnapshot: Equatable, Sendable {
    var rightCommand = false
    var rightOption = false
    var function = false
    /// Any modifier that is not one of the three watched keys — including the
    /// *left* Command and Option, which make this a chord rather than the bare
    /// tap the shortcut responds to.
    var otherModifiers = false

    var downKeys: [MacDictationKey] {
        var keys: [MacDictationKey] = []
        if rightCommand { keys.append(.macSource) }
        if rightOption { keys.append(.iPhoneSource) }
        if function { keys.append(.end) }
        return keys
    }
}

/// Recognizes one bare press-and-release of a single watched modifier key.
///
/// A tap is emitted only if, for the whole time that key was down, it was the
/// only modifier held and no other key or mouse button was pressed. Anything
/// else is someone using ⌘, ⌥, or fn for what those keys normally do, and must
/// pass through untouched.
struct MacDictationKeyRecognizer {
    private(set) var heldKey: MacDictationKey?
    /// Set the moment this press stops being a bare tap. It is cleared only
    /// when every watched key is up again, so releasing one half of a chord can
    /// never promote the surviving key into a fresh tap candidate.
    private var isPolluted = false

    mutating func modifiersChanged(_ snapshot: MacModifierSnapshot) -> MacDictationKey? {
        let down = snapshot.downKeys
        guard !down.isEmpty else {
            let recognized = !isPolluted && !snapshot.otherModifiers ? heldKey : nil
            reset()
            return recognized
        }
        if down.count > 1 || snapshot.otherModifiers {
            isPolluted = true
        }
        if heldKey == nil, down.count == 1 {
            heldKey = down[0]
        }
        return nil
    }

    /// Any ordinary key or mouse press while a watched key is down proves this
    /// is a chord. Presses with nothing watched held are none of our business.
    mutating func otherInputArrived() {
        guard heldKey != nil else { return }
        isPolluted = true
    }

    mutating func reset() {
        heldKey = nil
        isPolluted = false
    }
}
