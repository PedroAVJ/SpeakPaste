import AppKit
import Combine
import Foundation

/// Audible confirmation for the dictation lifecycle.
///
/// SpeakPaste is driven by a global shortcut from inside whatever app the user
/// is typing in, so at the moment a key is pressed the HUD is frequently
/// off-screen, behind another window, or on a different display. Sound is the
/// only feedback that arrives regardless of where the user is looking, which is
/// why superwhisper and Wispr Flow both ship it.
@MainActor
final class MacSoundEffects: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "mac-sound-effects-enabled"

    /// Start and stop are the one pair the user must tell apart without
    /// looking, so they are separated by pitch as well as timbre: a bright,
    /// clipped tick opens the microphone and a lower hollow blip closes it.
    /// Both are short enough that a quick correction — stop, then start again —
    /// does not overlap itself.
    private let started: NSSound?
    private let stopped: NSSound?
    /// Text has landed in the target app. Deliberately the brightest of the
    /// five, since it is the only one that reports the job actually finished.
    private let delivered: NSSound?
    /// A soft descending two-tone. `Basso` and `Sosumi` read as alarms, and
    /// nothing here is worth startling someone mid-sentence over — the audio is
    /// salvaged and the transcript is recoverable either way.
    private let failed: NSSound?
    /// A transcript is parked waiting for its field to come back. Quiet and
    /// unresolved on purpose: this is a "later", not a "done" and not an error.
    private let held: NSSound?

    init() {
        // Default on. A shortcut-driven tool that gives no feedback at all is a
        // worse first run than one that is briefly too chatty, and the toggle
        // is one click away.
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)

        // Resolved once and held for the process lifetime. Each `NSSound(named:)`
        // searches and decodes a file from disk, and these fire on the main
        // actor at the two moments latency is most visible — the instant the
        // shortcut is pressed, and the instant it is released.
        //
        // A nil here means the name is missing from this system, which cannot
        // be recovered from by retrying, so the corresponding cue simply goes
        // silent instead of re-searching on every dictation.
        started = NSSound(named: "Tink")
        stopped = NSSound(named: "Bottle")
        delivered = NSSound(named: "Glass")
        failed = NSSound(named: "Funk")
        held = NSSound(named: "Purr")
    }

    func playRecordingStarted() {
        play(started)
    }

    func playRecordingStopped() {
        play(stopped)
    }

    func playDelivered() {
        play(delivered)
    }

    func playFailed() {
        play(failed)
    }

    func playHeld() {
        play(held)
    }

    private func play(_ sound: NSSound?) {
        guard isEnabled, let sound else { return }
        // These instances are shared across calls, and `NSSound` refuses to
        // start one that is already playing. Rewinding first keeps the second
        // of two rapid presses audible; stopping an idle sound is harmless.
        sound.stop()
        // `play()` returns immediately and mixes on its own thread, so nothing
        // here delays the recording it is announcing.
        _ = sound.play()
    }
}
