@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
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
    case recordingFileProtectionFailed
    case audioStreamNotReady
    case audioStreamSilent
    case audioMonitorUnavailable
    case audioStreamStalled

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
        case .recordingFileProtectionFailed:
            "SpeakPaste could not protect the recording file, so recording was stopped."
        case .audioStreamNotReady:
            "The microphone connected but never delivered audio. Lock the iPhone, keep it nearby, then try again."
        case .audioStreamSilent:
            "The microphone is connected but sending silence. Check that it is not muted, and that the iPhone is not on a call."
        case .audioMonitorUnavailable:
            "macOS would not let SpeakPaste watch the microphone's audio stream, so it cannot tell when the iPhone is really ready. Recording was not started."
        case .audioStreamStalled:
            "The microphone stopped sending audio partway through. SpeakPaste kept what it had already recorded."
        }
    }
}

struct MacRecordedSegment: Sendable {
    let url: URL
}

/// A recording failure that occurred after a usable portion of the WAV had
/// already reached disk. The recorder has fully released its capture session
/// before throwing this error, so the caller can immediately move or upload
/// `audioURL` without keeping ownership of the Continuity microphone.
struct MacAudioRecorderSalvagedFailure: LocalizedError {
    let underlying: Error
    let audioURL: URL

    var errorDescription: String? {
        underlying.localizedDescription
    }
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

/// Tracks both the arrival of audio buffers and whether they actually contain
/// sound.
///
/// Counting buffers alone is not enough: a hardware-muted microphone, or an
/// iPhone that has handed its audio to a phone call, delivers a perfectly
/// steady stream of digital silence. That passes an arrival-only gate, so the
/// capture indicator says Listening, the user talks for a minute, and the run ends in an
/// empty transcript.
private final class MacSampleFlowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount: UInt64 = 0
    private var storedAudibleCount: UInt64 = 0

    /// Below this peak amplitude a buffer is indistinguishable from a muted
    /// input. Ordinary room tone sits well above it.
    private static let silenceFloor: Float = 0.0015

    func record(peakAmplitude: Float) {
        lock.lock()
        storedCount &+= 1
        if peakAmplitude > Self.silenceFloor { storedAudibleCount &+= 1 }
        lock.unlock()
    }

    var count: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    var audibleCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storedAudibleCount
    }
}

