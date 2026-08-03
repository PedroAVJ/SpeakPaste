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
    case audioStreamNotReady
    case audioMonitorUnavailable

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
        case .audioStreamNotReady:
            "The microphone connected but never delivered audio. Lock the iPhone, keep it nearby, then try again."
        case .audioMonitorUnavailable:
            "macOS would not let SpeakPaste watch the microphone's audio stream, so it cannot tell when the iPhone is really ready. Recording was not started."
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

/// Counts audio sample buffers delivered by the capture session so callers can
/// tell whether audio is actually flowing, not just whether the session claims
/// to be running.
private final class MacSampleFlowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount: UInt64 = 0

    func increment() {
        lock.lock()
        storedCount &+= 1
        lock.unlock()
    }

    var count: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }
}

final class MacAudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "com.example.speakpaste.capture")
    private let sampleQueue = DispatchQueue(label: "com.example.speakpaste.samples")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var activeDeviceID: String?
    private var sessionGeneration: UInt64 = 0
    private var runtimeErrorObserver: NSObjectProtocol?
    private var runtimeErrorLatch: MacRuntimeErrorLatch?
    private var runtimeError: NSError?
    private var recordingFailureHandler: (@Sendable (Error, URL?) -> Void)?
    private let sampleFlow = MacSampleFlowCounter()

    private var segmentURL: URL?
    private var segmentGeneration: UInt64?
    private var segmentDidStart = false
    private var segmentStartRetriesRemaining = 0
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var stopContinuation: CheckedContinuation<MacRecordedSegment, Error>?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var finalizationTimeoutWorkItem: DispatchWorkItem?
    private var pendingRecordingError: Error?

    private let recordingStartTimeout: TimeInterval = 8
    private let finalizationTimeout: TimeInterval = 8
    private let steadyAudioTimeout: TimeInterval = 15
    private static let requiredSteadyWindows = 6

    /// The second closure argument carries a finalized partial recording when
    /// the stream died mid-dictation but AVFoundation completed the file.
    func setRecordingFailureHandler(_ handler: @escaping @Sendable (Error, URL?) -> Void) {
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

    /// Connects the selected microphone for the next dictation and returns
    /// only after it is delivering a steady audio stream. Continuity
    /// microphones report a running session seconds before audio actually
    /// flows, and recording across that wake-up gap kills the file output
    /// with AVError -11812 (media discontinuity).
    /// Returns true only when a new audio session was created.
    func connect(deviceID: String) async throws -> Bool {
        try await ensurePermission()
        let createdConnection = try await establishSession(deviceID: deviceID)
        do {
            try await waitForSteadyAudio(timeout: steadyAudioTimeout)
        } catch {
            await releaseSession(with: error)
            throw error
        }
        return createdConnection
    }

    private func establishSession(deviceID: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
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

    /// Waits until the capture session delivers audio buffers in several
    /// consecutive observation windows, proving the stream is live and gapless
    /// right now rather than merely negotiated.
    private func waitForSteadyAudio(timeout: TimeInterval) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var lastCount = sampleFlow.count
        var steadyWindows = 0
        while steadyWindows < Self.requiredSteadyWindows {
            if let failure = captureQueue.sync(execute: { currentSessionFailure() }) {
                throw failure
            }
            guard clock.now < deadline else {
                throw MacAudioRecorderError.audioStreamNotReady
            }
            try? await Task.sleep(for: .milliseconds(30))
            let count = sampleFlow.count
            steadyWindows = count > lastCount ? steadyWindows + 1 : 0
            lastCount = count
        }
    }

    /// Must run on captureQueue.
    private func currentSessionFailure() -> Error? {
        if let runtimeError { return runtimeError }
        guard session?.isRunning == true else { return MacAudioRecorderError.connectionFailed }
        return nil
    }

    private func releaseSession(with error: Error) async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.failSession(with: error)
                continuation.resume()
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sampleFlow.increment()
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
                self.segmentStartRetriesRemaining = 2
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

        // A lightweight tap that only counts delivered buffers. It is how
        // connect() proves the Continuity stream is really flowing before any
        // file recording starts. Without it there is no liveness gate at all,
        // so refuse the connection instead of recording blind.
        let sampleTap = AVCaptureAudioDataOutput()
        sampleTap.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(sampleTap) else {
            session.commitConfiguration()
            throw MacAudioRecorderError.audioMonitorUnavailable
        }
        session.addOutput(sampleTap)
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
            recordingFailureHandler?(error, nil)
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

    /// Must run on captureQueue.
    private func canRetrySegmentStart() -> Bool {
        startContinuation != nil
            && segmentStartRetriesRemaining > 0
            && runtimeError == nil
            && session?.isRunning == true
            && output?.isRecording != true
    }

    private func isRetryableStartFailure(_ failure: Error) -> Bool {
        let nsError = failure as NSError
        guard nsError.domain == AVFoundationErrorDomain else { return false }
        return nsError.code == AVError.Code.mediaDiscontinuity.rawValue
            || nsError.code == AVError.Code.noDataCaptured.rawValue
    }

    private func retrySegmentStart(url: URL, generation: UInt64) {
        segmentStartRetriesRemaining -= 1
        try? FileManager.default.removeItem(at: url)
        // Give the stream a moment to settle past the discontinuity before
        // writing again. The original start timeout stays armed as the
        // overall bound.
        captureQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard
                let self,
                let output = self.output,
                self.matches(output: output, url: url, generation: generation),
                self.startContinuation != nil,
                self.runtimeError == nil,
                self.session?.isRunning == true,
                !output.isRecording
            else { return }
            output.startRecording(to: url, outputFileType: .wav, recordingDelegate: self)
        }
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
        segmentStartRetriesRemaining = 0
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
                if self.canRetrySegmentStart(), self.isRetryableStartFailure(failure) {
                    // The stream stuttered before the first sample was written.
                    // It is still flowing, so restart the file instead of
                    // tearing down the whole Continuity connection.
                    self.retrySegmentStart(url: outputFileURL, generation: generation)
                    return
                }
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
                    self.recordingFailureHandler?(failure, nil)
                }
                return
            }

            if self.startContinuation != nil {
                // A recording that finishes before didStart never delivered a
                // sample, even if AVFoundation omitted an NSError.
                if self.canRetrySegmentStart() {
                    self.retrySegmentStart(url: outputFileURL, generation: generation)
                    return
                }
                self.failSession(with: MacAudioRecorderError.connectionFailed)
                return
            }

            guard let continuation = self.stopContinuation else {
                // The stream ended on its own, but AVFoundation finalized the
                // file, so the dictation captured so far is still usable. Keep
                // the file out of failSession's cleanup and hand it to the app
                // instead of discarding it.
                let failure = error ?? MacAudioRecorderError.noActiveRecording
                self.pendingRecordingError = failure
                self.segmentURL = nil
                self.failSession(
                    with: failure,
                    preservingPendingRecordingError: true
                )
                self.recordingFailureHandler?(failure, outputFileURL)
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
