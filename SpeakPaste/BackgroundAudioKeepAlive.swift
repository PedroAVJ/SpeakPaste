import AVFoundation
import Foundation

/// Keeps SpeakPaste resident with an audio session that is already active.
///
/// iOS refuses to activate a recording session for an app that is not already
/// running one, which is why a cold Back Tap could not open the microphone.
/// An app that is already producing audio never goes through that cold start,
/// so arming it once from the foreground makes every later background start
/// legal. This is the same reason superwhisper works while it is backgrounded
/// but has to open when it has been force quit.
@MainActor
final class BackgroundAudioKeepAlive {
    /// `.playback` avoids holding the microphone — and its indicator — while
    /// idle. Some configurations refuse to escalate to input from the
    /// background, so the engine can fall back to holding input the whole time.
    enum Mode: String {
        case playbackOnly
        case holdsInput

        var category: AVAudioSession.Category {
            switch self {
            case .playbackOnly: .playback
            case .holdsInput: .playAndRecord
            }
        }

        var options: AVAudioSession.CategoryOptions {
            switch self {
            case .playbackOnly: [.mixWithOthers]
            case .holdsInput: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
            }
        }
    }

    private(set) var mode: Mode?
    private var player: AVAudioPlayer?

    var isArmed: Bool { player?.isPlaying == true }

    func arm(mode: Mode) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(mode.category, mode: .default, options: mode.options)
        try session.setActive(true)

        if player == nil {
            player = try AVAudioPlayer(data: Self.silentWaveform())
            player?.numberOfLoops = -1
            // Inaudible, but enough for iOS to consider the app an audio app
            // and leave it running.
            player?.volume = 0
        }
        player?.play()
        self.mode = mode
    }

    func disarm() {
        player?.stop()
        player = nil
        mode = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// Move an already-active session to a category that permits input. This is
    /// a category change on a live session rather than a cold activation, which
    /// is the distinction iOS actually enforces.
    func prepareForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else { return }
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
        )
    }

    /// A minimal silent WAV, built in code so no audio asset has to ship.
    private static func silentWaveform() -> Data {
        let sampleRate = 8_000
        let seconds = 1
        let frames = sampleRate * seconds
        let dataBytes = frames * 2

        var data = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        data.append(Data(count: dataBytes))
        return data
    }
}