private final class MacCaptureSessionAudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate,
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
    /// A late `didFinishRecordingTo` callback belongs to AVFoundation, not to
    /// the caller that now owns a salvaged file. Remember those URLs so that a
    /// stale delegate callback cannot delete a partial WAV after it was handed
    /// off for recovery.
    private var preservedPartialURLs = Set<URL>()

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
        // Escape may cancel while the first-run permission sheet is open.
        // Never create a capture session after that canceled sheet resolves.
        try Task.checkCancellation()
        let connection = try await establishSession(deviceID: deviceID)
        do {
            try await waitForSteadyAudio(
                timeout: steadyAudioTimeout,
                generation: connection.generation
            )
        } catch {
            await releaseSession(with: error, generation: connection.generation)
            throw error
        }
        return connection.wasCreated
    }

    private struct ConnectionReceipt: Sendable {
        let wasCreated: Bool
        let generation: UInt64
    }

    private func establishSession(deviceID: String) async throws -> ConnectionReceipt {
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
                        continuation.resume(
                            returning: ConnectionReceipt(
                                wasCreated: false,
                                generation: self.sessionGeneration
                            )
                        )
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
                    continuation.resume(
                        returning: ConnectionReceipt(
                            wasCreated: true,
                            generation: self.sessionGeneration
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Waits until the capture session delivers audio buffers in several
    /// consecutive observation windows, proving the stream is live and gapless
    /// right now rather than merely negotiated.
    private func waitForSteadyAudio(
        timeout: TimeInterval,
        generation: UInt64
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var lastCount = sampleFlow.count
        var lastAudibleCount = sampleFlow.audibleCount
        var steadyWindows = 0
        var audibleWindows = 0
        while steadyWindows < Self.requiredSteadyWindows {
            try Task.checkCancellation()
            if let failure = captureQueue.sync(execute: {
                currentSessionFailure(generation: generation)
            }) {
                throw failure
            }
            guard clock.now < deadline else {
                // Buffers arriving without sound is a different fault from no
                // buffers at all, and it has a different fix.
                throw lastCount > 0
                    ? MacAudioRecorderError.audioStreamSilent
                    : MacAudioRecorderError.audioStreamNotReady
            }
            try await Task.sleep(for: .milliseconds(30))
            let count = sampleFlow.count
            let audibleCount = sampleFlow.audibleCount
            steadyWindows = count > lastCount ? steadyWindows + 1 : 0
            audibleWindows = audibleCount > lastAudibleCount ? audibleWindows + 1 : audibleWindows
            lastCount = count
            lastAudibleCount = audibleCount
        }
        // A steady stream of digital silence is not a ready microphone.
        guard audibleWindows > 0 else {
            throw MacAudioRecorderError.audioStreamSilent
        }
    }

    /// Must run on captureQueue.
    private func currentSessionFailure(generation: UInt64) -> Error? {
        guard sessionGeneration == generation else {
            return MacAudioRecorderError.connectionFailed
        }
        if let runtimeError { return runtimeError }
        guard session?.isRunning == true else { return MacAudioRecorderError.connectionFailed }
        return nil
    }

    /// A canceled connection can finish unwinding after its replacement has
    /// already been configured. Tear down only the generation that failed;
    /// otherwise the stale task would stop the new Mac/iPhone session.
    private func releaseSession(with error: Error, generation: UInt64) async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                if let self, self.sessionGeneration == generation {
                    self.failSession(with: error)
                }
                continuation.resume()
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sampleFlow.record(peakAmplitude: Self.peakAmplitude(of: sampleBuffer))
    }

    /// Peak absolute amplitude across the buffer, normalized to 0...1. Returns
    /// zero for formats it cannot read, which is treated as silence — failing
    /// closed is correct here, since the whole point is refusing to promise a
    /// live microphone that is not.
    private nonisolated static func peakAmplitude(of sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return 0
        }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return 0 }

        let format = basicDescription.pointee
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0

        for buffer in UnsafeMutableAudioBufferListPointer(&audioBufferList) {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            if isFloat {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count { peak = max(peak, abs(samples[index])) }
            } else if format.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count {
                    peak = max(peak, abs(Float(samples[index]) / Float(Int16.max)))
                }
            }
        }
        return peak
    }

    /// Lets the app watch stream health while recording, not only before it.
    var deliveredSampleCount: UInt64 { sampleFlow.count }

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
                // AVFoundation creates the destination itself. Harden it on the
                // first synchronous opportunity, then require 0600 again in the
                // did-start callback before telling the app recording began.
                self.hardenRecordingPermissions(
                    at: url,
                    output: output,
                    generation: self.sessionGeneration
                )
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

    /// Asynchronous teardown receipt for interactive cancellation. Unlike the
    /// fire-and-forget variant, this returns only after `stopRunning()` has
    /// released the physical or Continuity microphone, so callers can pair a
    /// closing cue and visual state with the real hardware lifecycle.
    func disconnectAndWait() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if self.output?.isRecording == true {
                    self.output?.stopRecording()
                }
                self.failSession(with: MacAudioRecorderError.connectionFailed)
                continuation.resume()
            }
        }
    }

    /// Used only at process/lifecycle boundaries where returning before
    /// `stopRunning()` would leave the iPhone's Continuity microphone owned by
    /// a process that is about to sleep or exit.
    func disconnectSynchronously() {
        captureQueue.sync {
            if output?.isRecording == true {
                output?.stopRecording()
            }
            failSession(with: MacAudioRecorderError.connectionFailed)
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
        let salvagedURL = failSession(
            with: error,
            preservingPendingRecordingError: pendingRecordingError != nil,
            preservingPartialRecording: segmentDidStart
        )
        if shouldNotifyRecordingFailure {
            // Do not surface the error until stopRunning() has released Continuity.
            recordingFailureHandler?(error, salvagedURL)
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

            self.failSession(
                with: MacAudioRecorderError.recordingFinalizationTimedOut,
                preservingPartialRecording: self.segmentDidStart
            )
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
            hardenRecordingPermissions(at: url, output: output, generation: generation)
        }
    }

    /// AVFoundation owns destination creation. Poll briefly from the capture
    /// queue so a file created just after `startRecording` is chmodded before
    /// the delegate callback too; the callback remains the final mandatory
    /// privacy gate.
    private func hardenRecordingPermissions(
        at url: URL,
        output: AVCaptureAudioFileOutput,
        generation: UInt64,
        attemptsRemaining: Int = 50
    ) {
        if MacActiveCaptureRecovery.makeRecordingPrivate(at: url) { return }
        guard
            attemptsRemaining > 0,
            matches(output: output, url: url, generation: generation),
            startContinuation != nil
        else {
            return
        }
        captureQueue.asyncAfter(deadline: .now() + 0.01) { [weak self, weak output] in
            guard let self, let output else { return }
            self.hardenRecordingPermissions(
                at: url,
                output: output,
                generation: generation,
                attemptsRemaining: attemptsRemaining - 1
            )
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

    /// Tears down the complete capture session before resuming either
    /// continuation. When requested, a partially written WAV is retained only
    /// if it is a regular, non-symlink file with a RIFF/WAVE header and payload
    /// beyond the minimum header size.
    @discardableResult
    private func failSession(
        with error: Error,
        preservingPendingRecordingError: Bool = false,
        preservingPartialRecording: Bool = false
    ) -> URL? {
        let startContinuation = self.startContinuation
        let stopContinuation = self.stopContinuation
        let staleSession = session
        let staleURL = segmentURL
        let staleSegmentDidStart = segmentDidStart
        let savedPendingError = pendingRecordingError

        removeRuntimeErrorObserver()
        clearSegment()
        session = nil
        output = nil
        activeDeviceID = nil
        runtimeError = nil

        // stopRunning() is synchronous. Keep teardown on the same serial queue
        // as connection/start so a retry cannot race the old iPhone stream.
        staleSession?.stopRunning()

        let salvagedURL: URL?
        if
            preservingPartialRecording,
            staleSegmentDidStart,
            let staleURL,
            isPlausiblePartialWAV(at: staleURL)
        {
            salvagedURL = staleURL
            preservedPartialURLs.insert(staleURL.standardizedFileURL)
        } else {
            salvagedURL = nil
        }

        if salvagedURL == nil, let staleURL {
            try? FileManager.default.removeItem(at: staleURL)
        }

        let surfacedError: Error
        if let salvagedURL {
            surfacedError = MacAudioRecorderSalvagedFailure(
                underlying: error,
                audioURL: salvagedURL
            )
        } else {
            surfacedError = error
        }
        if preservingPendingRecordingError {
            pendingRecordingError = salvagedURL == nil ? savedPendingError : surfacedError
        } else {
            pendingRecordingError = nil
        }

        startContinuation?.resume(throwing: error)
        stopContinuation?.resume(throwing: surfacedError)
        return salvagedURL
    }

    /// Checks enough structure to avoid treating an empty placeholder, a
    /// directory, or an attacker-controlled symlink as recoverable audio. A
    /// canonical PCM WAV header is at least 44 bytes, so any retained file must
    /// contain bytes beyond that header as evidence that recording began.
    private func isPlausiblePartialWAV(at url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard
            let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize > 44,
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return false
        }
        defer { try? handle.close() }

        guard
            let header = try? handle.read(upToCount: 12),
            header.count == 12
        else {
            return false
        }
        return Array(header.prefix(4)) == Array("RIFF".utf8)
            && Array(header.dropFirst(8).prefix(4)) == Array("WAVE".utf8)
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

            guard MacActiveCaptureRecovery.makeRecordingPrivate(at: outputFileURL) else {
                if output.isRecording { output.stopRecording() }
                self.failSession(with: MacAudioRecorderError.recordingFileProtectionFailed)
                return
            }

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
                if self.preservedPartialURLs.remove(outputFileURL.standardizedFileURL) != nil {
                    return
                }
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
                let salvagedURL = self.failSession(
                    with: failure,
                    preservingPendingRecordingError: preserveForNextStop,
                    preservingPartialRecording: self.segmentDidStart
                )
                // This is the delegate callback the tracking set protects
                // against, so it has now been consumed.
                if let salvagedURL {
                    self.preservedPartialURLs.remove(salvagedURL.standardizedFileURL)
                }
                if preserveForNextStop {
                    self.recordingFailureHandler?(failure, salvagedURL)
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
                let salvagedURL = self.failSession(
                    with: failure,
                    preservingPendingRecordingError: true,
                    preservingPartialRecording: self.segmentDidStart
                )
                if let salvagedURL {
                    self.preservedPartialURLs.remove(salvagedURL.standardizedFileURL)
                }
                self.recordingFailureHandler?(failure, salvagedURL)
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

// MARK: - Voice Processing Continuity capture

/// Routes a selected Core Audio input through the system default-input slot
/// while Apple's Voice Processing I/O unit owns it. AVAudioEngine's public
/// macOS contract uses the default input device; binding the Continuity device
/// directly to the underlying unit exposes its raw multichannel transport and
/// cannot initialize Voice Processing I/O. The route is restored after every
/// segment, and only if it still contains the value SpeakPaste set so that a
/// user change made during capture is never overwritten.
private enum MacCoreAudioInputRoute {
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first { stringProperty(kAudioDevicePropertyDeviceUID, of: $0) == uid }
    }

    static func defaultDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &value
            ) == noErr,
            value != kAudioObjectUnknown
        else {
            return nil
        }
        return value
    }

    static func selectDefaultDevice(_ deviceID: AudioObjectID) throws {
        guard allDeviceIDs().contains(deviceID) else {
            throw MacAudioRecorderError.deviceUnavailable
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &value
        )
        guard status == noErr, defaultDeviceID() == deviceID else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status == noErr ? kAudioHardwareUnspecifiedError : status)
            )
        }
    }

    static func restore(
        originalDeviceID: AudioObjectID?,
        replacing selectedDeviceID: AudioObjectID
    ) {
        guard
            let originalDeviceID,
            originalDeviceID != selectedDeviceID,
            defaultDeviceID() == selectedDeviceID,
            allDeviceIDs().contains(originalDeviceID)
        else {
            return
        }
        try? selectDefaultDevice(originalDeviceID)
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ) == noErr
        else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &values
            ) == noErr
        else {
            return []
        }
        return values
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &value
            ) == noErr
        else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }
}

