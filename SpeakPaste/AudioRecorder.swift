import AVFoundation
import Combine
import Darwin
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case alreadyRecording
    case cancelled
    case couldNotStart
    case configurationFailed(stage: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Enable it for SpeakPaste in Settings."
        case .alreadyRecording:
            "A recording is already in progress."
        case .cancelled:
            "Recording startup was cancelled."
        case .couldNotStart:
            "The microphone could not start. Check whether another app is using it."
        case let .configurationFailed(stage, underlying):
            "Microphone \(stage) failed: \(underlying.localizedDescription)"
        }
    }
}

enum AudioRecorderReadiness: Equatable, Sendable {
    case idle
    case activating
    case awaitingSamples
    case ready
}

enum AudioRecorderRouteChangeReason: Equatable, Sendable {
    case unknown
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRoute
    case routeConfigurationChange
}

struct AudioRecorderRouteChange: Equatable, Sendable {
    let reason: AudioRecorderRouteChangeReason
    let hasUsableInput: Bool
    /// Set only when the route disappeared and SpeakPaste finalized the
    /// partial recording instead of continuing with no usable microphone.
    let finalizedRecordingURL: URL?
}

enum AudioRecorderEvent: Equatable, Sendable {
    /// Interruption starts finalize the current file. Resuming into the same
    /// file is unsafe because `AVAudioRecorder` may already have closed it.
    case interruptionBegan(finalizedRecordingURL: URL?)
    case interruptionEnded(systemSuggestedResume: Bool)
    case routeChanged(AudioRecorderRouteChange)
    case noAudioDetected(elapsed: TimeInterval)
    case maximumDurationApproaching(remaining: TimeInterval)
    /// The recorder has already been stopped and the returned file is ready to
    /// journal before this event is delivered.
    case maximumDurationReached(finalizedRecordingURL: URL?)
    case recordingEndedUnexpectedly(finalizedRecordingURL: URL?)
}

struct AudioRecordingSafetyPolicy: Equatable, Sendable {
    static let standard = AudioRecordingSafetyPolicy()

    let maximumDuration: TimeInterval
    let maximumDurationWarningLeadTime: TimeInterval
    let noAudioWarningDelay: TimeInterval
    let audiblePeakThresholdDecibels: Float

    init(
        maximumDuration: TimeInterval = 5 * 60,
        maximumDurationWarningLeadTime: TimeInterval = 30,
        noAudioWarningDelay: TimeInterval = 8,
        audiblePeakThresholdDecibels: Float = -60
    ) {
        self.maximumDuration = max(1, maximumDuration)
        self.maximumDurationWarningLeadTime = min(
            max(0, maximumDurationWarningLeadTime),
            self.maximumDuration
        )
        self.noAudioWarningDelay = max(0, noAudioWarningDelay)
        self.audiblePeakThresholdDecibels = min(0, audiblePeakThresholdDecibels)
    }
}

enum AudioRecordingSafetySignal: Equatable, Sendable {
    case noAudio(elapsed: TimeInterval)
    case maximumDurationWarning(remaining: TimeInterval)
    case maximumDurationReached
}

/// Pure policy state kept separate from AVFoundation so the timing and
/// exactly-once guarantees can be exercised without mocking a microphone.
struct AudioRecordingSafetyTracker: Sendable {
    let policy: AudioRecordingSafetyPolicy

    private(set) var loudestPeakDecibels: Float = -160
    private var didWarnAboutNoAudio = false
    private var didWarnAboutMaximumDuration = false
    private var didReachMaximumDuration = false

    init(policy: AudioRecordingSafetyPolicy = .standard) {
        self.policy = policy
    }

    mutating func observe(
        elapsed: TimeInterval,
        peakPowerDecibels: Float
    ) -> [AudioRecordingSafetySignal] {
        let elapsed = max(0, elapsed)
        if peakPowerDecibels.isFinite {
            loudestPeakDecibels = max(loudestPeakDecibels, peakPowerDecibels)
        }

        var signals: [AudioRecordingSafetySignal] = []
        if !didWarnAboutNoAudio,
           elapsed >= policy.noAudioWarningDelay,
           loudestPeakDecibels < policy.audiblePeakThresholdDecibels {
            didWarnAboutNoAudio = true
            signals.append(.noAudio(elapsed: elapsed))
        }

        let warningTime = policy.maximumDuration
            - policy.maximumDurationWarningLeadTime
        if !didWarnAboutMaximumDuration,
           elapsed >= warningTime,
           elapsed < policy.maximumDuration {
            didWarnAboutMaximumDuration = true
            signals.append(
                .maximumDurationWarning(
                    remaining: max(0, policy.maximumDuration - elapsed)
                )
            )
        }

        if !didReachMaximumDuration,
           elapsed >= policy.maximumDuration {
            didReachMaximumDuration = true
            signals.append(.maximumDurationReached)
        }
        return signals
    }
}

@MainActor
final class AudioRecorder: ObservableObject {
    private final class NotificationToken: @unchecked Sendable {
        let value: NSObjectProtocol

        init(_ value: NSObjectProtocol) {
            self.value = value
        }
    }

    private struct JournalCaptureContext: @unchecked Sendable {
        let journal: RecordingJournal
        let capture: RecordingJournalCapture
    }

    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var readiness: AudioRecorderReadiness = .idle

    let events = PassthroughSubject<AudioRecorderEvent, Never>()

    var isReady: Bool { readiness == .ready }
    var maximumDuration: TimeInterval { safetyPolicy.maximumDuration }

    private let session: AVAudioSession
    private let notificationCenter: NotificationCenter
    private let safetyPolicy: AudioRecordingSafetyPolicy
    private var safetyTracker: AudioRecordingSafetyTracker
    private var recorder: AVAudioRecorder?
    private var journalCaptureContext: JournalCaptureContext?
    private var meterTask: Task<Void, Never>?
    private var notificationTokens: [NotificationToken] = []
    private var recordingStartUptime: TimeInterval?
    private var startAttemptID: UUID?
    private var interruptionInProgress = false

    init(
        session: AVAudioSession = .sharedInstance(),
        notificationCenter: NotificationCenter = .default,
        safetyPolicy: AudioRecordingSafetyPolicy = .standard
    ) {
        self.session = session
        self.notificationCenter = notificationCenter
        self.safetyPolicy = safetyPolicy
        safetyTracker = AudioRecordingSafetyTracker(policy: safetyPolicy)
        installAudioSessionObservers()
    }

