import AVFoundation
import Combine
import Foundation

/// Audible confirmation for the dictation lifecycle.
///
/// SpeakPaste is driven by a global shortcut from inside whatever app the user
/// is typing in, so at the moment a key is pressed the capture indicator is frequently
/// off-screen, behind another window, or on a different display. Sound is the
/// only feedback that arrives regardless of where the user is looking, which is
/// why superwhisper and Wispr Flow both ship it.
@MainActor
final class MacSoundEffects: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "mac-sound-effects-enabled"

    /// These players are created and prepared once at launch. Playback therefore
    /// never searches for or decodes a file on the shortcut path. They use the
    /// normal app-output channel: System Sound Services uses the separate macOS
    /// alert-volume channel, which can be muted even while ordinary audio is
    /// audible and would make every SpeakPaste cue disappear.
    private let captureLive: AVAudioPlayer?
    private let captureReleased: AVAudioPlayer?
    private let deliveryVerified: AVAudioPlayer?
    private let needsAttention: AVAudioPlayer?

    init() {
        // Default on. A shortcut-driven tool that gives no feedback at all is a
        // worse first run than one that is briefly too chatty, and the toggle
        // is one click away.
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)

        captureLive = Self.loadSound(named: "capture-live")
        captureReleased = Self.loadSound(named: "capture-released")
        deliveryVerified = Self.loadSound(named: "delivery-verified")
        needsAttention = Self.loadSound(named: "needs-attention")
    }

    func playRecordingStarted() {
        play(captureLive)
    }

    func playRecordingStopped() {
        play(captureReleased)
    }

    func playDelivered() {
        play(deliveryVerified)
    }

    func playFailed() {
        play(needsAttention)
    }

    private static func loadSound(named name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else {
            return nil
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            return nil
        }
        player.volume = 1
        player.prepareToPlay()
        return player
    }

    private func play(_ player: AVAudioPlayer?) {
        guard isEnabled, let player else { return }
        player.currentTime = 0
        player.play()
    }
}
