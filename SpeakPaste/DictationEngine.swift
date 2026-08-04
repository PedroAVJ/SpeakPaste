import Combine
import Foundation
import UIKit

/// Dictation that never needs SpeakPaste on screen.
///
/// A keyboard extension cannot reach the microphone, which is the only reason
/// SpeakPaste ever foregrounded itself mid-dictation. Driving capture from an
/// App Intent instead means the app you are typing in keeps the screen, and
/// the keyboard's only remaining job is inserting the finished transcript at
/// the cursor. No app switch, and no switchback to get wrong.
@MainActor
final class DictationEngine {
    static let shared = DictationEngine()

    enum EngineError: LocalizedError {
        case missingAPIKey
        case microphoneDenied
        case backgroundCaptureUnavailable
        case backgroundTranscriptionUnavailable
        case backgroundTranscriptionExpired
        case sharedStateUnavailable
        case captureBusy
        case pendingTranscript

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Add your ElevenLabs API key in SpeakPaste before dictating."
            case .microphoneDenied:
                "Microphone access is off. Enable it for SpeakPaste in Settings."
            case .backgroundCaptureUnavailable:
                "iOS refused the microphone in the background. If another app or a screen recording is using audio, stop it and tap again."
            case .backgroundTranscriptionUnavailable:
                "iOS could not reserve enough background time to transcribe. The recording was saved; open SpeakPaste to retry."
            case .backgroundTranscriptionExpired:
                "iOS ended the background transcription window. The recording was saved; open SpeakPaste to retry."
            case .sharedStateUnavailable:
                "The transcript finished, but SpeakPaste couldn't deliver it to the keyboard. The recording was saved; open SpeakPaste to retry."
            case .captureBusy:
                "SpeakPaste is already recording in the app. Stop that recording before starting another one."
            case .pendingTranscript:
                "Switch to the SpeakPaste keyboard to insert the previous transcript before starting another dictation."
            }
        }
    }

    private let recorder = AudioRecorder()
    private let store = SharedDictationStore()
    private let keychain = KeychainStore()
    private let client: ElevenLabsClientProtocol
    private let defaults: UserDefaults
    private let history = HistoryStore()
    private let recordingJournal: RecordingJournal

    private var sessionID: UUID?
    private var recordingURL: URL?
    private var recordingCapture: RecordingJournalCapture?
    private var recordingJournalEntry: RecordingJournalEntry?
    private var isStarting = false
    private var isStopping = false
    private var heartbeatTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var transcriptionTask: Task<TranscriptionResult, Error>?
    private var transcriptionAttemptID: UUID?
    private var recorderEventCancellable: AnyCancellable?
    private let liveActivity = DictationLiveActivity()

    init(
        client: ElevenLabsClientProtocol = ElevenLabsClient(
            retryPolicy: .backgroundIntent,
            requestTimeout: 25,
            maximumConcurrentRequests: 1
        ),
        defaults: UserDefaults = .standard,
        recordingJournal: RecordingJournal = RecordingJournal()
    ) {
        self.client = client
        self.defaults = defaults
        self.recordingJournal = recordingJournal
        recorderEventCancellable = recorder.events.sink { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleRecorderEvent(event)
            }
        }
    }

    var isRecording: Bool { sessionID != nil && recorder.isRecording }

    /// One gesture for the whole round trip, so a single Back Tap binding both
    /// starts and finishes a dictation.
    func toggle() async throws {
        if isRecording {
            try await stop()
            return
        }
        // Ignore another gesture while startup, transcription, or teardown is
        // already in flight. Those awaits are MainActor-reentrant, so checking
        // only AVAudioRecorder would let a fast extra Back Tap replace the
        // current session.
        guard sessionID == nil, !isStarting, !isStopping else { return }
        try await start()
    }

    func start() async throws {
        guard sessionID == nil, !isStarting, !isStopping else { return }
        isStarting = true
        defer { isStarting = false }

        guard let snapshot = store.beginBackgroundSession() else {
            throw store.isCaptureLeaseActive
                ? EngineError.captureBusy
                : EngineError.pendingTranscript
        }
        sessionID = snapshot.sessionID
        // Startup can include permission and Live Activity work. Keep the
        // keyboard from declaring that still-owned session abandoned.
        startHeartbeat(sessionID: snapshot.sessionID)

        guard
            let key = keychain.load()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            store.setPhase(
                .failed,
                sessionID: snapshot.sessionID,
                errorMessage: EngineError.missingAPIKey.localizedDescription,
                hasRecoverableAudio: false,
                recoveryAction: .openContainingApp
            )
            finish()
            throw EngineError.missingAPIKey
        }
        guard await recorder.requestPermission() else {
            store.setPhase(
                .failed,
                sessionID: snapshot.sessionID,
                errorMessage: EngineError.microphoneDenied.localizedDescription,
                hasRecoverableAudio: false,
                recoveryAction: .openContainingApp
            )
            finish()
            throw EngineError.microphoneDenied
        }

        do {
            // Apple requires the Live Activity for an AudioRecordingIntent and
            // stops capture when it is missing. Start it before touching the
            // audio session so this is a supported cold background launch.
            try await liveActivity.start(
                sessionID: snapshot.sessionID,
                startedAt: snapshot.startedAt
            )
        } catch {
            store.setPhase(
                .failed,
                sessionID: snapshot.sessionID,
                errorMessage: error.localizedDescription,
                hasRecoverableAudio: false,
                recoveryAction: .openContainingApp
            )
            finish()
            throw error
        }

        do {
            let capture = try recordingJournal.beginCapture(
                id: snapshot.sessionID
            )
            recordingCapture = capture
            recordingURL = try await recorder.start(
                capture: capture,
                in: recordingJournal
            )
            let recordingStartedAt = Date()
            guard store.setPhase(
                .recording,
                sessionID: snapshot.sessionID,
                hasRecoverableAudio: true,
                startedAt: recordingStartedAt
            ) else {
                throw EngineError.sharedStateUnavailable
            }
            await liveActivity.update(
                .recording,
                sessionID: snapshot.sessionID,
                recordingStartedAt: recordingStartedAt
            )
        } catch {
            let audioURL = recorder.stop() ?? recordingURL
            var hasRecoverableAudio = false
            if let recordingCapture {
                do {
                    try recordingJournal.abandonCapture(recordingCapture)
                    self.recordingCapture = nil
                } catch {
                    recordingURL = (try? recordingJournal.audioURL(
                        for: recordingCapture
                    )) ?? audioURL
                    recordingURL = finalizeProtectedRecording(
                        at: recordingURL,
                        sessionID: snapshot.sessionID,
                        duration: recorder.duration
                    )
                    hasRecoverableAudio = recordingURL != nil
                }
            } else if recordingJournalEntry != nil {
                hasRecoverableAudio = true
            } else if let audioURL {
                cleanUpRecording(at: audioURL)
            }
            if !hasRecoverableAudio {
                recordingURL = nil
            }
            let surfacedError: any Error
            if
                case let AudioRecorderError.configurationFailed(stage, _) = error,
                stage == "activation",
                UIApplication.shared.applicationState != .active
            {
                surfacedError = EngineError.backgroundCaptureUnavailable
            } else {
                surfacedError = error
            }
            await liveActivity.end(.failed, sessionID: snapshot.sessionID)
            store.setPhase(
                .failed,
                sessionID: snapshot.sessionID,
                errorMessage: surfacedError.localizedDescription,
                hasRecoverableAudio: hasRecoverableAudio,
                recoveryAction: .openContainingApp
            )
            finish()
            throw surfacedError
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func stop() async throws {
        guard let sessionID, !isStarting, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        let attemptID = UUID()
        transcriptionAttemptID = attemptID
        defer {
            if transcriptionAttemptID == attemptID {
                transcriptionTask = nil
                transcriptionAttemptID = nil
            }
        }
        let duration = recorder.duration
        let finalizedURL = recorder.stop() ?? recordingURL
        _ = store.releaseCaptureLease(ownerID: sessionID)
        let audioURL = finalizeProtectedRecording(
            at: finalizedURL,
            sessionID: sessionID,
            duration: duration
        )

        // Recording itself owns background execution through the audio session
        // and Live Activity. Start a fresh finite task at stop so a long
        // dictation cannot consume the transcription window before it begins.
        guard beginBackgroundExecution() else {
            transcriptionAttemptID = nil
            stopHeartbeat()
            store.setPhase(
                .failed,
                sessionID: sessionID,
                errorMessage: EngineError.backgroundTranscriptionUnavailable.localizedDescription,
                hasRecoverableAudio: true,
                recoveryAction: .openContainingApp
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await liveActivity.end(.failed, sessionID: sessionID)
            finish()
            throw EngineError.backgroundTranscriptionUnavailable
        }
        // Keep the App Group heartbeat alive through the network request. The
        // keyboard treats a silent owner as abandoned after 15 seconds; ending
        // the heartbeat here could erase a legitimate slow transcription.
        await liveActivity.update(.transcribing, sessionID: sessionID)

        guard
            self.sessionID == sessionID,
            transcriptionAttemptID == attemptID
        else {
            throw EngineError.backgroundTranscriptionExpired
        }

        guard
            let audioURL,
            let key = keychain.load()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            transcriptionAttemptID = nil
            stopHeartbeat()
            store.setPhase(
                .failed,
                sessionID: sessionID,
                errorMessage: EngineError.missingAPIKey.localizedDescription,
                hasRecoverableAudio: true,
                recoveryAction: .openContainingApp
            )
            await liveActivity.end(.failed, sessionID: sessionID)
            finish()
            throw EngineError.missingAPIKey
        }

        store.setPhase(.transcribing, sessionID: sessionID)
        let requestedLanguage = language
        let requestedCleanSpeech = cleanSpeech
        let client = self.client
        let task = Task {
            try await client.transcribe(
                audioURL: audioURL,
                apiKey: key,
                language: requestedLanguage,
                cleanSpeech: requestedCleanSpeech
            )
        }
        transcriptionTask = task
        do {
            let result = try await task.value
            guard
                self.sessionID == sessionID,
                transcriptionAttemptID == attemptID
            else {
                throw EngineError.backgroundTranscriptionExpired
            }
            // The network work is complete. Keep the attempt token live until
            // the transcript itself has reached durable shared storage.
            transcriptionTask = nil
            let historyPersisted = history.add(
                TranscriptItem(
                    text: result.text,
                    languageCode: result.languageCode,
                    duration: duration,
                    sourceSessionID: sessionID
                )
            )
            // No more heartbeats may race the keyboard's terminal
            // `.completed -> .inserted` transition in the other process.
            stopHeartbeat()
            // The active keyboard inserts at the cursor on the system's clock.
            // A background pasteboard write was proven to silently no-op on
            // device, so history remains the explicit manual fallback.
            guard store.setPhase(
                .completed,
                sessionID: sessionID,
                transcript: result.text,
                historyPersisted: historyPersisted
            ) else {
                throw EngineError.sharedStateUnavailable
            }
            // Expiration after the durable commit must not replace a completed
            // transcript with failure while ActivityKit is winding down.
            transcriptionAttemptID = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            consumeProtectedRecording(fallbackURL: audioURL)
            await liveActivity.end(.completed, sessionID: sessionID)
            finish()
        } catch {
            guard
                self.sessionID == sessionID,
                transcriptionAttemptID == attemptID
            else {
                throw EngineError.backgroundTranscriptionExpired
            }
            transcriptionTask = nil
            transcriptionAttemptID = nil
            stopHeartbeat()
            store.setPhase(
                .failed,
                sessionID: sessionID,
                errorMessage: error.localizedDescription,
                hasRecoverableAudio: true,
                recoveryAction: .openContainingApp
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await liveActivity.end(.failed, sessionID: sessionID)
            finish()
            throw error
        }
    }

    func cancel() async {
        guard let sessionID, !isStarting, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        let audioURL = recorder.stop() ?? recordingURL
        _ = store.releaseCaptureLease(ownerID: sessionID)
        recordingURL = finalizeProtectedRecording(
            at: audioURL,
            sessionID: sessionID,
            duration: recorder.duration
        )
        guard discardProtectedRecording(fallbackURL: recordingURL) else {
            store.setPhase(
                .failed,
                sessionID: sessionID,
                errorMessage: "SpeakPaste couldn't discard the recording. Open SpeakPaste to recover it.",
                hasRecoverableAudio: true,
                recoveryAction: .openContainingApp
            )
            await liveActivity.end(.failed, sessionID: sessionID)
            finish()
            return
        }
        stopHeartbeat()
        store.setPhase(.cancelled, sessionID: sessionID)
        await liveActivity.end(.cancelled, sessionID: sessionID)
        finish()
    }

    private var language: TranscriptionLanguage {
        defaults.string(forKey: "transcription-language")
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .automatic
    }

    private var cleanSpeech: Bool {
        defaults.object(forKey: "clean-speech") as? Bool ?? true
    }

    private func startHeartbeat(sessionID: UUID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard
                    !Task.isCancelled,
                    let self,
                    self.sessionID == sessionID
                else {
                    return
                }

                tick += 1
                if tick.isMultiple(of: 25) {
                    // Without this the keyboard treats the session as abandoned.
                    self.store.touch(sessionID: sessionID)
                }

                let acceptedCommands: Set<SharedDictationCommand> =
                    self.recorder.isRecording ? [.stop, .cancel] : []
                switch self.store.takePendingCommand(
                    sessionID: sessionID,
                    accepting: acceptedCommands
                ) {
                case .stop:
                    Task { try? await self.stop() }
                case .cancel:
                    Task { await self.cancel() }
                case .none, .retry:
                    break
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func finish() {
        if let sessionID {
            _ = store.releaseCaptureLease(ownerID: sessionID)
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionAttemptID = nil
        sessionID = nil
        recordingURL = nil
        recordingCapture = nil
        recordingJournalEntry = nil
        stopHeartbeat()
        endBackgroundExecution()
    }

    private func finalizeProtectedRecording(
        at finalizedURL: URL?,
        sessionID: UUID,
        duration: TimeInterval
    ) -> URL? {
        guard let finalizedURL else { return nil }
        if let recordingCapture {
            do {
                let entry = try recordingJournal.finalizeCapture(
                    recordingCapture,
                    duration: duration
                )
                let protectedURL = try recordingJournal.audioURL(for: entry)
                recordingJournalEntry = entry
                self.recordingCapture = nil
                recordingURL = protectedURL
                return protectedURL
            } catch {
                // The audio remains journal-owned in Active and can be adopted
                // by the containing app after a process exit.
                recordingURL = finalizedURL
                return finalizedURL
            }
        }
        if recordingJournalEntry != nil {
            return recordingURL ?? finalizedURL
        }
        do {
            let entry = try recordingJournal.stageRecording(
                at: finalizedURL,
                id: sessionID,
                duration: duration
            )
            let protectedURL = try recordingJournal.audioURL(for: entry)
            recordingJournalEntry = entry
            recordingURL = protectedURL
            if finalizedURL.standardizedFileURL != protectedURL.standardizedFileURL {
                cleanUpRecording(at: finalizedURL)
            }
            return protectedURL
        } catch {
            // Keep the original file usable for this attempt. The shared error
            // path opens the app if transcription fails.
            recordingURL = finalizedURL
            return finalizedURL
        }
    }

    private func consumeProtectedRecording(fallbackURL: URL) {
        if let recordingCapture {
            if let entry = try? recordingJournal.finalizeCapture(
                recordingCapture,
                duration: recorder.duration
            ) {
                try? recordingJournal.consume(entry)
            }
        } else if let recordingJournalEntry {
            try? recordingJournal.consume(recordingJournalEntry)
        } else {
            cleanUpRecording(at: fallbackURL)
        }
        recordingJournalEntry = nil
        recordingCapture = nil
        recordingURL = nil
    }

    private func discardProtectedRecording(fallbackURL: URL?) -> Bool {
        do {
            if let recordingCapture {
                let entry = try recordingJournal.finalizeCapture(
                    recordingCapture,
                    duration: recorder.duration
                )
                try recordingJournal.discard(entry)
            } else if let recordingJournalEntry {
                try recordingJournal.discard(recordingJournalEntry)
            } else if let fallbackURL {
                try FileManager.default.removeItem(at: fallbackURL)
            }
            recordingJournalEntry = nil
            recordingCapture = nil
            recordingURL = nil
            return true
        } catch {
            return false
        }
    }

    private func handleRecorderEvent(_ event: AudioRecorderEvent) {
        let shouldFinalize: Bool
        switch event {
        case .maximumDurationReached,
             .interruptionBegan,
             .recordingEndedUnexpectedly:
            shouldFinalize = true
        case let .routeChanged(change):
            shouldFinalize = change.finalizedRecordingURL != nil
        case .interruptionEnded,
             .noAudioDetected,
             .maximumDurationApproaching:
            shouldFinalize = false
        }
        guard shouldFinalize, sessionID != nil, !isStopping else { return }
        Task { [weak self] in
            try? await self?.stop()
        }
    }

    private func cleanUpRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func beginBackgroundExecution() -> Bool {
        endBackgroundExecution()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "Finish background dictation"
        ) { [weak self] in
            // UIKit invokes expiration handlers on the main thread. Commit the
            // terminal shared phase synchronously so iOS cannot suspend the
            // process between releasing the assertion and publishing failure.
            MainActor.assumeIsolated {
                self?.expireBackgroundTranscription()
            }
        }
        return backgroundTaskID != .invalid
    }

    private func expireBackgroundTranscription() {
        guard
            let sessionID,
            transcriptionAttemptID != nil
        else {
            endBackgroundExecution()
            return
        }

        let expiringBackgroundTaskID = backgroundTaskID
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionAttemptID = nil
        stopHeartbeat()
        store.setPhase(
            .failed,
            sessionID: sessionID,
            errorMessage: EngineError.backgroundTranscriptionExpired.localizedDescription,
            hasRecoverableAudio: true,
            recoveryAction: .openContainingApp
        )
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        self.sessionID = nil
        recordingURL = nil
        recordingJournalEntry = nil

        // ActivityKit closure is session-scoped and best effort after the
        // durable failure. UIKit requires the expired background assertion to
        // be released immediately from this handler, not after an async join.
        Task { @MainActor in
            await liveActivity.end(.failed, sessionID: sessionID)
        }
        endBackgroundExecution(expected: expiringBackgroundTaskID)
    }

    private func endBackgroundExecution(
        expected taskID: UIBackgroundTaskIdentifier? = nil
    ) {
        if let taskID, backgroundTaskID != taskID { return }
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