    deinit {
        meterTask?.cancel()
        let activeRecorder = recorder
        activeRecorder?.stop()
        if let url = activeRecorder?.url,
           let journalCaptureContext {
            try? journalCaptureContext.journal.recordWriterRelease(
                journalCaptureContext.capture,
                finalizedURL: url
            )
        }
        for token in notificationTokens {
            notificationCenter.removeObserver(token.value)
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() async throws -> URL {
        try await start(recordingAt: nil, journalContext: nil)
    }

    /// Records directly into a destination reserved by `RecordingJournal`.
    /// Unlike the legacy temporary-file overload, startup failures never
    /// remove this URL: the journal remains the recovery authority until its
    /// capture is finalized or explicitly abandoned.
    func start(recordingAt durableURL: URL) async throws -> URL {
        try await start(
            recordingAt: Optional(durableURL),
            journalContext: nil
        )
    }

    /// Safe journal-owned capture path. The recorder itself releases the
    /// journal writer only after AVAudioRecorder has stopped, including
    /// interruption, route-loss, hard-limit, and failed-start teardown paths.
    func start(
        capture: RecordingJournalCapture,
        in journal: RecordingJournal
    ) async throws -> URL {
        let url = try journal.audioURL(for: capture)
        return try await start(
            recordingAt: Optional(url),
            journalContext: JournalCaptureContext(
                journal: journal,
                capture: capture
            )
        )
    }

    private func start(
        recordingAt durableURL: URL?,
        journalContext: JournalCaptureContext?
    ) async throws -> URL {
        guard recorder == nil, readiness == .idle else {
            throw AudioRecorderError.alreadyRecording
        }
        guard !interruptionInProgress else { throw AudioRecorderError.couldNotStart }

        let url: URL
        let removesOutputAfterFailedStart: Bool
        if let durableURL {
            do {
                try RecordingJournalPrivateIO.validateVacantRecordingDestination(
                    at: durableURL
                )
            } catch {
                throw AudioRecorderError.configurationFailed(
                    stage: "recording storage",
                    underlying: error
                )
            }
            url = durableURL
            removesOutputAfterFailedStart = false
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpeakPaste", isDirectory: true)
            do {
                try RecordingJournalPrivateIO.ensurePrivateDirectory(at: directory)
            } catch {
                throw AudioRecorderError.configurationFailed(
                    stage: "recording storage",
                    underlying: error
                )
            }
            url = directory.appendingPathComponent(
                "dictation-\(UUID().uuidString).m4a"
            )
            removesOutputAfterFailedStart = true
        }

        let attemptID = UUID()
        startAttemptID = attemptID
        readiness = .activating
        duration = 0
        level = 0
        safetyTracker = AudioRecordingSafetyTracker(policy: safetyPolicy)

        do {
            // The user-invoked Live Activity authorizes background capture.
            // Keep the session mixable: a non-mixable `.record` session is
            // refused in the background when another app owns audio, while
            // ducking leaves that audio alive and avoids a second-tap failure.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.duckOthers, .allowBluetoothHFP]
            )
        } catch {
            resetFailedStart(attemptID: attemptID)
            throw AudioRecorderError.configurationFailed(
                stage: "configuration",
                underlying: error
            )
        }
        do {
            try await activate(session, attemptID: attemptID)
        } catch let error as AudioRecorderError {
            resetFailedStart(attemptID: attemptID)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        } catch {
            resetFailedStart(attemptID: attemptID)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioRecorderError.configurationFailed(
                stage: "activation",
                underlying: error
            )
        }
        guard startAttemptID == attemptID, readiness == .activating else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioRecorderError.cancelled
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 96_000,
        ]

        let newRecorder: AVAudioRecorder
        do {
            newRecorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            releaseJournalWriter(journalContext, finalizedURL: url)
            resetFailedStart(attemptID: attemptID)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if removesOutputAfterFailedStart {
                _ = try? RecordingJournalPrivateIO.removeRegularFile(at: url)
            }
            throw AudioRecorderError.configurationFailed(
                stage: "recorder creation",
                underlying: error
            )
        }
        newRecorder.isMeteringEnabled = true
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
        guard newRecorder.prepareToRecord(), newRecorder.record() else {
            newRecorder.stop()
            releaseJournalWriter(journalContext, finalizedURL: url)
            resetFailedStart(attemptID: attemptID)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if removesOutputAfterFailedStart {
                _ = try? RecordingJournalPrivateIO.removeRegularFile(at: url)
            }
            throw AudioRecorderError.couldNotStart
        }
        guard startAttemptID == attemptID, readiness == .activating else {
            newRecorder.stop()
            releaseJournalWriter(journalContext, finalizedURL: url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if removesOutputAfterFailedStart {
                _ = try? RecordingJournalPrivateIO.removeRegularFile(at: url)
            }
            throw AudioRecorderError.cancelled
        }

        recorder = newRecorder
        journalCaptureContext = journalContext
        startAttemptID = nil
        recordingStartUptime = ProcessInfo.processInfo.systemUptime
        readiness = .awaitingSamples
        isRecording = true
        startMetering()
        return url
    }

    /// On a cold background launch, the recording grant tied to the Live
    /// Activity the intent just started propagates asynchronously, so an
    /// immediate `setActive` can lose the race. Retry inside one user gesture.
    private func activate(
        _ session: AVAudioSession,
        attemptID: UUID
    ) async throws {
        let delays: [Duration] = [
            .milliseconds(250), .milliseconds(500), .milliseconds(750),
            .seconds(1), .milliseconds(1500),
        ]
        var attempt = 0
        while true {
            guard startAttemptID == attemptID, readiness == .activating else {
                throw AudioRecorderError.cancelled
            }
            do {
                try session.setActive(true)
                return
            } catch {
                guard attempt < delays.count else { throw error }
                try? await Task.sleep(for: delays[attempt])
                attempt += 1
            }
        }
    }

    @discardableResult
    func stop(deactivatesSession: Bool = true) -> URL? {
        if recorder == nil {
            startAttemptID = nil
            readiness = .idle
            if deactivatesSession {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            return nil
        }
        return finishRecording(deactivatesSession: deactivatesSession)
    }

    private func finishRecording(
        deactivatesSession: Bool,
        callsRecorderStop: Bool = true
    ) -> URL? {
        meterTask?.cancel()
        meterTask = nil
        let activeRecorder = recorder
        let url = activeRecorder?.url
        let journalContext = journalCaptureContext
        recorder = nil
        journalCaptureContext = nil
        if callsRecorderStop {
            activeRecorder?.stop()
        }
        if let url {
            releaseJournalWriter(journalContext, finalizedURL: url)
        }
        startAttemptID = nil
        recordingStartUptime = nil
        isRecording = false
        readiness = .idle
        level = 0
        if deactivatesSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        return url
    }

    private func releaseJournalWriter(
        _ context: JournalCaptureContext?,
        finalizedURL: URL
    ) {
        guard let context else { return }
        try? context.journal.recordWriterRelease(
            context.capture,
            finalizedURL: finalizedURL
        )
    }

    private func resetFailedStart(attemptID: UUID) {
        guard startAttemptID == attemptID else { return }
        startAttemptID = nil
        readiness = .idle
        isRecording = false
        recordingStartUptime = nil
        level = 0
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { return }
                self.pollRecorder()
            }
        }
    }

