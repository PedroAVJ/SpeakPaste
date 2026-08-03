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
    case recordingStartTimedOut
    case recordingFinalizationTimedOut

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
        case .recordingStartTimedOut:
            "The microphone connected but did not begin delivering audio. SpeakPaste reset the connection; try again."
        case .recordingFinalizationTimedOut:
            "The microphone did not finish the recording. SpeakPaste reset the connection; try again."
        }
    }
}

struct MacRecordedSegment: Sendable {
    let url: URL
}

private final class MacRuntimeErrorLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: NSError?

    func record(_ error: NSError) {
        lock.lock()
        storedError = storedError ?? error
        lock.unlock()
    }

    func read() -> NSError? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

final class MacAudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "com.example.speakpaste.capture")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var activeDeviceID: String?
    private var sessionGeneration: UInt64 = 0
    private var runtimeErrorObserver: NSObjectProtocol?
    private var runtimeErrorLatch: MacRuntimeErrorLatch?
    private var runtimeError: NSError?
    private var recordingFailureHandler: (@Sendable (Error) -> Void)?

    private var segmentURL: URL?
    private var segmentGeneration: UInt64?
    private var segmentDidStart = false
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var stopContinuation: CheckedContinuation<MacRecordedSegment, Error>?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var finalizationTimeoutWorkItem: DispatchWorkItem?
    private var pendingRecordingError: Error?

    private let recordingStartTimeout: TimeInterval = 8
    private let finalizationTimeout: TimeInterval = 8

    func setRecordingFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        captureQueue.async { [weak self] in
            self?.recordingFailureHandler = handler
        }
    }

    var normalizedLevel: Double {
        captureQueue.sync {
            guard
                let channel = output?.connection(with: .audio)?.audioChannels.first,
                channel.averagePowerLevel.isFinite
            else {
                return 0
            }
            let decibels = max(-60, min(0, Double(channel.averagePowerLevel)))
            return pow(10, decibels / 20)
        }
    }

    /// Connects the selected microphone for the next dictation.
    /// Returns true only when a new audio session was created.
    func connect(deviceID: String) async throws -> Bool {
        try await ensurePermission()
        return try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }

                do {
                    if
                        self.activeDeviceID == deviceID,
                        self.session?.isRunning == true,
                        self.output != nil,
                        self.runtimeError == nil,
                        self.segmentURL == nil,
                        self.startContinuation == nil,
                        self.stopContinuation == nil
                    {
                        continuation.resume(returning: false)
                        return
                    }

                    guard
                        self.segmentURL == nil,
                        self.startContinuation == nil,
                        self.stopContinuation == nil,
                        self.output?.isRecording != true
                    else {
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

    /// Returns only after AVFoundation confirms that the first audio samples
    /// are being written. The caller can safely show "Speak now" after this.
    func startSegment() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                guard
                    let session = self.session,
                    session.isRunning,
                    self.runtimeError == nil,
                    let output = self.output
                else {
                    continuation.resume(throwing: self.runtimeError ?? MacAudioRecorderError.connectionFailed)
                    return
                }
                guard
                    !output.isRecording,
                    self.segmentURL == nil,
                    self.startContinuation == nil,
                    self.stopContinuation == nil
                else {
                    continuation.resume(throwing: MacAudioRecorderError.recorderBusy)
                    return
                }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SpeakPaste-\(UUID().uuidString)")
                    .appendingPathExtension("wav")
                try? FileManager.default.removeItem(at: url)

                self.segmentURL = url
                self.segmentGeneration = self.sessionGeneration
                self.segmentDidStart = false
                self.startContinuation = continuation
                self.pendingRecordingError = nil

                // Keep the Continuity session's native PCM format. This avoids
                // putting an AAC compressor/channel mixer in the capture graph.
                output.audioSettings = nil
                output.startRecording(to: url, outputFileType: .wav, recordingDelegate: self)
                self.scheduleStartTimeout(
                    output: output,
                    url: url,
                    generation: self.sessionGeneration
                )
            }
        }
    }

    func stop() async throws -> MacRecordedSegment {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                if let pendingRecordingError = self.pendingRecordingError {
                    self.pendingRecordingError = nil
                    continuation.resume(throwing: pendingRecordingError)
                    return
                }
                if let runtimeError = self.runtimeError {
                    continuation.resume(throwing: runtimeError)
                    return
                }
                guard
                    let output = self.output,
                    let url = self.segmentURL,
                    self.segmentGeneration == self.sessionGeneration,
                    self.segmentDidStart,
                    output.isRecording,
                    self.startContinuation == nil,
                    self.stopContinuation == nil
                else {
                    continuation.resume(throwing: MacAudioRecorderError.noActiveRecording)
                    return
                }

                self.stopContinuation = continuation
                output.stopRecording()
                self.scheduleFinalizationTimeout(
                    output: output,
                    url: url,
                    generation: self.sessionGeneration
                )
            }
        }
    }

    func disconnect() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.output?.isRecording == true {
                self.output?.stopRecording()
            }
            self.failSession(with: MacAudioRecorderError.connectionFailed)
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

        // WAV can hold the device's native PCM, so no compressor is needed.
        output.audioSettings = nil

        sessionGeneration &+= 1
        let generation = sessionGeneration
        let latch = MacRuntimeErrorLatch()
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self, weak session] notification in
            guard
                let session,
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            else { return }

            // startRunning() reports failures through this notification. It can
            // still leave isRunning true, so retain the error synchronously.
            latch.record(error)
            self?.captureQueue.async { [weak self, weak session] in
                guard let self, let session else { return }
                self.handleRuntimeError(error, session: session, generation: generation)
            }
        }

        self.session = session
        self.output = output
        activeDeviceID = deviceID
        runtimeErrorObserver = observer
        runtimeErrorLatch = latch
        runtimeError = nil

        session.startRunning()

        if let error = latch.read() {
            failSession(with: error)
            throw error
        }
        guard session.isRunning else {
            failSession(with: MacAudioRecorderError.connectionFailed)
            throw MacAudioRecorderError.connectionFailed
        }
    }

    private func handleRuntimeError(
        _ error: NSError,
        session: AVCaptureSession,
        generation: UInt64
    ) {
        guard self.session === session, sessionGeneration == generation else { return }
        runtimeError = error

        let shouldNotifyRecordingFailure = segmentDidStart
            && startContinuation == nil
            && stopContinuation == nil
        if shouldNotifyRecordingFailure {
            // Preserve the concrete failure so the user's second Command press
            // receives it rather than the vague "no active recording" error.
            pendingRecordingError = error
        }
        failSession(with: error, preservingPendingRecordingError: pendingRecordingError != nil)
        if shouldNotifyRecordingFailure {
            // Do not surface ERROR until stopRunning() has released Continuity.
            recordingFailureHandler?(error)
        }
    }

    private func scheduleStartTimeout(
        output: AVCaptureAudioFileOutput,
        url: URL,
        generation: UInt64
    ) {
        startTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak output] in
            guard
                let self,
                let output,
                self.matches(output: output, url: url, generation: generation),
                self.startContinuation != nil
            else { return }

            if output.isRecording {
                output.stopRecording()
            }
            self.failSession(with: MacAudioRecorderError.recordingStartTimedOut)
        }
        startTimeoutWorkItem = workItem
        captureQueue.asyncAfter(
            deadline: .now() + recordingStartTimeout,
            execute: workItem
        )
    }

    private func scheduleFinalizationTimeout(
        output: AVCaptureAudioFileOutput,
        url: URL,
        generation: UInt64
    ) {
        finalizationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak output] in
            guard
                let self,
                let output,
                self.matches(output: output, url: url, generation: generation),
                self.stopContinuation != nil
            else { return }

            self.failSession(with: MacAudioRecorderError.recordingFinalizationTimedOut)
        }
        finalizationTimeoutWorkItem = workItem
        captureQueue.asyncAfter(
            deadline: .now() + finalizationTimeout,
            execute: workItem
        )
    }

    private func matches(
        output: AVCaptureFileOutput,
        url: URL,
        generation: UInt64
    ) -> Bool {
        guard let currentOutput = self.output else { return false }
        return output === currentOutput
            && segmentURL == url
            && segmentGeneration == generation
            && sessionGeneration == generation
    }

    private func cancelSegmentTimeouts() {
        startTimeoutWorkItem?.cancel()
        finalizationTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        finalizationTimeoutWorkItem = nil
    }

    private func clearSegment() {
        cancelSegmentTimeouts()
        segmentURL = nil
        segmentGeneration = nil
        segmentDidStart = false
        startContinuation = nil
        stopContinuation = nil
    }

    private func removeRuntimeErrorObserver() {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        runtimeErrorObserver = nil
        runtimeErrorLatch = nil
    }

    private func finishSession() {
        let staleSession = session
        let staleURL = segmentURL
        removeRuntimeErrorObserver()
        clearSegment()
        session = nil
        output = nil
        activeDeviceID = nil
        runtimeError = nil
        pendingRecordingError = nil

        staleSession?.stopRunning()
        if let staleURL {
            try? FileManager.default.removeItem(at: staleURL)
        }
    }

    private func failSession(
        with error: Error,
        preservingPendingRecordingError: Bool = false
    ) {
        let startContinuation = self.startContinuation
        let stopContinuation = self.stopContinuation
        let staleSession = session
        let staleURL = segmentURL
        let savedPendingError = pendingRecordingError

        removeRuntimeErrorObserver()
        clearSegment()
        session = nil
        output = nil
        activeDeviceID = nil
        runtimeError = nil
        pendingRecordingError = preservingPendingRecordingError ? savedPendingError : nil

        // stopRunning() is synchronous. Keep teardown on the same serial queue
        // as connection/start so a retry cannot race the old iPhone stream.
        staleSession?.stopRunning()
        if let staleURL {
            try? FileManager.default.removeItem(at: staleURL)
        }

        startContinuation?.resume(throwing: error)
        stopContinuation?.resume(throwing: error)
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        captureQueue.async { [weak self, weak output] in
            guard let self, let output else { return }
            let generation = self.sessionGeneration
            guard
                self.matches(output: output, url: outputFileURL, generation: generation),
                let continuation = self.startContinuation
            else { return }

            self.startTimeoutWorkItem?.cancel()
            self.startTimeoutWorkItem = nil
            self.startContinuation = nil
            self.segmentDidStart = true
            continuation.resume(returning: outputFileURL)
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        captureQueue.async { [weak self, weak output] in
            guard let self, let output else { return }
            let generation = self.segmentGeneration
            guard
                let generation,
                self.matches(output: output, url: outputFileURL, generation: generation)
            else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }

            let nsError = error as NSError?
            let finishedSuccessfully = nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
            let failure = error.flatMap { finishedSuccessfully == true ? nil : $0 }

            if let failure {
                let preserveForNextStop = self.segmentDidStart
                    && self.startContinuation == nil
                    && self.stopContinuation == nil
                if preserveForNextStop {
                    self.pendingRecordingError = failure
                }
                self.failSession(
                    with: failure,
                    preservingPendingRecordingError: preserveForNextStop
                )
                if preserveForNextStop {
                    self.recordingFailureHandler?(failure)
                }
                return
            }

            if self.startContinuation != nil {
                // A recording that finishes before didStart never delivered a
                // sample, even if AVFoundation omitted an NSError.
                self.failSession(with: MacAudioRecorderError.connectionFailed)
                return
            }

            guard let continuation = self.stopContinuation else {
                let failure = MacAudioRecorderError.noActiveRecording
                self.pendingRecordingError = failure
                self.failSession(
                    with: failure,
                    preservingPendingRecordingError: true
                )
                self.recordingFailureHandler?(failure)
                return
            }

            let staleSession = self.session
            self.removeRuntimeErrorObserver()
            self.cancelSegmentTimeouts()
            self.segmentURL = nil
            self.segmentGeneration = nil
            self.segmentDidStart = false
            self.stopContinuation = nil
            self.session = nil
            self.output = nil
            self.activeDeviceID = nil
            self.runtimeError = nil
            self.pendingRecordingError = nil

            // The completed WAV no longer depends on the iPhone. Fully stop the
            // capture transport before transcription so macOS can release the
            // system-owned Continuity UI on the phone.
            staleSession?.stopRunning()

            continuation.resume(
                returning: MacRecordedSegment(
                    url: outputFileURL
                )
            )
        }
    }
}
