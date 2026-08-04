import AudioToolbox
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

    /// These IDs are created once at launch and retained for the process
    /// lifetime. Playback therefore never searches for or decodes a file on the
    /// shortcut path. System Sound Services also respects the user's macOS
    /// sound-effects preference instead of inventing an app-specific volume.
    private let captureLive: SystemSoundID?
    private let captureReleased: SystemSoundID?
    private let deliveryVerified: SystemSoundID?
    private let needsAttention: SystemSoundID?

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

    deinit {
        for soundID in [
            captureLive,
            captureReleased,
            deliveryVerified,
            needsAttention,
        ].compactMap({ $0 }) {
            AudioServicesDisposeSystemSoundID(soundID)
        }
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
        play(needsAttention, asAlert: true)
    }

    private static func loadSound(named name: String) -> SystemSoundID? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else {
            return nil
        }
        var soundID: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == kAudioServicesNoError else {
            return nil
        }
        return soundID
    }

    private func play(_ soundID: SystemSoundID?, asAlert: Bool = false) {
        guard isEnabled, let soundID else { return }
        if asAlert {
            AudioServicesPlayAlertSound(soundID)
        } else {
            AudioServicesPlaySystemSound(soundID)
        }
    }
}