    private func pollRecorder() {
        guard let recorder else { return }
        guard recorder.isRecording else {
            let url = finishRecording(
                deactivatesSession: true,
                callsRecorderStop: false
            )
            events.send(.recordingEndedUnexpectedly(finalizedRecordingURL: url))
            return
        }

        recorder.updateMeters()
        let recorderTime = max(0, recorder.currentTime)
        let wallTime = recordingStartUptime.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        } ?? recorderTime
        let elapsed = max(recorderTime, wallTime)
        duration = elapsed
        if readiness == .awaitingSamples, recorderTime > 0 {
            readiness = .ready
        }

        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)
        level = normalizedLevel(fromDecibels: averagePower)

        for signal in safetyTracker.observe(
            elapsed: elapsed,
            peakPowerDecibels: peakPower
        ) {
            switch signal {
            case let .noAudio(elapsed):
                events.send(.noAudioDetected(elapsed: elapsed))
            case let .maximumDurationWarning(remaining):
                events.send(.maximumDurationApproaching(remaining: remaining))
            case .maximumDurationReached:
                let url = finishRecording(deactivatesSession: true)
                events.send(.maximumDurationReached(finalizedRecordingURL: url))
                return
            }
        }
    }

    private func normalizedLevel(fromDecibels decibels: Float) -> Float {
        guard decibels.isFinite, decibels > -80 else { return 0 }
        return max(0, min(1, pow(10, decibels / 40)))
    }

    private func installAudioSessionObservers() {
        let interruptionToken = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: typeValue, optionValue: optionValue)
            }
        }
        notificationTokens.append(NotificationToken(interruptionToken))

        let routeToken = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }
        notificationTokens.append(NotificationToken(routeToken))
    }

    private func handleInterruption(typeValue: UInt?, optionValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        switch type {
        case .began:
            guard readiness != .idle else { return }
            interruptionInProgress = true
            let url = stop(deactivatesSession: false)
            events.send(.interruptionBegan(finalizedRecordingURL: url))
        case .ended:
            guard interruptionInProgress else { return }
            interruptionInProgress = false
            let options = AVAudioSession.InterruptionOptions(rawValue: optionValue ?? 0)
            events.send(
                .interruptionEnded(systemSuggestedResume: options.contains(.shouldResume))
            )
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard isRecording else { return }
        let reason = AudioRecorderRouteChangeReason(
            avReason: reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        )
        let hasUsableInput = !session.currentRoute.inputs.isEmpty
            || !(session.availableInputs?.isEmpty ?? true)
        let mustFinalize = !hasUsableInput
            && (reason == .oldDeviceUnavailable || reason == .noSuitableRoute)
        let url = mustFinalize ? stop(deactivatesSession: false) : nil
        events.send(
            .routeChanged(
                AudioRecorderRouteChange(
                    reason: reason,
                    hasUsableInput: hasUsableInput,
                    finalizedRecordingURL: url
                )
            )
        )
    }
}

private extension AudioRecorderRouteChangeReason {
    init(avReason: AVAudioSession.RouteChangeReason?) {
        switch avReason {
        case .newDeviceAvailable: self = .newDeviceAvailable
        case .oldDeviceUnavailable: self = .oldDeviceUnavailable
        case .categoryChange: self = .categoryChange
        case .override: self = .override
        case .wakeFromSleep: self = .wakeFromSleep
        case .noSuitableRouteForCategory: self = .noSuitableRoute
        case .routeConfigurationChange: self = .routeConfigurationChange
        case .unknown, .none: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

struct RecordingJournalEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let byteCount: Int64
    let audioFileExtension: String
}

/// Durable identity for an active capture. It intentionally stores no path;
/// every filesystem URL is re-derived and revalidated by `RecordingJournal`.
struct RecordingJournalCapture: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let audioFileExtension: String
    /// Launch recovery must never adopt a file still being written by another
    /// app process. A stale PID is conservative: PID reuse delays recovery but
    /// cannot destroy or move live audio.
    let ownerProcessIdentifier: Int32
}

enum RecordingJournalError: LocalizedError, Equatable {
    case sourceMissing
    case emptyRecording
    case duplicateIdentifier
    case recordMissing
    case captureMissing
    case captureContainsAudio
    case captureWriterActive
    case unsafeStorage
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "The recorded audio file is no longer available."
        case .emptyRecording:
            "The recorded audio file is empty."
        case .duplicateIdentifier:
            "A recovery recording already uses that identifier."
        case .recordMissing:
            "The recording is no longer in the recovery journal."
        case .captureMissing:
            "The active recording is no longer in the recovery journal."
        case .captureContainsAudio:
            "The active recording contains audio and must be finalized or recovered, not abandoned."
        case .captureWriterActive:
            "The active recording is still owned by a recorder and cannot be recovered yet."
        case .unsafeStorage:
            "The recording journal contains an unsafe file or symbolic link."
        case .corruptRecord:
            "The recovery recording is incomplete or corrupt."
        }
    }
}