private final class MacVoiceProcessingSampleFlow: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount: UInt64 = 0
    private var storedPeak: Float = 0

    func record(buffer: AVAudioPCMBuffer) {
        var peak: Float = 0
        if let samples = buffer.floatChannelData?.pointee {
            for index in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(samples[index]))
            }
        }

        lock.lock()
        storedCount &+= 1
        // Decay across silent buffers while keeping the meter readable between
        // Voice Processing I/O's relatively large callback slices.
        storedPeak = max(peak, storedPeak * 0.72)
        lock.unlock()
    }

    var count: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    var normalizedLevel: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(min(1, max(0, storedPeak)))
    }
}

private final class MacVoiceProcessingFileSink: @unchecked Sendable {
    struct WriteReceipt {
        let wroteFirstFrames: Bool
        let error: Error?
    }

    struct FinishReceipt {
        let url: URL?
        let frameCount: AVAudioFramePosition
        let error: Error?
    }

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var frameCount: AVAudioFramePosition = 0
    private var storedError: Error?
    private var surfacedError = false

    func start(url: URL, format: AVAudioFormat) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        lock.lock()
        self.file = file
        self.url = url
        frameCount = 0
        storedError = nil
        surfacedError = false
        lock.unlock()
    }

    func consume(_ buffer: AVAudioPCMBuffer) -> WriteReceipt {
        lock.lock()
        defer { lock.unlock() }
        guard let file, storedError == nil else {
            if let storedError, !surfacedError {
                surfacedError = true
                return WriteReceipt(wroteFirstFrames: false, error: storedError)
            }
            return WriteReceipt(wroteFirstFrames: false, error: nil)
        }

        let wasEmpty = frameCount == 0
        do {
            try file.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
            return WriteReceipt(
                wroteFirstFrames: wasEmpty && buffer.frameLength > 0,
                error: nil
            )
        } catch {
            storedError = error
            surfacedError = true
            return WriteReceipt(wroteFirstFrames: false, error: error)
        }
    }

    func finish() -> FinishReceipt {
        lock.lock()
        let receipt = FinishReceipt(url: url, frameCount: frameCount, error: storedError)
        // Dropping the last file reference finalizes the WAV header before the
        // caller checks or hands off the file.
        file = nil
        url = nil
        frameCount = 0
        storedError = nil
        surfacedError = false
        lock.unlock()
        return receipt
    }
}

