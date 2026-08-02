@preconcurrency import AVFoundation
import Foundation

enum MacAudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case deviceUnavailable
    case inputCannotBeAdded
    case outputCannotBeAdded
    case connectionFailed
    case recorderBusy
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Enable SpeakPaste in System Settings › Privacy & Security › Microphone."
        case .deviceUnavailable:
            "That microphone is no longer available. Lock the iPhone, keep it nearby, then refresh devices."
        case .inputCannotBeAdded:
            "macOS could not connect to the selected microphone."
        case .outputCannotBeAdded:
            "macOS could not create the audio recording output."
        case .connectionFailed:
            "The microphone appeared, but macOS could not keep its audio session running."
        case .recorderBusy:
            "The microphone is already starting or recording."
        case .noActiveRecording:
            "There is no active recording to stop."
        }
    }
}

final class MacAudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "com.example.speakpaste.capture")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var outputURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var activeDeviceID: String?

    var normalizedLevel: Double {
        guard
            let channel = output?.connection(with: .audio)?.audioChannels.first,
            channel.averagePowerLevel.isFinite
        else {
            return 0
        }
        let decibels = max(-60, min(0, Double(channel.averagePowerLevel)))
        return pow(10, decibels / 20)
    }

    /// Connect once and keep the underlying session running between dictations.
    /// Returns true only when a new audio session was created.
    func connect(deviceID: String) async throws -> Bool {
        try await ensurePermission()
        return try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else { return }
                do {
                    if
                        self.activeDeviceID == deviceID,
                        self.session?.isRunning == true,
                        self.output != nil
                    {
                        continuation.resume(returning: false)
                        return
                    }
                    guard self.output?.isRecording != true else {
                        throw MacAudioRecorderError.recorderBusy
                    }
                    self.finishSession()
                    try self.configureAndConnect(deviceID: deviceID)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startSegment() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard
                    let self,
                    self.session?.isRunning == true,
                    let output = self.output
                else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                guard !output.isRecording, self.stopContinuation == nil else {
                    continuation.resume(throwing: MacAudioRecorderError.recorderBusy)
                    return
                }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SpeakPaste-\(UUID().uuidString)")
                    .appendingPathExtension("m4a")
                try? FileManager.default.removeItem(at: url)
                self.outputURL = url
                output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
                continuation.resume(returning: url)
            }
        }
    }

    func stop() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self, let output = self.output, output.isRecording else {
                    continuation.resume(throwing: MacAudioRecorderError.noActiveRecording)
                    return
                }
                self.stopContinuation = continuation
                output.stopRecording()
            }
        }
    }

    func disconnect() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.output?.isRecording == true {
                self.output?.stopRecording()
            }
            self.finishSession()
        }
    }

    private func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MacAudioRecorderError.microphonePermissionDenied
            }
        default:
            throw MacAudioRecorderError.microphonePermissionDenied
        }
    }

    private func configureAndConnect(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw MacAudioRecorderError.deviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        let output = AVCaptureAudioFileOutput()

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MacAudioRecorderError.inputCannotBeAdded
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MacAudioRecorderError.outputCannotBeAdded
        }
        session.addOutput(output)
        session.commitConfiguration()

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]

        self.session = session
        self.output = output
        activeDeviceID = deviceID
        session.startRunning()
        guard session.isRunning else {
            finishSession()
            throw MacAudioRecorderError.connectionFailed
        }
    }

    private func finishSession() {
        session?.stopRunning()
        session = nil
        output = nil
        outputURL = nil
        activeDeviceID = nil
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            let continuation = self.stopContinuation
            self.stopContinuation = nil
            self.outputURL = nil

            let nsError = error as NSError?
            let finishedSuccessfully = nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
            if let error, finishedSuccessfully != true {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: outputFileURL)
            }
        }
    }
}
