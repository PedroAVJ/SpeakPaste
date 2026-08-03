import AVFoundation
import Combine
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case couldNotStart
    case configurationFailed(stage: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Enable it for SpeakPaste in Settings."
        case .couldNotStart:
            "The microphone could not start. Check whether another app is using it."
        case let .configurationFailed(stage, underlying):
            "Microphone \(stage) failed: \(underlying.localizedDescription)"
        }
    }
}

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// - Parameter configuresSession: false when a keep-alive already owns an
    ///   active session. Reconfiguring it would tear down the very thing that
    ///   makes a background start legal.
    func start(configuresSession: Bool = true) throws -> URL {
        let session = AVAudioSession.sharedInstance()
        if configuresSession {
            do {
                // This app only captures speech. `spokenAudio` is a playback
                // mode, and `duckOthers` is not valid with the record-only
                // category; that invalid combination returns OSStatus -50 on
                // the iPhone.
                try session.setCategory(.record, mode: .measurement, options: [])
            } catch {
                throw AudioRecorderError.configurationFailed(
                    stage: "configuration",
                    underlying: error
                )
            }
            do {
                try session.setActive(true)
            } catch {
                throw AudioRecorderError.configurationFailed(
                    stage: "activation",
                    underlying: error
                )
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakPaste", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 96_000,
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioRecorderError.configurationFailed(
                stage: "recorder creation",
                underlying: error
            )
        }
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioRecorderError.couldNotStart
        }

        self.recorder = recorder
        isRecording = true
        duration = 0
        level = 0
        startMetering()
        return url
    }

    @discardableResult
    func stop(deactivatesSession: Bool = true) -> URL? {
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        meterTask?.cancel()
        meterTask = nil
        isRecording = false
        level = 0
        if deactivatesSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        return url
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.duration = recorder.currentTime
                let decibels = recorder.averagePower(forChannel: 0)
                self.level = max(0, min(1, pow(10, decibels / 28)))
            }
        }
    }
}