/// Continuity-only recorder that opts SpeakPaste into the system Mic Modes by
/// recording through AVAudioEngine's Voice Processing I/O path. Standard and
/// Voice Isolation are still selected by the user; this class makes that
/// system-owned choice active for the audio delivered to SpeakPaste.
private final class MacVoiceProcessingAudioRecorder: @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "com.example.speakpaste.voice-processing")
    private let sampleFlow = MacVoiceProcessingSampleFlow()
    private let fileSink = MacVoiceProcessingFileSink()

    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var activeDeviceUID: String?
    private var selectedDeviceID: AudioObjectID?
    private var originalDefaultDeviceID: AudioObjectID?
    private var engineObserver: NSObjectProtocol?
    private var engineRestartWorkItem: DispatchWorkItem?
    private var engineRestartFailureCount = 0
    private var sessionGeneration: UInt64 = 0

    private var segmentURL: URL?
    private var segmentDidStart = false
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var pendingRecordingError: Error?
    private var recordingFailureHandler: (@Sendable (Error, URL?) -> Void)?
    private var stopping = false

    private let recordingStartTimeout: TimeInterval = 8
    private let steadyAudioTimeout: TimeInterval = 15
    private let engineRestartDelays: [TimeInterval] = [0.25, 0.5, 1]
    private static let requiredSteadyWindows = 6
    private static let recordingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    func setRecordingFailureHandler(_ handler: @escaping @Sendable (Error, URL?) -> Void) {
        captureQueue.async { [weak self] in self?.recordingFailureHandler = handler }
    }

    var normalizedLevel: Double { sampleFlow.normalizedLevel }
    var deliveredSampleCount: UInt64 { sampleFlow.count }

    func connect(deviceID: String) async throws -> Bool {
        try await ensurePermission()
        try Task.checkCancellation()
        let receipt = try await establishSession(deviceUID: deviceID)
        do {
            try await waitForSteadyAudio(
                timeout: steadyAudioTimeout,
                generation: receipt.generation
            )
        } catch {
            await releaseSession(with: error, generation: receipt.generation)
            throw error
        }
        return receipt.wasCreated
    }

    private struct ConnectionReceipt: Sendable {
        let wasCreated: Bool
        let generation: UInt64
    }

    private func establishSession(deviceUID: String) async throws -> ConnectionReceipt {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                do {
                    if
                        activeDeviceUID == deviceUID,
                        engine?.isRunning == true,
                        segmentURL == nil,
                        startContinuation == nil,
                        pendingRecordingError == nil
                    {
                        continuation.resume(
                            returning: ConnectionReceipt(
                                wasCreated: false,
                                generation: sessionGeneration
                            )
                        )
                        return
                    }
                    guard segmentURL == nil, startContinuation == nil else {
                        throw MacAudioRecorderError.recorderBusy
                    }

                    finishSession(removingSegment: true)
                    try configureAndConnect(deviceUID: deviceUID)
                    continuation.resume(
                        returning: ConnectionReceipt(
                            wasCreated: true,
                            generation: sessionGeneration
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func waitForSteadyAudio(
        timeout: TimeInterval,
        generation: UInt64
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var lastCount = sampleFlow.count
        var steadyWindows = 0
        while steadyWindows < Self.requiredSteadyWindows {
            try Task.checkCancellation()
            if let failure = captureQueue.sync(execute: {
                currentSessionFailure(generation: generation)
            }) {
                throw failure
            }
            guard clock.now < deadline else {
                throw MacAudioRecorderError.audioStreamNotReady
            }
            try await Task.sleep(for: .milliseconds(30))
            let count = sampleFlow.count
            steadyWindows = count > lastCount ? steadyWindows + 1 : 0
            lastCount = count
        }
        // Voice Isolation intentionally turns ordinary room tone into silence.
        // Buffer flow, rather than nonzero amplitude, is therefore the only
        // valid readiness signal for this backend.
    }

    private func currentSessionFailure(generation: UInt64) -> Error? {
        // Voice Processing I/O intentionally stops AVAudioEngine while macOS
        // finishes rebuilding its private input/output aggregate. Treating
        // that brief stopped state as a disconnect races the configuration
        // notification and tears the Continuity session down before it can be
        // restarted. The notification handler owns recovery; the ordinary
        // steady-audio timeout still bounds a route that never comes back.
        switch MacVoiceProcessingSessionHealth.evaluate(
            sessionMatches: sessionGeneration == generation,
            hasEngine: engine != nil,
            inputRouteMatches: MacCoreAudioInputRoute.defaultDeviceID() == selectedDeviceID,
            engineIsRunning: engine?.isRunning == true
        ) {
        case .active, .recoveringConfiguration:
            return nil
        case .connectionFailed:
            return MacAudioRecorderError.connectionFailed
        case .deviceUnavailable:
            return MacAudioRecorderError.deviceUnavailable
        }
    }

    private func releaseSession(with error: Error, generation: UInt64) async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                if let self, self.sessionGeneration == generation {
                    self.failSession(with: error, preservingPartialRecording: false)
                }
                continuation.resume()
            }
        }
    }

    func startSegment() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                guard engine?.isRunning == true, inputNode?.isVoiceProcessingEnabled == true else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                guard
                    segmentURL == nil,
                    startContinuation == nil,
                    pendingRecordingError == nil
                else {
                    continuation.resume(throwing: MacAudioRecorderError.recorderBusy)
                    return
                }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SpeakPaste-\(UUID().uuidString)")
                    .appendingPathExtension("wav")
                try? FileManager.default.removeItem(at: url)

                do {
                    try fileSink.start(url: url, format: Self.recordingFormat)
                    guard MacActiveCaptureRecovery.makeRecordingPrivate(at: url) else {
                        _ = fileSink.finish()
                        try? FileManager.default.removeItem(at: url)
                        throw MacAudioRecorderError.recordingFileProtectionFailed
                    }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                segmentURL = url
                segmentDidStart = false
                startContinuation = continuation
                stopping = false
                scheduleStartTimeout(url: url, generation: sessionGeneration)
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
                if let pendingRecordingError {
                    self.pendingRecordingError = nil
                    continuation.resume(throwing: pendingRecordingError)
                    return
                }
                guard
                    let url = segmentURL,
                    segmentDidStart,
                    startContinuation == nil,
                    !stopping
                else {
                    continuation.resume(throwing: MacAudioRecorderError.noActiveRecording)
                    return
                }

                stopping = true
                stopEngineAndRemoveTap()
                let finish = fileSink.finish()
                cancelStartTimeout()
                segmentURL = nil
                segmentDidStart = false
                stopping = false
                restoreInputRoute()
                clearEngineState()

                if let error = finish.error {
                    if isPlausiblePartialWAV(at: url), finish.frameCount > 0 {
                        continuation.resume(
                            throwing: MacAudioRecorderSalvagedFailure(
                                underlying: error,
                                audioURL: url
                            )
                        )
                    } else {
                        try? FileManager.default.removeItem(at: url)
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard finish.url == url, finish.frameCount > 0, isPlausiblePartialWAV(at: url) else {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                continuation.resume(returning: MacRecordedSegment(url: url))
            }
        }
    }

    func disconnect() {
        captureQueue.async { [weak self] in self?.finishSession(removingSegment: true) }
    }

    func disconnectAndWait() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.finishSession(removingSegment: true)
                continuation.resume()
            }
        }
    }

    func disconnectSynchronously() {
        captureQueue.sync { finishSession(removingSegment: true) }
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

    private func configureAndConnect(deviceUID: String) throws {
        guard let selectedDeviceID = MacCoreAudioInputRoute.deviceID(forUID: deviceUID) else {
            throw MacAudioRecorderError.deviceUnavailable
        }
        let originalDefaultDeviceID = MacCoreAudioInputRoute.defaultDeviceID()
        if originalDefaultDeviceID != selectedDeviceID {
            try MacCoreAudioInputRoute.selectDefaultDevice(selectedDeviceID)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            guard inputNode.isVoiceProcessingEnabled else {
                throw MacAudioRecorderError.connectionFailed
            }

            sessionGeneration &+= 1
            let generation = sessionGeneration
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: Self.recordingFormat
            ) { [weak self] buffer, _ in
                self?.handleAudioBuffer(buffer, generation: generation)
            }

            self.engine = engine
            self.inputNode = inputNode
            self.activeDeviceUID = deviceUID
            self.selectedDeviceID = selectedDeviceID
            self.originalDefaultDeviceID = originalDefaultDeviceID
            pendingRecordingError = nil

            engine.prepare()
            try engine.start()
            guard engine.isRunning else {
                throw MacAudioRecorderError.connectionFailed
            }

            // Register only after the initial start. Voice Processing I/O emits
            // setup-time configuration notifications while the engine is still
            // stopped; observing those would race a second start against this
            // one and make the first Continuity connection fail.
            engineObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self, weak engine] _ in
                guard let engine else { return }
                self?.captureQueue.async { [weak self, weak engine] in
                    guard let self, let engine else { return }
                    self.handleConfigurationChange(engine: engine, generation: generation)
                }
            }
        } catch {
            stopEngineAndRemoveTap(engine: engine, inputNode: inputNode)
            removeEngineObserver()
            MacCoreAudioInputRoute.restore(
                originalDeviceID: originalDefaultDeviceID,
                replacing: selectedDeviceID
            )
            clearEngineState()
            throw error
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        sampleFlow.record(buffer: buffer)
        let write = fileSink.consume(buffer)
        guard write.wroteFirstFrames || write.error != nil else { return }
        captureQueue.async { [weak self] in
            guard let self, sessionGeneration == generation else { return }
            if let error = write.error {
                handleWriteFailure(error)
                return
            }
            guard
                write.wroteFirstFrames,
                let continuation = startContinuation,
                let url = segmentURL
            else {
                return
            }
            cancelStartTimeout()
            startContinuation = nil
            segmentDidStart = true
            continuation.resume(returning: url)
        }
    }

    private func handleWriteFailure(_ error: Error) {
        guard segmentURL != nil, !stopping else { return }
        let wasRecording = segmentDidStart && startContinuation == nil
        let salvagedURL = failSession(
            with: error,
            preservingPartialRecording: wasRecording
        )
        if wasRecording {
            let surfaced: Error
            if let salvagedURL {
                surfaced = MacAudioRecorderSalvagedFailure(
                    underlying: error,
                    audioURL: salvagedURL
                )
            } else {
                surfaced = error
            }
            pendingRecordingError = surfaced
            recordingFailureHandler?(error, salvagedURL)
        }
    }

    private func handleConfigurationChange(engine: AVAudioEngine, generation: UInt64) {
        guard self.engine === engine, sessionGeneration == generation else { return }
        guard MacCoreAudioInputRoute.defaultDeviceID() == selectedDeviceID else {
            let wasRecording = segmentDidStart && startContinuation == nil
            let salvagedURL = failSession(
                with: MacAudioRecorderError.deviceUnavailable,
                preservingPartialRecording: wasRecording
            )
            if wasRecording {
                let surfaced: Error
                if let salvagedURL {
                    surfaced = MacAudioRecorderSalvagedFailure(
                        underlying: MacAudioRecorderError.deviceUnavailable,
                        audioURL: salvagedURL
                    )
                } else {
                    surfaced = MacAudioRecorderError.deviceUnavailable
                }
                pendingRecordingError = surfaced
                recordingFailureHandler?(MacAudioRecorderError.deviceUnavailable, salvagedURL)
            }
            return
        }
        if engine.isRunning {
            cancelEngineRestart()
            engineRestartFailureCount = 0
            return
        }

        // Initial Continuity setup and later Mic Mode changes can both rebuild
        // the I/O unit. AVAudioEngine posts the notification before that
        // rebuild has fully settled, so an immediate start races Core Audio
        // and fails. Keep the installed tap, wait briefly, then retry with a
        // small bounded backoff. The steady-audio timeout remains the outer
        // bound for a route that never resumes.
        scheduleEngineRestart(engine: engine, generation: generation)
    }

    private func scheduleEngineRestart(engine: AVAudioEngine, generation: UInt64) {
        guard engineRestartWorkItem == nil else { return }
        let delayIndex = min(engineRestartFailureCount, engineRestartDelays.count - 1)
        let workItem = DispatchWorkItem { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.engineRestartWorkItem = nil
            self.restartEngineAfterConfigurationChange(engine: engine, generation: generation)
        }
        engineRestartWorkItem = workItem
        captureQueue.asyncAfter(deadline: .now() + engineRestartDelays[delayIndex], execute: workItem)
    }

    private func restartEngineAfterConfigurationChange(
        engine: AVAudioEngine,
        generation: UInt64
    ) {
        guard self.engine === engine, sessionGeneration == generation else { return }
        guard MacCoreAudioInputRoute.defaultDeviceID() == selectedDeviceID else {
            failForChangedInputRoute()
            return
        }
        guard !engine.isRunning else {
            engineRestartFailureCount = 0
            return
        }

        do {
            try engine.start()
            engineRestartFailureCount = 0
        } catch {
            engineRestartFailureCount += 1
            if engineRestartFailureCount < engineRestartDelays.count {
                scheduleEngineRestart(engine: engine, generation: generation)
            }
        }
    }

    private func failForChangedInputRoute() {
        let error = MacAudioRecorderError.deviceUnavailable
        let wasRecording = segmentDidStart && startContinuation == nil
        let salvagedURL = failSession(
            with: error,
            preservingPartialRecording: wasRecording
        )
        if wasRecording {
            let surfaced: Error
            if let salvagedURL {
                surfaced = MacAudioRecorderSalvagedFailure(
                    underlying: error,
                    audioURL: salvagedURL
                )
            } else {
                surfaced = error
            }
            pendingRecordingError = surfaced
            recordingFailureHandler?(error, salvagedURL)
        }
    }

    private func scheduleStartTimeout(url: URL, generation: UInt64) {
        cancelStartTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                sessionGeneration == generation,
                segmentURL == url,
                startContinuation != nil
            else {
                return
            }
            failSession(
                with: MacAudioRecorderError.recordingStartTimedOut,
                preservingPartialRecording: false
            )
        }
        startTimeoutWorkItem = workItem
        captureQueue.asyncAfter(deadline: .now() + recordingStartTimeout, execute: workItem)
    }

    private func cancelStartTimeout() {
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
    }

    private func finishSession(removingSegment: Bool) {
        let staleURL = segmentURL
        let continuation = startContinuation
        stopEngineAndRemoveTap()
        _ = fileSink.finish()
        cancelStartTimeout()
        segmentURL = nil
        segmentDidStart = false
        startContinuation = nil
        pendingRecordingError = nil
        stopping = false
        restoreInputRoute()
        clearEngineState()
        if removingSegment, let staleURL {
            try? FileManager.default.removeItem(at: staleURL)
        }
        continuation?.resume(throwing: MacAudioRecorderError.connectionFailed)
    }

    @discardableResult
    private func failSession(
        with error: Error,
        preservingPartialRecording: Bool
    ) -> URL? {
        let staleURL = segmentURL
        let continuation = startContinuation
        stopEngineAndRemoveTap()
        let finish = fileSink.finish()
        cancelStartTimeout()
        segmentURL = nil
        segmentDidStart = false
        startContinuation = nil
        stopping = false
        restoreInputRoute()
        clearEngineState()

        let salvagedURL: URL?
        if
            preservingPartialRecording,
            finish.frameCount > 0,
            let staleURL,
            isPlausiblePartialWAV(at: staleURL)
        {
            salvagedURL = staleURL
        } else {
            salvagedURL = nil
            if let staleURL { try? FileManager.default.removeItem(at: staleURL) }
        }
        continuation?.resume(throwing: error)
        return salvagedURL
    }

    private func stopEngineAndRemoveTap() {
        stopEngineAndRemoveTap(engine: engine, inputNode: inputNode)
    }

    private func stopEngineAndRemoveTap(
        engine: AVAudioEngine?,
        inputNode: AVAudioInputNode?
    ) {
        engine?.stop()
        inputNode?.removeTap(onBus: 0)
    }

    private func removeEngineObserver() {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
    }

    private func cancelEngineRestart() {
        engineRestartWorkItem?.cancel()
        engineRestartWorkItem = nil
    }

    private func restoreInputRoute() {
        guard let selectedDeviceID else { return }
        MacCoreAudioInputRoute.restore(
            originalDeviceID: originalDefaultDeviceID,
            replacing: selectedDeviceID
        )
    }

    private func clearEngineState() {
        cancelEngineRestart()
        engineRestartFailureCount = 0
        removeEngineObserver()
        engine = nil
        inputNode = nil
        activeDeviceUID = nil
        selectedDeviceID = nil
        originalDefaultDeviceID = nil
    }

    private func isPlausiblePartialWAV(at url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard
            let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize > 44,
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else {
            return false
        }
        return Array(header.prefix(4)) == Array("RIFF".utf8)
            && Array(header.dropFirst(8).prefix(4)) == Array("WAVE".utf8)
    }
}