/// A crash-safe journal for finalized iPhone recordings.
///
/// Each entry is assembled and synced inside `Staging`, then its entire bundle
/// is renamed into `Entries` in one exclusive filesystem operation. Consume
/// and discard do the inverse: the bundle first moves atomically out of the
/// recoverable namespace, then best-effort cleanup runs. No index points at an
/// arbitrary path, and all owned path components reject symbolic links.
final class RecordingJournal {
    private struct Manifest: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let entry: RecordingJournalEntry
        let audioFileName: String
    }

    private struct ActiveManifest: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let capture: RecordingJournalCapture
        let audioFileName: String
    }

    private struct WriterReleaseManifest: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let capture: RecordingJournalCapture
        let finalizedAudioFileName: String
    }

    private final class ReleasedCaptureRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var identifiers = Set<UUID>()

        func insert(_ identifier: UUID) {
            lock.lock()
            identifiers.insert(identifier)
            lock.unlock()
        }

        func contains(_ identifier: UUID) -> Bool {
            lock.lock()
            let result = identifiers.contains(identifier)
            lock.unlock()
            return result
        }
    }

    private static let releasedCaptureRegistry = ReleasedCaptureRegistry()

    enum Retirement: String {
        case consumed
        case discarded
    }

    let rootDirectory: URL
    let entriesDirectory: URL
    let activeDirectory: URL
    let stagingDirectory: URL
    let retiredDirectory: URL

    private let fileManager: FileManager
    private let bootstrapDirectories: [URL]

    convenience init(fileManager: FileManager = .default) {
        if let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        {
            self.init(
                rootDirectory: applicationSupport
                    .appendingPathComponent("SpeakPaste", isDirectory: true)
                    .appendingPathComponent(
                        "RecordingJournal",
                        isDirectory: true
                    ),
                bootstrapDirectories: [applicationSupport],
                fileManager: fileManager
            )
        } else {
            // The temporary directory itself is an existing system-owned
            // anchor. Do not chmod it; only create SpeakPaste beneath it.
            self.init(
                rootDirectory: fileManager.temporaryDirectory
                    .appendingPathComponent("SpeakPaste", isDirectory: true)
                    .appendingPathComponent(
                        "RecordingJournal",
                        isDirectory: true
                    ),
                fileManager: fileManager
            )
        }
    }

    init(
        rootDirectory: URL,
        bootstrapDirectories: [URL] = [],
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.bootstrapDirectories = bootstrapDirectories.map(
            \.standardizedFileURL
        )
        entriesDirectory = self.rootDirectory.appendingPathComponent("Entries", isDirectory: true)
        activeDirectory = self.rootDirectory.appendingPathComponent("Active", isDirectory: true)
        stagingDirectory = self.rootDirectory.appendingPathComponent("Staging", isDirectory: true)
        retiredDirectory = self.rootDirectory.appendingPathComponent("Retired", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Reserves and durably commits a private Application Support bundle before
    /// AVFoundation is allowed to open the recording file. A force-quit can
    /// therefore leave an active capture, never an unowned temporary file.
    func beginCapture(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        audioFileExtension: String = "m4a",
        ownerProcessIdentifier: Int32 = getpid()
    ) throws -> RecordingJournalCapture {
        try prepareStorage()
        let capture = RecordingJournalCapture(
            id: id,
            createdAt: createdAt,
            audioFileExtension: safeAudioExtension(audioFileExtension),
            ownerProcessIdentifier: ownerProcessIdentifier
        )
        let destinationURL = activeCaptureDirectory(for: id)
        guard !RecordingJournalPrivateIO.entryExists(at: destinationURL),
              !RecordingJournalPrivateIO.entryExists(at: entryDirectory(for: id)) else {
            throw RecordingJournalError.duplicateIdentifier
        }

        let stageName = "\(id.uuidString.lowercased()).active-staging-\(UUID().uuidString.lowercased())"
        let stageURL = stagingDirectory.appendingPathComponent(stageName, isDirectory: true)
        try RecordingJournalPrivateIO.createPrivateDirectoryExclusively(at: stageURL)
        var didCommit = false
        defer {
            if !didCommit {
                try? RecordingJournalPrivateIO.removeOwnedBundle(at: stageURL)
            }
        }

        let activeManifest = ActiveManifest(
            version: ActiveManifest.currentVersion,
            capture: capture,
            audioFileName: "audio.\(capture.audioFileExtension)"
        )
        try RecordingJournalPrivateIO.writeFileExclusively(
            try encoded(activeManifest),
            to: stageURL.appendingPathComponent("active-manifest.json")
        )
        try RecordingJournalPrivateIO.syncDirectory(at: stageURL)
        do {
            try RecordingJournalPrivateIO.renameExclusively(
                from: stageURL,
                to: destinationURL
            )
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
            throw RecordingJournalError.duplicateIdentifier
        }
        didCommit = true
        return capture
    }

    /// Returns the only URL AVAudioRecorder may use for this capture. Before
    /// recording it must be absent; afterward it may be a regular single-link
    /// file. Symbolic links and replacement directories fail closed.
    func audioURL(for capture: RecordingJournalCapture) throws -> URL {
        try prepareStorage()
        let bundleURL = activeCaptureDirectory(for: capture.id)
        guard RecordingJournalPrivateIO.entryExists(at: bundleURL) else {
            throw RecordingJournalError.captureMissing
        }
        let manifest = try loadActiveManifest(
            at: bundleURL,
            expectedID: capture.id
        )
        guard manifest.capture == capture else {
            throw RecordingJournalError.corruptRecord
        }
        let url = bundleURL.appendingPathComponent(manifest.audioFileName)
        try RecordingJournalPrivateIO.validateAbsentOrRegularFile(at: url)
        return url
    }

    /// Called only by `AudioRecorder` after it has synchronously stopped its
    /// exact journal destination. The in-process registry closes a same-process
    /// write-failure gap; the manifest carries that proof across journal
    /// instances and UI/intent coordination in the surviving process.
    fileprivate func recordWriterRelease(
        _ capture: RecordingJournalCapture,
        finalizedURL: URL
    ) throws {
        let bundleURL = activeCaptureDirectory(for: capture.id)
        if !RecordingJournalPrivateIO.entryExists(at: bundleURL) {
            if RecordingJournalPrivateIO.entryExists(
                at: entryDirectory(for: capture.id)
            ) {
                return
            }
            throw RecordingJournalError.captureMissing
        }
        let activeManifest = try loadActiveManifest(
            at: bundleURL,
            expectedID: capture.id
        )
        guard activeManifest.capture == capture else {
            throw RecordingJournalError.corruptRecord
        }
        let expectedURL = bundleURL.appendingPathComponent(
            activeManifest.audioFileName
        )
        guard expectedURL.standardizedFileURL
            == finalizedURL.standardizedFileURL else {
            throw RecordingJournalError.corruptRecord
        }

        Self.releasedCaptureRegistry.insert(capture.id)
        let releaseURL = bundleURL.appendingPathComponent(
            "writer-release.json"
        )
        if try RecordingJournalPrivateIO.regularFileExists(at: releaseURL) {
            let existing = try loadWriterReleaseManifest(
                at: bundleURL,
                expectedCapture: capture
            )
            guard existing.finalizedAudioFileName
                == activeManifest.audioFileName else {
                throw RecordingJournalError.corruptRecord
            }
            return
        }
        let release = WriterReleaseManifest(
            version: WriterReleaseManifest.currentVersion,
            capture: capture,
            finalizedAudioFileName: activeManifest.audioFileName
        )
        try RecordingJournalPrivateIO.writeFileExclusively(
            try encoded(release),
            to: releaseURL
        )
        try RecordingJournalPrivateIO.syncDirectory(at: bundleURL)
    }

    /// Converts a stopped active capture into an ordinary recoverable entry.
    /// The audio is synced first, the final manifest is synced second, and the
    /// whole bundle moves into `Entries` last. If any pre-rename step fails,
    /// the active bundle and its audio remain available for launch recovery.
    @discardableResult
    func finalizeCapture(
        _ capture: RecordingJournalCapture,
        duration: TimeInterval
    ) throws -> RecordingJournalEntry {
        let activeURL = activeCaptureDirectory(for: capture.id)
        let destinationURL = entryDirectory(for: capture.id)

        if !RecordingJournalPrivateIO.entryExists(at: activeURL) {
            try prepareStorage()
            if let loaded = try? loadBundle(at: destinationURL, expectedID: capture.id),
               loaded.manifest.entry.createdAt == capture.createdAt,
               loaded.manifest.entry.audioFileExtension == capture.audioFileExtension {
                return loaded.manifest.entry
            }
            throw RecordingJournalError.captureMissing
        }

        let activeManifest = try loadActiveManifest(
            at: activeURL,
            expectedID: capture.id
        )
        guard activeManifest.capture == capture else {
            throw RecordingJournalError.corruptRecord
        }
        guard writerWasReleased(
            capture,
            in: activeURL
        ) else {
            throw RecordingJournalError.captureWriterActive
        }
        try prepareStorage()

        if let completed = try? loadBundle(at: activeURL, expectedID: capture.id) {
            guard completed.manifest.entry.createdAt == capture.createdAt,
                  completed.manifest.entry.audioFileExtension
                    == capture.audioFileExtension else {
                throw RecordingJournalError.corruptRecord
            }
            guard !RecordingJournalPrivateIO.entryExists(at: destinationURL) else {
                throw RecordingJournalError.duplicateIdentifier
            }
            try RecordingJournalPrivateIO.renameExclusively(
                from: activeURL,
                to: destinationURL
            )
            return completed.manifest.entry
        }

        let audioURL = activeURL.appendingPathComponent(activeManifest.audioFileName)
        let byteCount: Int64
        do {
            byteCount = try RecordingJournalPrivateIO.syncRegularFile(at: audioURL)
        } catch let error as RecordingJournalError {
            throw error
        } catch let error as NSError where error.code == Int(ENOENT) {
            throw RecordingJournalError.sourceMissing
        }
        guard byteCount > 0 else { throw RecordingJournalError.emptyRecording }

        let entry = RecordingJournalEntry(
            id: capture.id,
            createdAt: capture.createdAt,
            duration: max(0, duration),
            byteCount: byteCount,
            audioFileExtension: capture.audioFileExtension
        )
        let manifest = Manifest(
            version: Manifest.currentVersion,
            entry: entry,
            audioFileName: activeManifest.audioFileName
        )
        try RecordingJournalPrivateIO.writeFileExclusively(
            try encoded(manifest),
            to: activeURL.appendingPathComponent("manifest.json")
        )
        try RecordingJournalPrivateIO.syncDirectory(at: activeURL)
        guard !RecordingJournalPrivateIO.entryExists(at: destinationURL) else {
            throw RecordingJournalError.duplicateIdentifier
        }
        try RecordingJournalPrivateIO.renameExclusively(
            from: activeURL,
            to: destinationURL
        )
        return entry
    }

    /// Promotes audio left in `Active` by a terminated process. Call this once
    /// during primary launch, before a new recording begins. It is deliberately
    /// separate from `recoverableEntries()` so foreground activation during a
    /// live recording can never adopt the file that AVFoundation is writing.
    @discardableResult
    func adoptCrashLeftCaptures() throws -> [RecordingJournalEntry] {
        try prepareStorage()
        try recoverCompletedActiveStagingBundles()
        let names = try fileManager.contentsOfDirectory(atPath: activeDirectory.path)
        var adopted: [RecordingJournalEntry] = []
        for name in names where name.hasSuffix(".recording") {
            guard let id = Self.id(fromEntryDirectoryName: name) else { continue }
            let activeURL = activeDirectory.appendingPathComponent(name, isDirectory: true)
            let destinationURL = entryDirectory(for: id)
            guard !RecordingJournalPrivateIO.entryExists(at: destinationURL) else {
                continue
            }
            guard let activeManifest = try? loadActiveManifest(
                at: activeURL,
                expectedID: id
            ), writerWasReleased(
                activeManifest.capture,
                in: activeURL
            ) else {
                continue
            }

            if let completed = try? loadBundle(at: activeURL, expectedID: id) {
                do {
                    try RecordingJournalPrivateIO.renameExclusively(
                        from: activeURL,
                        to: destinationURL
                    )
                    adopted.append(completed.manifest.entry)
                } catch {
                    continue
                }
                continue
            }
            let audioURL = activeURL.appendingPathComponent(activeManifest.audioFileName)
            guard let byteCount = try? RecordingJournalPrivateIO.syncRegularFile(
                at: audioURL
            ), byteCount > 0 else {
                continue
            }
            let entry = RecordingJournalEntry(
                id: id,
                createdAt: activeManifest.capture.createdAt,
                // The previous process died before it could persist a trusted
                // duration. Zero means unknown; it does not discard short audio.
                duration: 0,
                byteCount: byteCount,
                audioFileExtension: activeManifest.capture.audioFileExtension
            )
            let manifest = Manifest(
                version: Manifest.currentVersion,
                entry: entry,
                audioFileName: activeManifest.audioFileName
            )
            do {
                try RecordingJournalPrivateIO.writeFileExclusively(
                    try encoded(manifest),
                    to: activeURL.appendingPathComponent("manifest.json")
                )
                try RecordingJournalPrivateIO.syncDirectory(at: activeURL)
                try RecordingJournalPrivateIO.renameExclusively(
                    from: activeURL,
                    to: destinationURL
                )
                adopted.append(entry)
            } catch {
                // Leave Active authoritative. A later launch can retry without
                // depending on the temporary directory or the dead process.
                continue
            }
        }
        return adopted.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    /// Explicitly retires a reservation that never became useful audio. This
    /// is the only automatic-start failure cleanup API; ordinary launch
    /// recovery never guesses that a short active file is disposable.
    func abandonCapture(_ capture: RecordingJournalCapture) throws {
        try prepareStorage()
        let sourceURL = activeCaptureDirectory(for: capture.id)
        guard RecordingJournalPrivateIO.entryExists(at: sourceURL) else {
            throw RecordingJournalError.captureMissing
        }
        let manifest = try loadActiveManifest(
            at: sourceURL,
            expectedID: capture.id
        )
        guard manifest.capture == capture else {
            throw RecordingJournalError.corruptRecord
        }
        let audioURL = sourceURL.appendingPathComponent(manifest.audioFileName)
        if try RecordingJournalPrivateIO.regularFileExists(at: audioURL),
           try RecordingJournalPrivateIO.regularFileByteCount(at: audioURL) > 0 {
            throw RecordingJournalError.captureContainsAudio
        }
        let retiredURL = retiredDirectory.appendingPathComponent(
            "\(capture.id.uuidString.lowercased()).abandoned-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try RecordingJournalPrivateIO.renameExclusively(
            from: sourceURL,
            to: retiredURL
        )
        try? RecordingJournalPrivateIO.removeOwnedBundle(at: retiredURL)
    }

    @discardableResult
    func stageRecording(
        at sourceURL: URL,
        id: UUID = UUID(),
        duration: TimeInterval = 0,
        createdAt: Date = Date()
    ) throws -> RecordingJournalEntry {
        try prepareStorage()
        let fileExtension = safeAudioExtension(sourceURL.pathExtension)
        let audioFileName = "audio.\(fileExtension)"
        let stageName = "\(id.uuidString.lowercased()).staging-\(UUID().uuidString.lowercased())"
        let stageURL = stagingDirectory.appendingPathComponent(stageName, isDirectory: true)
        let destinationURL = entryDirectory(for: id)

        guard !RecordingJournalPrivateIO.entryExists(at: destinationURL),
              !RecordingJournalPrivateIO.entryExists(
                at: activeCaptureDirectory(for: id)
              ) else {
            throw RecordingJournalError.duplicateIdentifier
        }

        try RecordingJournalPrivateIO.createPrivateDirectoryExclusively(at: stageURL)
        var didCommit = false
        defer {
            if !didCommit {
                try? RecordingJournalPrivateIO.removeOwnedBundle(at: stageURL)
            }
        }

        let audioURL = stageURL.appendingPathComponent(audioFileName)
        let byteCount: Int64
        byteCount = try RecordingJournalPrivateIO.copyRegularFile(
            from: sourceURL,
            to: audioURL
        )
        guard byteCount > 0 else { throw RecordingJournalError.emptyRecording }

        let entry = RecordingJournalEntry(
            id: id,
            createdAt: createdAt,
            duration: max(0, duration),
            byteCount: byteCount,
            audioFileExtension: fileExtension
        )
        let manifest = Manifest(
            version: Manifest.currentVersion,
            entry: entry,
            audioFileName: audioFileName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try RecordingJournalPrivateIO.writeFileExclusively(
            manifestData,
            to: stageURL.appendingPathComponent("manifest.json")
        )
        try RecordingJournalPrivateIO.syncDirectory(at: stageURL)
        do {
            try RecordingJournalPrivateIO.renameExclusively(
                from: stageURL,
                to: destinationURL
            )
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
            throw RecordingJournalError.duplicateIdentifier
        }
        didCommit = true
        return entry
    }

    /// Returns oldest first so repeated recovery cannot starve an earlier
    /// recording. Complete bundles left in Staging by a crash are promoted
    /// before enumeration; incomplete bundles remain untouched and hidden.
    func recoverableEntries() throws -> [RecordingJournalEntry] {
        try prepareStorage()
        try recoverCompletedStagingBundles()
        let names = try fileManager.contentsOfDirectory(atPath: entriesDirectory.path)
        var entries: [RecordingJournalEntry] = []
        for name in names where name.hasSuffix(".recording") {
            let bundleURL = entriesDirectory.appendingPathComponent(name, isDirectory: true)
            guard let expectedID = Self.id(fromEntryDirectoryName: name),
                  let loaded = try? loadBundle(at: bundleURL, expectedID: expectedID) else {
                continue
            }
            entries.append(loaded.manifest.entry)
        }
        return entries.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func audioURL(for entry: RecordingJournalEntry) throws -> URL {
        try prepareStorage()
        let bundleURL = entryDirectory(for: entry.id)
        guard RecordingJournalPrivateIO.entryExists(at: bundleURL) else {
            throw RecordingJournalError.recordMissing
        }
        let loaded = try loadBundle(at: bundleURL, expectedID: entry.id)
        guard loaded.manifest.entry == entry else {
            throw RecordingJournalError.corruptRecord
        }
        return bundleURL.appendingPathComponent(loaded.manifest.audioFileName)
    }

    func consume(_ entry: RecordingJournalEntry) throws {
        try retire(entry, as: .consumed)
    }

    func discard(_ entry: RecordingJournalEntry) throws {
        try retire(entry, as: .discarded)
    }

    private func retire(
        _ entry: RecordingJournalEntry,
        as retirement: Retirement
    ) throws {
        try prepareStorage()
        let sourceURL = entryDirectory(for: entry.id)
        guard RecordingJournalPrivateIO.entryExists(at: sourceURL) else {
            throw RecordingJournalError.recordMissing
        }
        let loaded = try loadBundle(at: sourceURL, expectedID: entry.id)
        guard loaded.manifest.entry == entry else {
            throw RecordingJournalError.corruptRecord
        }

        let retiredName = "\(entry.id.uuidString.lowercased()).\(retirement.rawValue)-\(UUID().uuidString.lowercased())"
        let retiredURL = retiredDirectory.appendingPathComponent(retiredName, isDirectory: true)
        try RecordingJournalPrivateIO.renameExclusively(from: sourceURL, to: retiredURL)
        // Once the rename is durable, this recording cannot reappear as
        // recoverable even if process termination interrupts physical cleanup.
        try? RecordingJournalPrivateIO.removeOwnedBundle(at: retiredURL)
    }

    private func prepareStorage() throws {
        do {
            for directory in bootstrapDirectories {
                // Explicit anchors are only allowed inside the journal's own
                // ancestry. This keeps the bootstrap path from widening the
                // journal's chmod/no-follow boundary to an unrelated folder.
                guard
                    directory.pathComponents.count
                        < rootDirectory.pathComponents.count,
                    rootDirectory.pathComponents.starts(
                        with: directory.pathComponents
                    )
                else {
                    throw RecordingJournalError.unsafeStorage
                }
                try RecordingJournalPrivateIO.ensurePrivateDirectory(
                    at: directory
                )
            }
            let parent = rootDirectory.deletingLastPathComponent()
            try RecordingJournalPrivateIO.ensurePrivateDirectory(at: parent)
            try RecordingJournalPrivateIO.ensurePrivateDirectory(at: rootDirectory)
            try RecordingJournalPrivateIO.ensurePrivateDirectory(at: entriesDirectory)
            try RecordingJournalPrivateIO.ensurePrivateDirectory(at: activeDirectory)
            try RecordingJournalPrivateIO.ensurePrivateDirectory(at: stagingDirectory)
            try RecordingJournalPrivateIO.ensurePrivateDirectory(at: retiredDirectory)
            try? (rootDirectory as NSURL).setResourceValue(
                true,
                forKey: .isExcludedFromBackupKey
            )
            cleanupRetiredBundles()
        } catch {
            throw RecordingJournalError.unsafeStorage
        }
    }

    private func cleanupRetiredBundles() {
        guard let names = try? fileManager.contentsOfDirectory(
            atPath: retiredDirectory.path
        ) else {
            return
        }
        for name in names {
            let url = retiredDirectory.appendingPathComponent(name, isDirectory: true)
            try? RecordingJournalPrivateIO.removeOwnedBundle(at: url)
        }
    }

    private func recoverCompletedStagingBundles() throws {
        let names = try fileManager.contentsOfDirectory(atPath: stagingDirectory.path)
        for name in names {
            let stageURL = stagingDirectory.appendingPathComponent(name, isDirectory: true)
            guard let loaded = try? loadBundle(at: stageURL, expectedID: nil) else {
                continue
            }
            let destinationURL = entryDirectory(for: loaded.manifest.entry.id)
            guard !RecordingJournalPrivateIO.entryExists(at: destinationURL) else {
                continue
            }
            try? RecordingJournalPrivateIO.renameExclusively(
                from: stageURL,
                to: destinationURL
            )
        }
    }

    private func recoverCompletedActiveStagingBundles() throws {
        let names = try fileManager.contentsOfDirectory(atPath: stagingDirectory.path)
        for name in names where name.contains(".active-staging-") {
            let stageURL = stagingDirectory.appendingPathComponent(name, isDirectory: true)
            guard let activeManifest = try? loadActiveManifest(
                at: stageURL,
                expectedID: nil
            ) else {
                continue
            }
            guard !Self.processIsAlive(
                activeManifest.capture.ownerProcessIdentifier
            ) else {
                continue
            }
            let destinationURL = activeCaptureDirectory(
                for: activeManifest.capture.id
            )
            guard !RecordingJournalPrivateIO.entryExists(at: destinationURL),
                  !RecordingJournalPrivateIO.entryExists(
                    at: entryDirectory(for: activeManifest.capture.id)
                  ) else {
                continue
            }
            try? RecordingJournalPrivateIO.renameExclusively(
                from: stageURL,
                to: destinationURL
            )
        }
    }

    private func loadBundle(
        at bundleURL: URL,
        expectedID: UUID?
    ) throws -> (manifest: Manifest, audioByteCount: Int64) {
        do {
            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            let data = try RecordingJournalPrivateIO.readRegularFile(
                at: manifestURL,
                maximumByteCount: 64 * 1024
            )
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == Manifest.currentVersion,
                  expectedID == nil || manifest.entry.id == expectedID,
                  manifest.audioFileName == "audio.\(manifest.entry.audioFileExtension)",
                  safeAudioExtension(manifest.entry.audioFileExtension)
                    == manifest.entry.audioFileExtension,
                  manifest.entry.byteCount > 0,
                  manifest.entry.duration >= 0 else {
                throw RecordingJournalError.corruptRecord
            }
            let audioURL = bundleURL.appendingPathComponent(manifest.audioFileName)
            let byteCount = try RecordingJournalPrivateIO.regularFileByteCount(at: audioURL)
            guard byteCount == manifest.entry.byteCount else {
                throw RecordingJournalError.corruptRecord
            }
            return (manifest, byteCount)
        } catch let error as RecordingJournalError {
            throw error
        } catch {
            throw RecordingJournalError.corruptRecord
        }
    }

    private func loadActiveManifest(
        at bundleURL: URL,
        expectedID: UUID?
    ) throws -> ActiveManifest {
        do {
            let data = try RecordingJournalPrivateIO.readRegularFile(
                at: bundleURL.appendingPathComponent("active-manifest.json"),
                maximumByteCount: 64 * 1024
            )
            let manifest = try JSONDecoder().decode(ActiveManifest.self, from: data)
            guard manifest.version == ActiveManifest.currentVersion,
                  expectedID == nil || manifest.capture.id == expectedID,
                  manifest.audioFileName
                    == "audio.\(manifest.capture.audioFileExtension)",
                  safeAudioExtension(manifest.capture.audioFileExtension)
                    == manifest.capture.audioFileExtension else {
                throw RecordingJournalError.corruptRecord
            }
            return manifest
        } catch let error as RecordingJournalError {
            throw error
        } catch {
            throw RecordingJournalError.corruptRecord
        }
    }

    private func loadWriterReleaseManifest(
        at bundleURL: URL,
        expectedCapture: RecordingJournalCapture
    ) throws -> WriterReleaseManifest {
        do {
            let data = try RecordingJournalPrivateIO.readRegularFile(
                at: bundleURL.appendingPathComponent("writer-release.json"),
                maximumByteCount: 64 * 1024
            )
            let manifest = try JSONDecoder().decode(
                WriterReleaseManifest.self,
                from: data
            )
            guard manifest.version == WriterReleaseManifest.currentVersion,
                  manifest.capture == expectedCapture,
                  manifest.finalizedAudioFileName
                    == "audio.\(expectedCapture.audioFileExtension)" else {
                throw RecordingJournalError.corruptRecord
            }
            return manifest
        } catch let error as RecordingJournalError {
            throw error
        } catch {
            throw RecordingJournalError.corruptRecord
        }
    }

    private func writerWasReleased(
        _ capture: RecordingJournalCapture,
        in bundleURL: URL
    ) -> Bool {
        if Self.releasedCaptureRegistry.contains(capture.id) { return true }
        if (try? loadWriterReleaseManifest(
            at: bundleURL,
            expectedCapture: capture
        )) != nil {
            return true
        }
        return !Self.processIsAlive(capture.ownerProcessIdentifier)
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func entryDirectory(for id: UUID) -> URL {
        entriesDirectory.appendingPathComponent(
            "\(id.uuidString.lowercased()).recording",
            isDirectory: true
        )
    }

    private func activeCaptureDirectory(for id: UUID) -> URL {
        activeDirectory.appendingPathComponent(
            "\(id.uuidString.lowercased()).recording",
            isDirectory: true
        )
    }

    private func safeAudioExtension(_ candidate: String) -> String {
        let normalized = candidate.lowercased()
        return Self.audioExtensions.contains(normalized) ? normalized : "m4a"
    }

    private static func id(fromEntryDirectoryName name: String) -> UUID? {
        guard name.hasSuffix(".recording") else { return nil }
        return UUID(uuidString: String(name.dropLast(".recording".count)))
    }

    private static func processIsAlive(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        if kill(processIdentifier, 0) == 0 { return true }
        // EPERM proves a process exists even if this sandbox cannot signal it.
        return errno != ESRCH
    }

    private static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "mp4",
        "ogg", "opus", "wav", "webm",
    ]
}

/// Descriptor-relative filesystem operations for the iPhone recovery journal.
/// Every final owned component is opened with `O_NOFOLLOW`, and incoming audio
/// must be a regular, single-link file.
private enum RecordingJournalPrivateIO {
    private static let directoryPermissions: mode_t = 0o700
    private static let filePermissions: mode_t = 0o600

    static func ensurePrivateDirectory(at directoryURL: URL) throws {
        var status = stat()
        let exists = directoryURL.path.withCString { lstat($0, &status) == 0 }
        if exists {
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                throw unsafeStorageError(path: directoryURL.path)
            }
        } else {
            let lookupError = errno
            guard lookupError == ENOENT else {
                throw posixError(path: directoryURL.path, code: lookupError)
            }
            let parentURL = directoryURL.deletingLastPathComponent()
            let parentFD = try openDirectory(at: parentURL, makePrivate: false)
            defer { close(parentFD) }
            let name = try safeBasename(of: directoryURL)
            let result = name.withCString {
                mkdirat(parentFD, $0, directoryPermissions)
            }
            if result != 0, errno != EEXIST {
                throw posixError(path: directoryURL.path)
            }
            guard fsync(parentFD) == 0 else {
                throw posixError(path: parentURL.path)
            }
        }
        let descriptor = try openDirectory(at: directoryURL, makePrivate: true)
        close(descriptor)
    }

    static func createPrivateDirectoryExclusively(at directoryURL: URL) throws {
        let parentFD = try openDirectory(
            at: directoryURL.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(parentFD) }
        let name = try safeBasename(of: directoryURL)
        let result = name.withCString { mkdirat(parentFD, $0, directoryPermissions) }
        guard result == 0 else { throw posixError(path: directoryURL.path) }
        guard fsync(parentFD) == 0 else {
            throw posixError(path: directoryURL.deletingLastPathComponent().path)
        }
    }

    static func entryExists(at url: URL) -> Bool {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        guard result == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFDIR
    }

    /// AVAudioRecorder must never truncate an existing journal file. Validate
    /// through the already-opened parent so a final-component symlink cannot
    /// redirect capture outside the reserved bundle.
    static func validateVacantRecordingDestination(at url: URL) throws {
        let parentFD = try openDirectory(
            at: url.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(parentFD) }
        let name = try safeBasename(of: url)
        var status = stat()
        let result = name.withCString {
            fstatat(parentFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            let lookupError = errno
            guard lookupError == ENOENT else {
                throw posixError(path: url.path, code: lookupError)
            }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw unsafeStorageError(path: url.path)
        }
        throw posixError(path: url.path, code: EEXIST)
    }

    static func validateAbsentOrRegularFile(at url: URL) throws {
        let parentFD = try openDirectory(
            at: url.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(parentFD) }
        let name = try safeBasename(of: url)
        var status = stat()
        let result = name.withCString {
            fstatat(parentFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            let lookupError = errno
            guard lookupError == ENOENT else {
                throw posixError(path: url.path, code: lookupError)
            }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw unsafeStorageError(path: url.path)
        }
    }

    static func regularFileExists(at url: URL) throws -> Bool {
        let parentFD = try openDirectory(
            at: url.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(parentFD) }
        let name = try safeBasename(of: url)
        var status = stat()
        let result = name.withCString {
            fstatat(parentFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            let lookupError = errno
            if lookupError == ENOENT { return false }
            throw posixError(path: url.path, code: lookupError)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw unsafeStorageError(path: url.path)
        }
        return true
    }

    @discardableResult
    static func copyRegularFile(from sourceURL: URL, to destinationURL: URL) throws -> Int64 {
        let sourceFD = sourceURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceFD >= 0 else { throw RecordingJournalError.sourceMissing }
        defer { close(sourceFD) }

        var sourceStatus = stat()
        guard fstat(sourceFD, &sourceStatus) == 0 else {
            throw posixError(path: sourceURL.path)
        }
        guard (sourceStatus.st_mode & S_IFMT) == S_IFREG,
              sourceStatus.st_nlink == 1 else {
            throw RecordingJournalError.sourceMissing
        }
        guard sourceStatus.st_size > 0 else {
            throw RecordingJournalError.emptyRecording
        }

        let destinationDirectoryFD = try openDirectory(
            at: destinationURL.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(destinationDirectoryFD) }
        let destinationName = try safeBasename(of: destinationURL)
        let destinationFD = destinationName.withCString {
            openat(
                destinationDirectoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                filePermissions
            )
        }
        guard destinationFD >= 0 else { throw posixError(path: destinationURL.path) }
        var completed = false
        defer {
            close(destinationFD)
            if !completed {
                _ = destinationName.withCString {
                    unlinkat(destinationDirectoryFD, $0, 0)
                }
            }
        }

        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(sourceFD, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(path: sourceURL.path)
            }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = write(
                        destinationFD,
                        baseAddress.advanced(by: offset),
                        count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError(path: destinationURL.path)
                    }
                    guard written > 0 else {
                        throw posixError(path: destinationURL.path, code: EIO)
                    }
                    offset += written
                    copied += Int64(written)
                }
            }
        }
        guard copied == sourceStatus.st_size else {
            throw posixError(path: destinationURL.path, code: EIO)
        }
        guard fchmod(destinationFD, filePermissions) == 0,
              fsync(destinationFD) == 0,
              fsync(destinationDirectoryFD) == 0 else {
            throw posixError(path: destinationURL.path)
        }
        completed = true
        return copied
    }

    static func writeFileExclusively(_ data: Data, to url: URL) throws {
        let directoryFD = try openDirectory(
            at: url.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(directoryFD) }
        let name = try safeBasename(of: url)
        let descriptor = name.withCString {
            openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                filePermissions
            )
        }
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        var completed = false
        defer {
            close(descriptor)
            if !completed {
                _ = name.withCString { unlinkat(directoryFD, $0, 0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: url.path)
                }
                guard written > 0 else {
                    throw posixError(path: url.path, code: EIO)
                }
                offset += written
            }
        }
        guard fchmod(descriptor, filePermissions) == 0,
              fsync(descriptor) == 0,
              fsync(directoryFD) == 0 else {
            throw posixError(path: url.path)
        }
        completed = true
    }

    static func readRegularFile(at url: URL, maximumByteCount: Int64) throws -> Data {
        let descriptor = try openRegularFile(at: url)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size >= 0,
              status.st_size <= maximumByteCount else {
            throw RecordingJournalError.corruptRecord
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    static func regularFileByteCount(at url: URL) throws -> Int64 {
        let descriptor = try openRegularFile(at: url)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size > 0 else {
            throw RecordingJournalError.corruptRecord
        }
        return status.st_size
    }

    /// Flushes AVAudioRecorder's finalized file before a manifest can make it
    /// recoverable. The descriptor is opened without following links and the
    /// byte count comes from that same opened inode.
    static func syncRegularFile(at url: URL) throws -> Int64 {
        let descriptor = try openRegularFile(at: url, accessFlags: O_RDWR)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixError(path: url.path)
        }
        guard status.st_size > 0 else {
            throw RecordingJournalError.emptyRecording
        }
        guard fchmod(descriptor, filePermissions) == 0,
              fsync(descriptor) == 0 else {
            throw posixError(path: url.path)
        }
        return status.st_size
    }

    static func renameExclusively(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceParentFD = try openDirectory(
            at: sourceURL.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(sourceParentFD) }
        let destinationParentFD = try openDirectory(
            at: destinationURL.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(destinationParentFD) }
        let sourceName = try safeBasename(of: sourceURL)
        let destinationName = try safeBasename(of: destinationURL)
        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(
                    sourceParentFD,
                    source,
                    destinationParentFD,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else { throw posixError(path: destinationURL.path) }
        guard fsync(destinationParentFD) == 0,
              fsync(sourceParentFD) == 0 else {
            throw posixError(path: destinationURL.path)
        }
    }

    static func syncDirectory(at url: URL) throws {
        let descriptor = try openDirectory(at: url, makePrivate: true)
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(path: url.path) }
    }

    static func removeOwnedBundle(at bundleURL: URL) throws {
        let bundleFD = try openDirectory(at: bundleURL, makePrivate: true)
        let knownNames = [
            "manifest.json",
            "active-manifest.json",
            "writer-release.json",
        ]
        for name in knownNames {
            _ = name.withCString { unlinkat(bundleFD, $0, 0) }
        }

        // The only other permitted entry is `audio.<safe extension>`. Enumerate
        // without following it, then unlink only a regular, single-link file.
        let duplicateFD = dup(bundleFD)
        if duplicateFD >= 0, let stream = fdopendir(duplicateFD) {
            while let rawEntry = readdir(stream) {
                let name = withUnsafePointer(to: rawEntry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                guard name != ".", name != "..", name.hasPrefix("audio.") else { continue }
                var status = stat()
                let isRegularSingleLink = name.withCString {
                    fstatat(bundleFD, $0, &status, AT_SYMLINK_NOFOLLOW) == 0
                } && (status.st_mode & S_IFMT) == S_IFREG && status.st_nlink == 1
                if isRegularSingleLink {
                    _ = name.withCString { unlinkat(bundleFD, $0, 0) }
                }
            }
            closedir(stream)
        } else if duplicateFD >= 0 {
            close(duplicateFD)
        }
        _ = fsync(bundleFD)
        close(bundleFD)

        let parentFD = try openDirectory(
            at: bundleURL.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(parentFD) }
        let name = try safeBasename(of: bundleURL)
        let result = name.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
        if result != 0, errno != ENOENT, errno != ENOTEMPTY {
            throw posixError(path: bundleURL.path)
        }
        _ = fsync(parentFD)
    }

    @discardableResult
    static func removeRegularFile(at url: URL) throws -> Bool {
        let parentFD = try openDirectory(
            at: url.deletingLastPathComponent(),
            makePrivate: false
        )
        defer { close(parentFD) }
        let name = try safeBasename(of: url)
        var status = stat()
        let lookup = name.withCString {
            fstatat(parentFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if lookup != 0, errno == ENOENT { return false }
        guard lookup == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw unsafeStorageError(path: url.path)
        }
        guard name.withCString({ unlinkat(parentFD, $0, 0) }) == 0 else {
            throw posixError(path: url.path)
        }
        _ = fsync(parentFD)
        return true
    }

    private static func openDirectory(at url: URL, makePrivate: Bool) throws -> Int32 {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw unsafeStorageError(path: url.path)
        }
        if makePrivate, fchmod(descriptor, directoryPermissions) != 0 {
            close(descriptor)
            throw posixError(path: url.path)
        }
        return descriptor
    }

    private static func openRegularFile(
        at url: URL,
        accessFlags: Int32 = O_RDONLY
    ) throws -> Int32 {
        let directoryFD = try openDirectory(
            at: url.deletingLastPathComponent(),
            makePrivate: true
        )
        defer { close(directoryFD) }
        let name = try safeBasename(of: url)
        let descriptor = name.withCString {
            openat(
                directoryFD,
                $0,
                accessFlags | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            close(descriptor)
            throw unsafeStorageError(path: url.path)
        }
        return descriptor
    }

    private static func safeBasename(of url: URL) throws -> String {
        let name = url.lastPathComponent
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw unsafeStorageError(path: url.path)
        }
        return name
    }

    private static func unsafeStorageError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ELOOP),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "The recording journal contains an unsafe storage boundary.",
            ]
        )
    }

    private static func posixError(path: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
