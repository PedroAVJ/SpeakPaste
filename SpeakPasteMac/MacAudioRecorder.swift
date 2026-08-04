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

final class MacAudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "com.example.speakpaste.capture")
    private let sampleQueue = DispatchQueue(label: "com.example.speakpaste.samples")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var activeDeviceID: String?
    /// Whether the liveness tap for this capture generation is also configured
    /// as Scribe's 16 kHz PCM producer. Default batch sessions keep the tap in
    /// the device-native format and do not alter the established capture graph.
    private var preparesRealtimePCM = false
    private var sessionGeneration: UInt64 = 0
    private var runtimeErrorObserver: NSObjectProtocol?
    private var runtimeErrorLatch: MacRuntimeErrorLatch?
    private var runtimeError: NSError?
    private var recordingFailureHandler: (@Sendable (Error, URL?) -> Void)?
    private let sampleFlow = MacSampleFlowCounter()
    /// Realtime Scribe consumes 200 ms frames of raw mono PCM16 at 16 kHz.
    /// These members are confined to `sampleQueue`; the ordinary WAV output
    /// remains native and independently recoverable for batch fallback.
    private var realtimeSampleHandler: (@Sendable (Data) -> Void)?
    private var realtimeSampleAccumulator = Data()
    private let realtimePCMConverter = MacRealtimePCMConverter()
    private static let realtimeChunkByteCount = 6_400
    private static let realtimeMinimumChunkByteCount = 3_200

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
    func connect(
        deviceID: String,
        preparesRealtimePCM: Bool = false
    ) async throws -> Bool {
        try await ensurePermission()
        // Escape may cancel while the first-run permission sheet is open.
        // Never create a capture session after that canceled sheet resolves.
        try Task.checkCancellation()
        let connection = try await establishSession(
            deviceID: deviceID,
            preparesRealtimePCM: preparesRealtimePCM
        )
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

    private func establishSession(
        deviceID: String,
        preparesRealtimePCM: Bool
    ) async throws -> ConnectionReceipt {
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
                        self.preparesRealtimePCM == preparesRealtimePCM,
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
                    try self.configureAndConnect(
                        deviceID: deviceID,
                        preparesRealtimePCM: preparesRealtimePCM
                    )
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
        guard realtimeSampleHandler != nil else { return }
        guard let data = realtimePCMConverter.convert(sampleBuffer) else { return }
        appendRealtimeSamples(data)
    }

    /// Starts forwarding only future sample-tap buffers. The liveness samples
    /// consumed while Continuity warms up are deliberately excluded.
    func beginRealtimeAudioStreaming(
        _ handler: @escaping @Sendable (Data) -> Void
    ) {
        sampleQueue.sync {
            realtimePCMConverter.reset()
            realtimeSampleAccumulator.removeAll(keepingCapacity: true)
            realtimeSampleHandler = handler
        }
    }

    /// Drains the sample queue and emits the final tail, padding only with PCM
    /// silence when needed to meet the service's 100 ms minimum chunk. Call this
    /// only after `stop()` has returned and capture is released.
    func finishRealtimeAudioStreaming() {
        sampleQueue.sync {
            let convertedTail = realtimePCMConverter.finish()
            if !convertedTail.isEmpty {
                appendRealtimeSamples(convertedTail)
            }
            if !realtimeSampleAccumulator.isEmpty {
                var finalFrame = realtimeSampleAccumulator
                if finalFrame.count < Self.realtimeMinimumChunkByteCount {
                    finalFrame.append(
                        Data(
                            repeating: 0,
                            count: Self.realtimeMinimumChunkByteCount - finalFrame.count
                        )
                    )
                }
                realtimeSampleHandler?(finalFrame)
            }
            realtimeSampleAccumulator.removeAll(keepingCapacity: false)
            realtimeSampleHandler = nil
        }
    }

    func cancelRealtimeAudioStreaming() {
        sampleQueue.sync {
            realtimePCMConverter.reset()
            realtimeSampleAccumulator.removeAll(keepingCapacity: false)
            realtimeSampleHandler = nil
        }
    }

    private nonisolated func appendRealtimeSamples(_ data: Data) {
        guard realtimeSampleHandler != nil else { return }
        realtimeSampleAccumulator.append(data)
        while realtimeSampleAccumulator.count >= Self.realtimeChunkByteCount {
            let frame = Data(
                realtimeSampleAccumulator.prefix(Self.realtimeChunkByteCount)
            )
            realtimeSampleAccumulator.removeFirst(Self.realtimeChunkByteCount)
            realtimeSampleHandler?(frame)
        }
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

    private func configureAndConnect(
        deviceID: String,
        preparesRealtimePCM: Bool
    ) throws {
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

        // A lightweight tap that counts delivered device-native buffers. When
        // realtime is armed, MacRealtimePCMConverter explicitly produces
        // Scribe's 16 kHz mono PCM; asking AVCapture to do that conversion here
        // fails on some Mac and Continuity inputs and silently yields no stream.
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
        self.preparesRealtimePCM = preparesRealtimePCM
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
        preparesRealtimePCM = false
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
        preparesRealtimePCM = false
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