// MARK: - Recorder facade

/// Keeps the mature AVCaptureSession path for ordinary microphones while
/// routing Continuity devices through Voice Processing I/O so macOS Mic Modes
/// affect the audio before it reaches SpeakPaste.
final class MacAudioRecorder: @unchecked Sendable {
    private enum Backend {
        case captureSession
        case voiceProcessing
    }

    private let backendLock = NSLock()
    private var activeBackend: Backend?
    private let captureRecorder = MacCaptureSessionAudioRecorder()
    private let voiceRecorder = MacVoiceProcessingAudioRecorder()

    func setRecordingFailureHandler(_ handler: @escaping @Sendable (Error, URL?) -> Void) {
        captureRecorder.setRecordingFailureHandler(handler)
        voiceRecorder.setRecordingFailureHandler(handler)
    }

    var normalizedLevel: Double {
        switch currentBackend() {
        case .captureSession:
            captureRecorder.normalizedLevel
        case .voiceProcessing:
            voiceRecorder.normalizedLevel
        case nil:
            0
        }
    }

    var deliveredSampleCount: UInt64 {
        switch currentBackend() {
        case .captureSession:
            captureRecorder.deliveredSampleCount
        case .voiceProcessing:
            voiceRecorder.deliveredSampleCount
        case nil:
            0
        }
    }

