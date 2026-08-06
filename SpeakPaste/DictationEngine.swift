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
        case sessionRecoveryUnavailable
        case recoveryRequired
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
            case .sessionRecoveryUnavailable:
                "SpeakPaste couldn't save the segmented dictation recovery record. No recording was started."
            case .recoveryRequired:
                "A previous recording still needs recovery. Open SpeakPaste to retry or discard it."
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
    private let segmentedSessionStore: SegmentedDictationSessionStore

    private struct FinalizedSegment {
        let ordinal: Int
        let entry: RecordingJournalEntry
        let audioURL: URL
        let duration: TimeInterval
    }

    private struct SegmentWork {
        let ordinal: Int
        let entry: RecordingJournalEntry
        let audioURL: URL
        let duration: TimeInterval
        let transcriptionTask: Task<TranscriptionResult, Error>
    }

    private var sessionID: UUID?
    private var captureState: SegmentedDictationCaptureState = .idle
    private var recordingURL: URL?
    private var recordingCapture: RecordingJournalCapture?
    private var recordingJournalEntry: RecordingJournalEntry?
    private var currentSegmentOrdinal: Int?
    private var segmentWorks: [SegmentWork] = []
    private var pendingSegmentIDs: Set<UUID> = []
    /// Distinguishes callbacks from a prior transcription attempt even when a
    /// crash-recovery attempt deliberately reuses the same parent session ID.
    private var segmentWorkGeneration = UUID()
    private var nextSegmentOrdinal = 0
    private var closingAttemptID: UUID?
    private var rehydratingSessionID: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var recorderEventCancellable: AnyCancellable?
    private let liveActivity = DictationLiveActivity()

    init(
        client: ElevenLabsClientProtocol = ElevenLabsClient(
            retryPolicy: .backgroundIntent,
            requestTimeout: 25,
            maximumConcurrentRequests: 1
        ),
        defaults: UserDefaults = .standard,
        recordingJournal: RecordingJournal = RecordingJournal(),
        segmentedSessionStore: SegmentedDictationSessionStore =
            SegmentedDictationSessionStore()
    ) {
        self.client = client
        self.defaults = defaults
        self.recordingJournal = recordingJournal
        self.segmentedSessionStore = segmentedSessionStore
        recorderEventCancellable = recorder.events.sink { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleRecorderEvent(event)
            }
        }
    }

    var isRecording: Bool { sessionID != nil && recorder.isRecording }

    /// Back Tap is one fixed gesture; the current capture state supplies its
    /// meaning. Transitional states intentionally absorb duplicates.
    func toggle() async throws {
        let sharedBeforeRehydration = store.load()
        if sessionID == nil, captureState == .idle {
            // A duplicate system invocation must not reinterpret a durable
            // transitional phase as a brand-new recording.
            guard ![
                SharedDictationPhase.launching,
                .transcribing,
            ].contains(sharedBeforeRehydration.phase) else {
                return
            }
            if sharedBeforeRehydration.sessionKind == .keyboardRoundTrip,
               [.launching, .starting, .recording, .transcribing]
                    .contains(sharedBeforeRehydration.phase) {
                // The compatibility lane is owned by AppModel and has no
                // segmented manifest. Back Tap must never convert its live
                // recorder into a false crash-recovery failure.
                return
            }
            if sharedBeforeRehydration.phase == .starting,
               store.isCaptureLeaseActive {
                // Permission and audio-session startup are user-paced, but a
                // live process renews this lease. Once it expires, a later tap
                // is allowed to retire an empty child or bank crash-left audio.
                return
            }
            let didRehydrate = try await rehydrateSessionIfNeeded(
                expectedSessionID: sharedBeforeRehydration.sessionID
            )
            if didRehydrate,
               [.starting, .recording]
                    .contains(sharedBeforeRehydration.phase) {
                // A process death already stopped the microphone. Rehydration
                // finalized that hot child and therefore fulfilled this tap's
                // requested Pause; do not immediately resume it.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                return
            }
        }
        switch captureState.toggleAction {
        case .start:
            try await start()
        case .pause:
            guard let sessionID else { return }
            try await pause(expectedSessionID: sessionID)
        case .resume:
            guard let sessionID else { return }
            try await resume(expectedSessionID: sessionID)
        case .none:
            return
        }
    }

    func start() async throws {
        if sessionID == nil {
            let persisted = store.load()
            if persisted.phase == .failed,
               persisted.hasRecoverableAudio != true {
                _ = store.resetNonrecoverableFailure(
                    sessionID: persisted.sessionID
                )
            }
            _ = SegmentedDictationFailureRepair.resetIfProvablyEmpty(
                snapshot: store.load(),
                sharedStore: store,
                sessionStore: segmentedSessionStore,
                recordingJournal: recordingJournal
            )
            if try await rehydrateSessionIfNeeded(
                expectedSessionID: store.load().sessionID
            ) {
                return
            }
        }
        guard sessionID == nil, captureState == .idle else { return }
        captureState = .starting

        guard let snapshot = store.beginBackgroundSession() else {
            captureState = .idle
            let current = store.load()
            if store.isCaptureLeaseActive {
                throw EngineError.captureBusy
            }
            if current.phase == .failed,
               current.hasRecoverableAudio == true {
                throw EngineError.recoveryRequired
            }
            throw EngineError.pendingTranscript
        }
        sessionID = snapshot.sessionID
        do {
            _ = try segmentedSessionStore.create(
                sessionID: snapshot.sessionID
            )
        } catch {
            store.setPhase(
                .failed,
                sessionID: snapshot.sessionID,
                errorMessage: EngineError.sessionRecoveryUnavailable
                    .localizedDescription,
                hasRecoverableAudio: false,
                recoveryAction: .openContainingApp
            )
            finish()
            throw EngineError.sessionRecoveryUnavailable
        }
        segmentWorkGeneration = UUID()
        segmentWorks = []
        pendingSegmentIDs = []
        nextSegmentOrdinal = 0
        // Startup can include permission and Live Activity work. Keep the
        // keyboard from declaring that still-owned session abandoned.
        startHeartbeat(sessionID: snapshot.sessionID)

        guard
            let key = keychain.load()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            try? segmentedSessionStore.delete(sessionID: snapshot.sessionID)
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
            try? segmentedSessionStore.delete(sessionID: snapshot.sessionID)
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
            try? segmentedSessionStore.delete(sessionID: snapshot.sessionID)
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
            try await beginHotSegmentCapture()
            guard
                sessionID == snapshot.sessionID,
                captureState == .starting,
                recorder.isRecording
            else {
                throw EngineError.backgroundCaptureUnavailable
            }
            let recordingStartedAt = Date()
            guard store.setPhase(
                .recording,
                sessionID: snapshot.sessionID,
                hasRecoverableAudio: true,
                elapsedDuration: 0,
                startedAt: recordingStartedAt
            ) else {
                throw EngineError.sharedStateUnavailable
            }
            await liveActivity.update(
                .recording,
                sessionID: snapshot.sessionID,
                recordingStartedAt: recordingStartedAt
            )
            guard
                sessionID == snapshot.sessionID,
                captureState == .starting
            else {
                throw EngineError.backgroundCaptureUnavailable
            }
            captureState = .recording
        } catch {
            let hasRecoverableAudio = preserveHotCaptureForRecovery()
            if hasRecoverableAudio {
                _ = try? segmentedSessionStore.setLifecycle(
                    .failed,
                    sessionID: snapshot.sessionID
                )
            } else {
                try? segmentedSessionStore.delete(
                    sessionID: snapshot.sessionID
                )
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

    func pause(expectedSessionID: UUID) async throws {
        if sessionID == nil {
            let shared = store.load()
            guard
                shared.sessionID == expectedSessionID,
                shared.phase == .recording
            else {
                return
            }
            _ = try await rehydrateSessionIfNeeded(
                expectedSessionID: expectedSessionID
            )
        }
        guard
            sessionID == expectedSessionID,
            captureState == .recording
        else {
            return
        }
        captureState = .pausing

        do {
            let segment = try finalizeHotSegment(lifecycle: .paused)
            guard beginBackgroundExecutionIfNeeded() else {
                throw EngineError.backgroundTranscriptionUnavailable
            }
            try appendTranscription(
                for: segment,
                sessionID: expectedSessionID
            )
            await liveActivity.update(
                .paused,
                sessionID: expectedSessionID,
                elapsedDuration: accumulatedSegmentDuration
            )
            guard
                sessionID == expectedSessionID,
                captureState == .pausing
            else {
                throw EngineError.backgroundTranscriptionExpired
            }
            guard store.setPhase(
                .paused,
                sessionID: expectedSessionID,
                hasRecoverableAudio: true,
                elapsedDuration: accumulatedSegmentDuration
            ) else {
                throw EngineError.sharedStateUnavailable
            }
            captureState = .paused
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            guard sessionID == expectedSessionID else {
                throw EngineError.backgroundTranscriptionExpired
            }
            await failSession(error, sessionID: expectedSessionID)
            throw error
        }
    }

    func resume(expectedSessionID: UUID) async throws {
        if sessionID == nil {
            let shared = store.load()
            guard
                shared.sessionID == expectedSessionID,
                shared.phase == .paused
            else {
                return
            }
            _ = try await rehydrateSessionIfNeeded(
                expectedSessionID: expectedSessionID
            )
        }
        guard
            sessionID == expectedSessionID,
            captureState == .paused
        else {
            return
        }
        captureState = .resuming

        do {
            try await beginHotSegmentCapture()
            guard
                sessionID == expectedSessionID,
                captureState == .resuming,
                recorder.isRecording
            else {
                _ = preserveHotCaptureForRecovery()
                throw EngineError.backgroundTranscriptionExpired
            }
            // The hot microphone now supplies the supported background
            // runtime. Release the finite assertion that belonged only to the
            // paused segment's eager upload so its later expiration cannot
            // terminate this new capture.
            endBackgroundExecution()
            let recordingStartedAt = Date()
            await liveActivity.update(
                .recording,
                sessionID: expectedSessionID,
                recordingStartedAt: recordingStartedAt,
                elapsedDuration: accumulatedSegmentDuration
            )
            guard
                sessionID == expectedSessionID,
                captureState == .resuming
            else {
                _ = preserveHotCaptureForRecovery()
                throw EngineError.backgroundTranscriptionExpired
            }
            guard store.setPhase(
                .recording,
                sessionID: expectedSessionID,
                hasRecoverableAudio: true,
                elapsedDuration: accumulatedSegmentDuration,
                startedAt: recordingStartedAt
            ) else {
                throw EngineError.sharedStateUnavailable
            }
            captureState = .recording
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            guard sessionID == expectedSessionID else {
                throw EngineError.backgroundTranscriptionExpired
            }
            _ = preserveHotCaptureForRecovery()
            let surfacedError = surfacedCaptureError(error)
            await failSession(surfacedError, sessionID: expectedSessionID)
            throw surfacedError
        }
    }

    func stop() async throws {
        let expectedSessionID = sessionID ?? store.load().sessionID
        try await stop(expectedSessionID: expectedSessionID)
    }

    func stop(expectedSessionID: UUID) async throws {
        if sessionID == nil {
            let shared = store.load()
            guard
                shared.sessionID == expectedSessionID,
                [.recording, .paused].contains(shared.phase)
            else {
                return
            }
            _ = try await rehydrateSessionIfNeeded(
                expectedSessionID: expectedSessionID
            )
        }
        guard
            sessionID == expectedSessionID,
            captureState == .recording || captureState == .paused
        else {
            return
        }
        let stoppedWhileRecording = captureState == .recording
        captureState = .closing
        let attemptID = UUID()
        closingAttemptID = attemptID

        do {
            if stoppedWhileRecording {
                let segment = try finalizeHotSegment(lifecycle: .transcribing)
                // Stop gets a fresh finite assertion. Time spent speaking or on
                // an earlier pause must not consume the final join window.
                guard beginBackgroundExecution() else {
                    throw EngineError.backgroundTranscriptionUnavailable
                }
                try appendTranscription(
                    for: segment,
                    sessionID: expectedSessionID
                )
            } else {
                guard beginBackgroundExecution() else {
                    throw EngineError.backgroundTranscriptionUnavailable
                }
                _ = try segmentedSessionStore.setLifecycle(
                    .transcribing,
                    sessionID: expectedSessionID
                )
            }

            _ = store.releaseCaptureLease(ownerID: expectedSessionID)
            guard store.setPhase(
                .transcribing,
                sessionID: expectedSessionID,
                hasRecoverableAudio: true,
                elapsedDuration: accumulatedSegmentDuration
            ) else {
                throw EngineError.sharedStateUnavailable
            }
            await liveActivity.update(
                .transcribing,
                sessionID: expectedSessionID,
                elapsedDuration: accumulatedSegmentDuration
            )
            guard
                sessionID == expectedSessionID,
                captureState == .closing,
                closingAttemptID == attemptID
            else {
                throw EngineError.backgroundTranscriptionExpired
            }

            var pieces: [SegmentedTranscriptPiece] = []
            var firstFailure: (any Error)?
            for segment in segmentWorks.sorted(by: { $0.ordinal < $1.ordinal }) {
                do {
                    let result = try await segment.transcriptionTask.value
                    pieces.append(
                        SegmentedTranscriptPiece(
                            ordinal: segment.ordinal,
                            text: result.text,
                            languageCode: result.languageCode
                        )
                    )
                } catch {
                    if firstFailure == nil {
                        firstFailure = error
                    }
                }
            }

            guard
                sessionID == expectedSessionID,
                captureState == .closing,
                closingAttemptID == attemptID
            else {
                throw EngineError.backgroundTranscriptionExpired
            }
            if let firstFailure {
                throw firstFailure
            }
            guard let assembly = SegmentedTranscriptAssembler.assemble(pieces) else {
                throw ElevenLabsClientError.emptyTranscript
            }

            let totalDuration = segmentWorks.reduce(0) { partial, segment in
                partial + segment.duration
            }
            let historyPersisted = history.add(
                TranscriptItem(
                    text: assembly.text,
                    languageCode: assembly.languageCode,
                    duration: totalDuration,
                    sourceSessionID: expectedSessionID
                )
            )
            // No more heartbeats may race the keyboard's terminal
            // `.completed -> .inserted` transition in the other process.
            stopHeartbeat()
            guard store.setPhase(
                .completed,
                sessionID: expectedSessionID,
                transcript: assembly.text,
                historyPersisted: historyPersisted,
                hasRecoverableAudio: false,
                elapsedDuration: totalDuration
            ) else {
                throw EngineError.sharedStateUnavailable
            }

            // The transcript is now durable in both fallback History (when its
            // retention policy permits it) and the App Group delivery record.
            // Only this commit authorizes retiring every source segment.
            closingAttemptID = nil
            endBackgroundExecution()
            _ = try? segmentedSessionStore.setLifecycle(
                .completed,
                sessionID: expectedSessionID
            )
            try? consumeAllFinalizedSegmentsAndDeleteManifest(
                sessionID: expectedSessionID
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await liveActivity.end(
                .completed,
                sessionID: expectedSessionID
            )
            finish()
        } catch {
            guard
                sessionID == expectedSessionID,
                captureState == .closing,
                closingAttemptID == attemptID
            else {
                throw EngineError.backgroundTranscriptionExpired
            }
            closingAttemptID = nil
            await failSession(error, sessionID: expectedSessionID)
            throw error
        }
    }

    func cancel() async {
        let expectedSessionID = sessionID ?? store.load().sessionID
        await cancel(expectedSessionID: expectedSessionID)
    }

    func cancel(expectedSessionID: UUID) async {
        if sessionID == nil {
            let shared = store.load()
            guard
                shared.sessionID == expectedSessionID,
                [.recording, .paused].contains(shared.phase)
            else {
                return
            }
            _ = try? await rehydrateSessionIfNeeded(
                expectedSessionID: expectedSessionID
            )
        }
        guard
            sessionID == expectedSessionID,
            captureState == .recording || captureState == .paused
        else {
            return
        }
        captureState = .closing
        let hasRecoverableAudio = preserveHotCaptureForRecovery(
            lifecycle: .cancelled
        )
            || !segmentWorks.isEmpty
        _ = try? segmentedSessionStore.setLifecycle(
            .cancelled,
            sessionID: expectedSessionID
        )
        cancelSegmentTranscriptions()
        _ = store.releaseCaptureLease(ownerID: expectedSessionID)
        stopHeartbeat()
        endBackgroundExecution()
        store.setPhase(
            .cancelled,
            sessionID: expectedSessionID,
            hasRecoverableAudio: hasRecoverableAudio,
            recoveryAction: hasRecoverableAudio ? .openContainingApp : nil
        )
        await liveActivity.end(
            .cancelled,
            sessionID: expectedSessionID
        )
        finish()
    }

    private var language: TranscriptionLanguage {
        defaults.string(forKey: "transcription-language")
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .automatic
    }

    private var cleanSpeech: Bool {
        defaults.object(forKey: "clean-speech") as? Bool ?? true
    }

    private var accumulatedSegmentDuration: TimeInterval {
        segmentWorks.reduce(0) { $0 + $1.duration }
    }

    /// App Intents may be served by a fresh process after a pause released the
    /// microphone. Rebuild only the exact parent named by the shared state or
    /// Live Activity; a stale card can never adopt a newer session.
    private func rehydrateSessionIfNeeded(
        expectedSessionID: UUID
    ) async throws -> Bool {
        guard sessionID == nil, captureState == .idle else { return true }
        if let rehydratingSessionID {
            return rehydratingSessionID == expectedSessionID
        }
        rehydratingSessionID = expectedSessionID
        defer { rehydratingSessionID = nil }
        let shared = store.load()
        guard shared.sessionID == expectedSessionID else { return false }
        guard shared.sessionKind != .keyboardRoundTrip else { return false }
        guard [.starting, .recording, .paused].contains(shared.phase) else {
            return false
        }
        let loadedManifest: SegmentedDictationSessionManifest?
        do {
            loadedManifest = try segmentedSessionStore.load(
                sessionID: expectedSessionID
            )
        } catch {
            guard store.transitionPhase(
                from: [shared.phase],
                to: .failed,
                sessionID: expectedSessionID,
                errorMessage: error.localizedDescription,
                hasRecoverableAudio: true,
                recoveryAction: .openContainingApp
            ) else {
                return false
            }
            _ = store.releaseCaptureLease(ownerID: expectedSessionID)
            await liveActivity.end(.failed, sessionID: expectedSessionID)
            throw error
        }
        guard
            var manifest = loadedManifest,
            [.starting, .recording, .paused]
                .contains(manifest.lifecycle)
        else {
            let staleManifest = try? segmentedSessionStore.load(
                sessionID: expectedSessionID
            )
            let hasRecoverableAudio = staleManifest?.activeCapture != nil
                || staleManifest?.segments.isEmpty == false
            guard store.transitionPhase(
                from: [shared.phase],
                to: .failed,
                sessionID: expectedSessionID,
                errorMessage: hasRecoverableAudio
                    ? "Dictation was interrupted. Open SpeakPaste to recover the recording."
                    : "Dictation stopped before its recovery record was secured. Try again.",
                hasRecoverableAudio: hasRecoverableAudio,
                recoveryAction: hasRecoverableAudio
                    ? .openContainingApp
                    : nil
            ) else {
                return false
            }
            _ = store.releaseCaptureLease(ownerID: expectedSessionID)
            await liveActivity.end(.failed, sessionID: expectedSessionID)
            throw EngineError.sessionRecoveryUnavailable
        }

        let journalEntries: [RecordingJournalEntry]
        do {
            _ = try recordingJournal.adoptCrashLeftCaptures()
            journalEntries = try recordingJournal.recoverableEntries()
            manifest = try segmentedSessionStore.adoptFinalizedActiveCapture(
                sessionID: expectedSessionID,
                from: journalEntries
            )
            if let activeCapture = manifest.activeCapture,
               try recordingJournal.abandonCrashLeftEmptyCapture(
                   id: activeCapture.id
               )
            {
                manifest = try segmentedSessionStore.clearEmptyActiveCapture(
                    sessionID: expectedSessionID,
                    captureID: activeCapture.id,
                    ordinal: activeCapture.ordinal,
                    lifecycle: manifest.segments.isEmpty ? .failed : .paused
                )
            }
        } catch {
            let hasRecoverableAudio = manifest.activeCapture != nil
                || !manifest.segments.isEmpty
            guard store.transitionPhase(
                from: [shared.phase],
                to: .failed,
                sessionID: expectedSessionID,
                errorMessage: error.localizedDescription,
                hasRecoverableAudio: hasRecoverableAudio,
                recoveryAction: hasRecoverableAudio
                    ? .openContainingApp
                    : nil
            ) else {
                return false
            }
            _ = try? segmentedSessionStore.setLifecycle(
                .failed,
                sessionID: expectedSessionID
            )
            _ = store.releaseCaptureLease(ownerID: expectedSessionID)
            await liveActivity.end(.failed, sessionID: expectedSessionID)
            throw error
        }
        guard manifest.activeCapture == nil, !manifest.segments.isEmpty else {
            let hasRecoverableAudio = manifest.activeCapture != nil
                || !manifest.segments.isEmpty
            let publishedFailure = store.transitionPhase(
                from: [shared.phase],
                to: .failed,
                sessionID: expectedSessionID,
                errorMessage: hasRecoverableAudio
                    ? "An interrupted segment is still being secured. Open SpeakPaste to recover it."
                    : "Dictation stopped before any audio was captured. Try again.",
                hasRecoverableAudio: hasRecoverableAudio,
                recoveryAction: hasRecoverableAudio
                    ? .openContainingApp
                    : nil
            )
            if publishedFailure {
                if hasRecoverableAudio {
                    _ = try? segmentedSessionStore.setLifecycle(
                        .failed,
                        sessionID: expectedSessionID
                    )
                } else {
                    try? segmentedSessionStore.delete(
                        sessionID: expectedSessionID
                    )
                }
                _ = store.releaseCaptureLease(ownerID: expectedSessionID)
                await liveActivity.end(.failed, sessionID: expectedSessionID)
            }
            throw EngineError.sessionRecoveryUnavailable
        }
        let group: SegmentedDictationRecoveryGroup
        do {
            group = try segmentedSessionStore.recoveryGroup(
                for: manifest,
                journalEntries: journalEntries
            )
        } catch {
            guard store.transitionPhase(
                from: [shared.phase],
                to: .failed,
                sessionID: expectedSessionID,
                errorMessage: error.localizedDescription,
                hasRecoverableAudio: true,
                recoveryAction: .openContainingApp
            ) else {
                return false
            }
            _ = try? segmentedSessionStore.setLifecycle(
                .failed,
                sessionID: expectedSessionID
            )
            _ = store.releaseCaptureLease(ownerID: expectedSessionID)
            await liveActivity.end(.failed, sessionID: expectedSessionID)
            throw error
        }
        guard beginBackgroundExecutionIfNeeded() else {
            let publishedFailure = store.transitionPhase(
                from: [shared.phase],
                to: .failed,
                sessionID: expectedSessionID,
                errorMessage: EngineError.backgroundTranscriptionUnavailable
                    .localizedDescription,
                hasRecoverableAudio: true,
                recoveryAction: .openContainingApp
            )
            if publishedFailure {
                _ = try? segmentedSessionStore.setLifecycle(
                    .failed,
                    sessionID: expectedSessionID
                )
                _ = store.releaseCaptureLease(ownerID: expectedSessionID)
                await liveActivity.end(.failed, sessionID: expectedSessionID)
            }
            throw EngineError.backgroundTranscriptionUnavailable
        }

        guard store.transitionPhase(
            from: [shared.phase],
            to: .paused,
            sessionID: expectedSessionID,
            hasRecoverableAudio: true,
            elapsedDuration: manifest.orderedSegments.reduce(0) {
                $0 + $1.duration
            }
        ) else {
            endBackgroundExecution()
            return false
        }

        sessionID = expectedSessionID
        captureState = .paused
        segmentWorkGeneration = UUID()
        segmentWorks = []
        pendingSegmentIDs = []
        nextSegmentOrdinal = manifest.nextOrdinal
        _ = store.renewCaptureLease(ownerID: expectedSessionID)
        startHeartbeat(sessionID: expectedSessionID)

        do {
            for (segment, entry) in zip(
                manifest.orderedSegments,
                group.entries
            ) {
                try appendTranscription(
                    for: FinalizedSegment(
                        ordinal: segment.ordinal,
                        entry: entry,
                        audioURL: try recordingJournal.audioURL(for: entry),
                        duration: segment.duration
                    ),
                    sessionID: expectedSessionID
                )
            }
            _ = try segmentedSessionStore.setLifecycle(
                .paused,
                sessionID: expectedSessionID
            )
            await liveActivity.update(
                .paused,
                sessionID: expectedSessionID,
                elapsedDuration: accumulatedSegmentDuration
            )
            return true
        } catch {
            _ = try? segmentedSessionStore.setLifecycle(
                .failed,
                sessionID: expectedSessionID
            )
            store.setPhase(
                .failed,
                sessionID: expectedSessionID,
                errorMessage: error.localizedDescription,
                hasRecoverableAudio: true,
                recoveryAction: .openContainingApp
            )
            await liveActivity.end(.failed, sessionID: expectedSessionID)
            finish()
            throw error
        }
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
                    switch self.captureState {
                    case .starting:
                        await self.liveActivity.refreshStaleness(
                            .starting,
                            sessionID: sessionID
                        )
                    case .recording:
                        await self.liveActivity.refreshStaleness(
                            .recording,
                            sessionID: sessionID
                        )
                    case .idle, .pausing, .paused, .resuming, .closing:
                        break
                    }
                }

                let acceptedCommands: Set<SharedDictationCommand>
                switch self.captureState {
                case .recording:
                    acceptedCommands = [.pause, .stop, .cancel]
                case .paused:
                    acceptedCommands = [.resume, .stop, .cancel]
                case .idle, .starting, .pausing, .resuming, .closing:
                    acceptedCommands = []
                }
                switch self.store.takePendingCommand(
                    sessionID: sessionID,
                    accepting: acceptedCommands
                ) {
                case .pause:
                    Task {
                        try? await self.pause(expectedSessionID: sessionID)
                    }
                case .resume:
                    Task {
                        try? await self.resume(expectedSessionID: sessionID)
                    }
                case .stop:
                    Task {
                        try? await self.stop(expectedSessionID: sessionID)
                    }
                case .cancel:
                    Task {
                        await self.cancel(expectedSessionID: sessionID)
                    }
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
        cancelSegmentTranscriptions()
        closingAttemptID = nil
        sessionID = nil
        captureState = .idle
        recordingURL = nil
        recordingCapture = nil
        recordingJournalEntry = nil
        currentSegmentOrdinal = nil
        segmentWorks = []
        pendingSegmentIDs = []
        nextSegmentOrdinal = 0
        stopHeartbeat()
        endBackgroundExecution()
    }

    private func beginHotSegmentCapture() async throws {
        guard
            let sessionID,
            recordingCapture == nil,
            recordingURL == nil
        else {
            throw AudioRecorderError.alreadyRecording
        }
        let capture = try recordingJournal.beginCapture(id: UUID())
        let ordinal = nextSegmentOrdinal
        do {
            _ = try segmentedSessionStore.setActiveCapture(
                sessionID: sessionID,
                captureID: capture.id,
                ordinal: ordinal,
                lifecycle: .recording
            )
        } catch {
            try? recordingJournal.abandonCapture(capture)
            throw error
        }
        recordingCapture = capture
        currentSegmentOrdinal = ordinal
        recordingURL = try await recorder.start(
            capture: capture,
            in: recordingJournal
        )
    }

    /// Turns the current hot capture into one immutable journal entry. No
    /// transcription owns or deletes the entry; session completion is the only
    /// point that consumes it.
    private func finalizeHotSegment(
        lifecycle: SegmentedDictationSessionManifest.Lifecycle
    ) throws -> FinalizedSegment {
        let duration = recorder.duration
        let finalizedURL = recorder.stop() ?? recordingURL
        guard
            let sessionID,
            let capture = recordingCapture,
            let ordinal = currentSegmentOrdinal
        else {
            throw RecordingJournalError.captureMissing
        }
        guard finalizedURL != nil else {
            throw RecordingJournalError.sourceMissing
        }

        let entry = try recordingJournal.finalizeCapture(
            capture,
            duration: duration
        )
        recordingJournalEntry = entry
        recordingCapture = nil
        let protectedURL = try recordingJournal.audioURL(for: entry)
        recordingURL = protectedURL
        _ = try segmentedSessionStore.appendFinalizedSegment(
            sessionID: sessionID,
            entry: entry,
            ordinal: ordinal,
            lifecycle: lifecycle
        )

        let segment = FinalizedSegment(
            ordinal: ordinal,
            entry: entry,
            audioURL: protectedURL,
            duration: duration
        )
        nextSegmentOrdinal = max(nextSegmentOrdinal, ordinal + 1)
        currentSegmentOrdinal = nil
        return segment
    }

    private func appendTranscription(
        for segment: FinalizedSegment,
        sessionID: UUID
    ) throws {
        guard
            let key = keychain.load()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            throw EngineError.missingAPIKey
        }

        let requestedLanguage = language
        let requestedCleanSpeech = cleanSpeech
        let client = self.client
        let generation = segmentWorkGeneration
        let task = Task {
            try await client.transcribe(
                audioURL: segment.audioURL,
                apiKey: key,
                language: requestedLanguage,
                cleanSpeech: requestedCleanSpeech
            )
        }
        segmentWorks.append(
            SegmentWork(
                ordinal: segment.ordinal,
                entry: segment.entry,
                audioURL: segment.audioURL,
                duration: segment.duration,
                transcriptionTask: task
            )
        )
        if recordingJournalEntry?.id == segment.entry.id {
            recordingJournalEntry = nil
            recordingURL = nil
        }
        pendingSegmentIDs.insert(segment.entry.id)
        Task { @MainActor [weak self] in
            _ = await task.result
            self?.segmentTranscriptionDidFinish(
                segmentID: segment.entry.id,
                sessionID: sessionID,
                generation: generation
            )
        }
    }

    private func segmentTranscriptionDidFinish(
        segmentID: UUID,
        sessionID: UUID,
        generation: UUID
    ) {
        guard
            self.sessionID == sessionID,
            segmentWorkGeneration == generation
        else {
            return
        }
        pendingSegmentIDs.remove(segmentID)
        if pendingSegmentIDs.isEmpty, captureState != .closing {
            endBackgroundExecution()
        }
    }

    /// Makes a stopped or partially started capture recoverable without ever
    /// invoking the journal's destructive discard path.
    @discardableResult
    private func preserveHotCaptureForRecovery(
        lifecycle: SegmentedDictationSessionManifest.Lifecycle = .failed
    ) -> Bool {
        let duration = recorder.duration
        let finalizedURL = recorder.stop() ?? recordingURL

        if let capture = recordingCapture {
            do {
                let entry = try recordingJournal.finalizeCapture(
                    capture,
                    duration: duration
                )
                recordingJournalEntry = entry
                recordingCapture = nil
                recordingURL = try? recordingJournal.audioURL(for: entry)
                if let sessionID, let currentSegmentOrdinal {
                    _ = try segmentedSessionStore.appendFinalizedSegment(
                        sessionID: sessionID,
                        entry: entry,
                        ordinal: currentSegmentOrdinal,
                        lifecycle: lifecycle
                    )
                    nextSegmentOrdinal = max(
                        nextSegmentOrdinal,
                        currentSegmentOrdinal + 1
                    )
                    self.currentSegmentOrdinal = nil
                }
                return true
            } catch RecordingJournalError.emptyRecording {
                if abandonEmptyHotCapture(capture, lifecycle: lifecycle) {
                    return false
                }
                recordingURL = finalizedURL
                return finalizedURL != nil
            } catch {
                // `finalizeCapture` checks writer ownership before it checks
                // whether AVFoundation ever created the destination. A failed
                // audio-session activation therefore reports writer-active
                // even though the durable bundle contains only its JSON
                // reservation. Use the journal's conservative abandon API:
                // it succeeds only when the audio file is absent or zero-byte
                // and refuses every real recording, including very short ones.
                if abandonEmptyHotCapture(capture, lifecycle: lifecycle) {
                    return false
                }
                // A failed durable transition leaves the Active bundle and its
                // audio in the journal for crash adoption.
                recordingURL = finalizedURL
                    ?? (try? recordingJournal.audioURL(for: capture))
                return recordingURL != nil
            }
        }
        if recordingJournalEntry != nil {
            return true
        }
        guard let finalizedURL else { return false }
        do {
            let entry = try recordingJournal.stageRecording(
                at: finalizedURL,
                id: UUID(),
                duration: duration
            )
            recordingJournalEntry = entry
            let protectedURL = try recordingJournal.audioURL(for: entry)
            recordingURL = protectedURL
            if finalizedURL.standardizedFileURL != protectedURL.standardizedFileURL {
                cleanUpRecording(at: finalizedURL)
            }
            return true
        } catch {
            recordingURL = finalizedURL
            return true
        }
    }

    /// Clears only a journal reservation that the journal itself proves has
    /// no audio bytes. This closes failed-start state without weakening the
    /// recovery guarantee for short or partially captured speech.
    private func abandonEmptyHotCapture(
        _ capture: RecordingJournalCapture,
        lifecycle: SegmentedDictationSessionManifest.Lifecycle
    ) -> Bool {
        do {
            try recordingJournal.abandonCapture(capture)
        } catch {
            return false
        }
        if let sessionID, let currentSegmentOrdinal {
            _ = try? segmentedSessionStore.clearEmptyActiveCapture(
                sessionID: sessionID,
                captureID: capture.id,
                ordinal: currentSegmentOrdinal,
                lifecycle: lifecycle
            )
        }
        recordingCapture = nil
        recordingURL = nil
        currentSegmentOrdinal = nil
        return true
    }

    private func consumeAllFinalizedSegmentsAndDeleteManifest(
        sessionID: UUID
    ) throws {
        var firstError: (any Error)?
        for segment in segmentWorks {
            do {
                try recordingJournal.consume(segment.entry)
            } catch RecordingJournalError.recordMissing {
                // A prior cleanup pass already retired this child.
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw firstError
        }
        try segmentedSessionStore.delete(sessionID: sessionID)
    }

    private func cancelSegmentTranscriptions() {
        // Invalidate callbacks before cancellation; an HTTP client may finish
        // concurrently and cancellation is not an acknowledgement barrier.
        segmentWorkGeneration = UUID()
        for segment in segmentWorks {
            segment.transcriptionTask.cancel()
        }
        pendingSegmentIDs.removeAll()
    }

    private func surfacedCaptureError(_ error: any Error) -> any Error {
        if
            case let AudioRecorderError.configurationFailed(stage, _) = error,
            stage == "activation",
            UIApplication.shared.applicationState != .active
        {
            return EngineError.backgroundCaptureUnavailable
        }
        return error
    }

    private func failSession(
        _ error: any Error,
        sessionID: UUID
    ) async {
        let hasRecoverableAudio = preserveHotCaptureForRecovery()
            || !segmentWorks.isEmpty
        _ = try? segmentedSessionStore.setLifecycle(
            .failed,
            sessionID: sessionID
        )
        cancelSegmentTranscriptions()
        _ = store.releaseCaptureLease(ownerID: sessionID)
        stopHeartbeat()
        endBackgroundExecution()
        store.setPhase(
            .failed,
            sessionID: sessionID,
            errorMessage: error.localizedDescription,
            hasRecoverableAudio: hasRecoverableAudio,
            recoveryAction: .openContainingApp
        )
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        await liveActivity.end(.failed, sessionID: sessionID)
        finish()
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
        guard
            shouldFinalize,
            let sessionID,
            captureState == .recording
        else {
            return
        }
        Task { [weak self] in
            try? await self?.stop(expectedSessionID: sessionID)
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

    @discardableResult
    private func beginBackgroundExecutionIfNeeded() -> Bool {
        if backgroundTaskID != .invalid {
            return true
        }
        return beginBackgroundExecution()
    }

    private func expireBackgroundTranscription() {
        guard let sessionID, backgroundTaskID != .invalid else {
            endBackgroundExecution()
            return
        }

        let expiringBackgroundTaskID = backgroundTaskID
        if captureState == .recording || captureState == .resuming {
            // This assertion belonged to eager transcription of an earlier,
            // already-journaled segment. Active audio now owns process runtime;
            // expiring the upload allowance must never stop the new segment.
            endBackgroundExecution(expected: expiringBackgroundTaskID)
            return
        }
        let hasRecoverableAudio = preserveHotCaptureForRecovery()
            || !segmentWorks.isEmpty
            || recordingJournalEntry != nil
        _ = try? segmentedSessionStore.setLifecycle(
            .failed,
            sessionID: sessionID
        )
        cancelSegmentTranscriptions()
        closingAttemptID = nil
        _ = store.releaseCaptureLease(ownerID: sessionID)
        stopHeartbeat()
        store.setPhase(
            .failed,
            sessionID: sessionID,
            errorMessage: EngineError.backgroundTranscriptionExpired.localizedDescription,
            hasRecoverableAudio: hasRecoverableAudio,
            recoveryAction: .openContainingApp
        )
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        self.sessionID = nil
        captureState = .idle
        recordingURL = nil
        recordingCapture = nil
        recordingJournalEntry = nil
        currentSegmentOrdinal = nil
        segmentWorks = []
        pendingSegmentIDs = []
        nextSegmentOrdinal = 0

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
