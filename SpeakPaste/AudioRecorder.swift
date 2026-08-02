import AVFoundation
import Combine
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Enable it for SpeakPaste in Settings."
        case .couldNotStart:
            "The microphone could not start. Check whether another app is using it."
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

    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)

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

        let recorder = try AVAudioRecorder(url: url, settings: settings)
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
    func stop() -> URL? {
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        meterTask?.cancel()
        meterTask = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
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