    func connect(deviceID: String) async throws -> Bool {
        let backend: Backend = MacAudioDeviceCatalog.availableInputs()
            .first(where: { $0.id == deviceID })?
            .isContinuityDevice == true
            ? .voiceProcessing
            : .captureSession

        await disconnectBackendOtherThan(backend)
        setCurrentBackend(backend)
        do {
            switch backend {
            case .captureSession:
                return try await captureRecorder.connect(deviceID: deviceID)
            case .voiceProcessing:
                return try await voiceRecorder.connect(deviceID: deviceID)
            }
        } catch {
            clearCurrentBackend(if: backend)
            throw error
        }
    }

    func startSegment() async throws -> URL {
        switch currentBackend() {
        case .captureSession:
            try await captureRecorder.startSegment()
        case .voiceProcessing:
            try await voiceRecorder.startSegment()
        case nil:
            throw MacAudioRecorderError.connectionFailed
        }
    }

    func stop() async throws -> MacRecordedSegment {
        guard let backend = currentBackend() else {
            throw MacAudioRecorderError.noActiveRecording
        }
        defer { clearCurrentBackend(if: backend) }
        switch backend {
        case .captureSession:
            return try await captureRecorder.stop()
        case .voiceProcessing:
            return try await voiceRecorder.stop()
        }
    }

    func disconnect() {
        setCurrentBackend(nil)
        captureRecorder.disconnect()
        voiceRecorder.disconnect()
    }

    func disconnectAndWait() async {
        setCurrentBackend(nil)
        async let capture: Void = captureRecorder.disconnectAndWait()
        async let voice: Void = voiceRecorder.disconnectAndWait()
        _ = await (capture, voice)
    }

    func disconnectSynchronously() {
        setCurrentBackend(nil)
        captureRecorder.disconnectSynchronously()
        voiceRecorder.disconnectSynchronously()
    }

    private func disconnectBackendOtherThan(_ backend: Backend) async {
        guard let current = currentBackend(), current != backend else { return }
        setCurrentBackend(nil)
        switch current {
        case .captureSession:
            await captureRecorder.disconnectAndWait()
        case .voiceProcessing:
            await voiceRecorder.disconnectAndWait()
        }
    }

    private func currentBackend() -> Backend? {
        backendLock.lock()
        defer { backendLock.unlock() }
        return activeBackend
    }

    private func setCurrentBackend(_ backend: Backend?) {
        backendLock.lock()
        activeBackend = backend
        backendLock.unlock()
    }

    private func clearCurrentBackend(if backend: Backend) {
        backendLock.lock()
        if activeBackend == backend { activeBackend = nil }
        backendLock.unlock()
    }
}
