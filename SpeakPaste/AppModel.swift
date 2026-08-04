import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var transcriptText = ""
    @Published var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    @Published var cleanSpeech: Bool {
        didSet { defaults.set(cleanSpeech, forKey: Keys.cleanSpeech) }
    }
    @Published var autoCopy: Bool {
        didSet { defaults.set(autoCopy, forKey: Keys.autoCopy) }
    }
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var copiedRecently = false
    @Published var needsMicrophoneSettings = false
    @Published var keyboardReturnPrompt: KeyboardReturnPrompt?
    @Published var showSwitchbackExplanation = false
    @Published var showManualReturnHint = false
    @Published private(set) var recordingNotice: String?

    let recorder: AudioRecorder
    let history: HistoryStore

    private let client: ElevenLabsClientProtocol
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let sharedStore: SharedDictationStore
    private let recordingJournal: RecordingJournal
    private var activeRecordingURL: URL?
    private var activeRecordingCapture: RecordingJournalCapture?
    private var activeRecordingJournalEntry: RecordingJournalEntry?
    private var activeRecordingDuration: TimeInterval = 0
    private var activeSharedSessionID: UUID?
    private var activeRecordingSessionID: UUID?
    private var captureLeaseHeldID: UUID?
    private var copiedTask: Task<Void, Never>?
    private var sharedMonitorTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isStartingRecording = false
    private var pendingAutomaticReturnSessionID: UUID?
    private var recorderEventCancellable: AnyCancellable?
    private var recordingNoticeTask: Task<Void, Never>?
    private var captureLeaseHeartbeatTask: Task<Void, Never>?
    private var transcriptionTask: Task<TranscriptionResult, Error>?
    private var transcriptionAttemptID: UUID?

    private enum Keys {
        static let language = "transcription-language"
        static let cleanSpeech = "clean-speech"
        static let autoCopy = "auto-copy"
        static let switchbackExplanationPrefix =
            "did-show-switchback-explanation."
    }

    init(
        client: ElevenLabsClientProtocol = ElevenLabsClient(),
        recorder: AudioRecorder? = nil,
        history: HistoryStore? = nil,
        keychain: KeychainStore = KeychainStore(),
        defaults: UserDefaults = .standard,
        sharedStore: SharedDictationStore = SharedDictationStore(),
        recordingJournal: RecordingJournal = RecordingJournal()
    ) {
        self.client = client
        self.recorder = recorder ?? AudioRecorder()
        self.history = history ?? HistoryStore()
        self.keychain = keychain
        self.defaults = defaults
        self.sharedStore = sharedStore
        self.recordingJournal = recordingJournal

        if
            let rawLanguage = defaults.string(forKey: Keys.language),
            let savedLanguage = TranscriptionLanguage(rawValue: rawLanguage)
        {
            language = savedLanguage
        } else {
            language = .automatic
        }
        cleanSpeech = defaults.object(forKey: Keys.cleanSpeech) as? Bool ?? true
        autoCopy = defaults.object(forKey: Keys.autoCopy) as? Bool ?? true

        recorderEventCancellable = self.recorder.events.sink { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleRecorderEvent(event)
            }
        }
        // Active manifests carry the recorder PID. Adoption skips a live owner,
        // but immediately promotes audio left by a force-quit process.
        _ = try? recordingJournal.adoptCrashLeftCaptures()
        restoreOldestRecoverableRecording()
    }

    var hasAPIKey: Bool {
        guard let key = keychain.load() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isRecording: Bool { phase == .recording }
    var isTranscribing: Bool { phase == .transcribing }
    var isKeyboardDictation: Bool { activeSharedSessionID != nil }
    var canStartRecording: Bool {
        isRecording
            || (!isTranscribing && activeRecordingURL == nil)
    }
    var hasRecoverableRecording: Bool { activeRecordingURL != nil }
    var canAutomaticallyReturnToKeyboardHost: Bool {
        HostAppSwitcher.supportsAutomaticReturn(
            to: keyboardReturnPrompt?.bundleIdentifier
        )
    }
    var manualReturnMessage: String {
        let appName = keyboardReturnPrompt?.appName ?? "your previous app"
        if appName == "your previous app" {
            return "Swipe right along the bottom home bar to return to your app. Recording continues while you switch."
        }
        return "In \(appName), SpeakPaste can’t automatically bring you back. Swipe right along the bottom home bar; recording continues while you switch."
    }

    func toggleRecording() {
        if isRecording {
            stopAndTranscribe()
        } else {
            Task { await startRecording() }
        }
    }

    func startRecording() async {
        await startRecording(for: nil)
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "speakpaste" else { return }

        if url.host == "settings" {
            showSettings = true
            return
        }

        if url.host == "recover" {
            let requestedSessionID = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems?
                .first(where: { $0.name == "session" })?
                .value
                .flatMap(UUID.init(uuidString:))
            let currentSharedSessionID = sharedStore.load().sessionID
            restoreOldestRecoverableRecording(
                preferredSessionID: requestedSessionID == currentSharedSessionID
                    ? requestedSessionID
                    : nil
            )
            if let activeSharedSessionID {
                startSharedCommandMonitor(sessionID: activeSharedSessionID)
            }
            return
        }

        guard url.host == "dictate", url.path == "/start" else { return }
        let snapshot = sharedStore.load()
        guard
            snapshot.phase == .launching || snapshot.phase == .failed,
            Date().timeIntervalSince(snapshot.startedAt) < 30,
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "session" })?
                .value == snapshot.sessionID.uuidString
        else {
            return
        }

        Task { await startRecording(for: snapshot) }
    }

    func handleActivation() {
        history.reload()
        restoreOldestRecoverableRecording()
        let snapshot = sharedStore.load()
        guard
            snapshot.phase == .launching,
            Date().timeIntervalSince(snapshot.updatedAt) < 30,
            !isRecording,
            !isTranscribing,
            !isStartingRecording
        else {
            return
        }
        Task { await startRecording(for: snapshot) }
    }

    func returnToKeyboardHost() {
        guard let prompt = keyboardReturnPrompt else { return }
        sharedStore.setReturnDiagnostics(
            HostAppSwitcher.anticipatedAttempts(
                for: prompt.bundleIdentifier,
                processIdentifier: prompt.processIdentifier
            ),
            sessionID: prompt.id
        )
        Task {
            let outcome = await HostAppSwitcher.open(
                bundleIdentifier: prompt.bundleIdentifier,
                processIdentifier: prompt.processIdentifier,
                onAttemptsChanged: { [sharedStore] attempts in
                    sharedStore.setReturnDiagnostics(
                        attempts,
                        sessionID: prompt.id
                    )
                }
            )
            sharedStore.setReturnDiagnostics(
                outcome.attempts,
                sessionID: prompt.id
            )
            guard
                activeSharedSessionID == prompt.id,
                keyboardReturnPrompt?.id == prompt.id
            else {
                return
            }
            if outcome.didOpen {
                keyboardReturnPrompt = nil
            } else {
                showManualReturnHint = true
            }
        }
    }

    func confirmSwitchbackExplanation() {
        showSwitchbackExplanation = false
        guard let sessionID = pendingAutomaticReturnSessionID else { return }
        pendingAutomaticReturnSessionID = nil
        if
            let prompt = keyboardReturnPrompt,
            prompt.id == sessionID,
            let key = switchbackExplanationKey(
                for: prompt.bundleIdentifier
            )
        {
            defaults.set(true, forKey: key)
        }
        automaticallyReturnToKeyboardHost(sessionID: sessionID)
    }

    private func startRecording(
        for incomingSharedSnapshot: SharedDictationSnapshot?
    ) async {
        guard !isRecording, !isTranscribing, !isStartingRecording else { return }
        guard activeRecordingURL == nil else {
            let message = "An unfinished recording is ready to retry. Transcribe or discard it before starting another dictation."
            phase = .failed(message)
            if let incomingSharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: incomingSharedSnapshot.sessionID,
                    errorMessage: message,
                    hasRecoverableAudio: false,
                    recoveryAction: .openContainingApp
                )
            }
            endBackgroundExecution()
            return
        }
        isStartingRecording = true
        defer { isStartingRecording = false }
        var sharedSnapshot = incomingSharedSnapshot
        if let incomingSharedSnapshot {
            // Claim the launch immediately. Permission sheets are user-paced;
            // leaving this at `.launching` makes the keyboard's open watchdog
            // report a false failure while iOS is still asking for access.
            sharedStore.setPhase(
                .starting,
                sessionID: incomingSharedSnapshot.sessionID
            )
        }
        if var snapshot = sharedSnapshot {
            let capturedPIDAge = Date().timeIntervalSince(snapshot.startedAt)
            let canResolveCapturedPID = (-5 ... 30).contains(capturedPIDAge)
            let resolution = HostAppSwitcher.resolveReturnTarget(
                bundleIdentifier: snapshot.returnBundleIdentifier,
                processIdentifier: canResolveCapturedPID
                    ? snapshot.returnProcessIdentifier
                    : nil
            )
            var diagnostics = resolution.attempts
            if
                snapshot.returnBundleIdentifier == nil,
                snapshot.returnProcessIdentifier != nil,
                !canResolveCapturedPID
            {
                diagnostics.append("return-target-host-pid:stale")
            }
            sharedStore.setReturnDiagnostics(
                diagnostics,
                sessionID: snapshot.sessionID
            )
            if let resolvedBundleIdentifier = resolution.bundleIdentifier {
                snapshot.returnBundleIdentifier = resolvedBundleIdentifier
                sharedStore.setReturnBundleIdentifier(
                    resolvedBundleIdentifier,
                    sessionID: snapshot.sessionID
                )
            }
            sharedSnapshot = snapshot
        }
        guard hasAPIKey else {
            showSettings = true
            let message = "Add your ElevenLabs API key before your first dictation."
            phase = .failed(message)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: message,
                    hasRecoverableAudio: false,
                    recoveryAction: .openContainingApp
                )
                sharedStore.releaseCaptureLease(
                    ownerID: sharedSnapshot.sessionID
                )
            }
            endBackgroundExecution()
            return
        }

        let recordingSessionID = sharedSnapshot?.sessionID ?? UUID()
        let ownsCapture: Bool
        if sharedSnapshot != nil {
            ownsCapture = sharedStore.renewCaptureLease(
                ownerID: recordingSessionID
            )
        } else {
            ownsCapture = sharedStore.acquireCaptureLease(
                ownerID: recordingSessionID
            )
        }
        guard ownsCapture else {
            let message = "Another SpeakPaste recording is already using the microphone. Stop it before starting a new dictation."
            phase = .failed(message)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: message,
                    hasRecoverableAudio: false,
                    recoveryAction: .openContainingApp
                )
            }
            return
        }
        activeRecordingSessionID = recordingSessionID
        captureLeaseHeldID = recordingSessionID
        startCaptureLeaseHeartbeat(ownerID: recordingSessionID)

        let hasPermission = await recorder.requestPermission()
        guard hasPermission else {
            needsMicrophoneSettings = true
            let message = AudioRecorderError.microphoneDenied.localizedDescription
            phase = .failed(message)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: message,
                    hasRecoverableAudio: false,
                    recoveryAction: .openContainingApp
                )
            }
            releaseCaptureLease()
            return
        }

        do {
            let capture = try recordingJournal.beginCapture(
                id: recordingSessionID
            )
            activeRecordingCapture = capture
            activeRecordingURL = try await recorder.start(
                capture: capture,
                in: recordingJournal
            )
            recordingNotice = nil
            phase = .recording
            if let sharedSnapshot {
                activeSharedSessionID = sharedSnapshot.sessionID
                let published = sharedStore.setPhase(
                    .recording,
                    sessionID: sharedSnapshot.sessionID,
                    hasRecoverableAudio: true
                )
                guard published else {
                    activeRecordingDuration = recorder.duration
                    let finalizedURL = recorder.stop() ?? activeRecordingURL
                    releaseCaptureLease()
                    activeRecordingURL = finalizeProtectedRecording(
                        at: finalizedURL,
                        duration: activeRecordingDuration
                    )
                    phase = .failed(
                        "SpeakPaste started recording, but shared storage became unavailable. The audio is saved; retry in SpeakPaste."
                    )
                    return
                }
                startSharedCommandMonitor(sessionID: sharedSnapshot.sessionID)
                keyboardReturnPrompt = KeyboardReturnPrompt(
                    id: sharedSnapshot.sessionID,
                    bundleIdentifier: sharedSnapshot.returnBundleIdentifier,
                    processIdentifier: sharedSnapshot.returnProcessIdentifier,
                    appName: HostAppSwitcher.displayName(
                        for: sharedSnapshot.returnBundleIdentifier
                    )
                )
                showManualReturnHint = false
                if !HostAppSwitcher.supportsAutomaticReturn(
                    to: sharedSnapshot.returnBundleIdentifier
                ) {
                    pendingAutomaticReturnSessionID = nil
                    showManualReturnHint = true
                } else if hasShownSwitchbackExplanation(
                    for: sharedSnapshot.returnBundleIdentifier
                ) {
                    automaticallyReturnToKeyboardHost(
                        sessionID: sharedSnapshot.sessionID
                    )
                } else {
                    pendingAutomaticReturnSessionID = sharedSnapshot.sessionID
                    showSwitchbackExplanation = true
                }
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            var hasRecoverableAudio = false
            if let activeRecordingCapture {
                // `recorder.start` did not return, so capture never became an
                // acknowledged recorder. Usually its empty reservation can be
                // retired; if AVFoundation wrote bytes before failing, preserve
                // and finalize those bytes instead.
                do {
                    try recordingJournal.abandonCapture(activeRecordingCapture)
                    self.activeRecordingCapture = nil
                    activeRecordingURL = nil
                } catch {
                    activeRecordingURL = try? recordingJournal.audioURL(
                        for: activeRecordingCapture
                    )
                    activeRecordingURL = finalizeProtectedRecording(
                        at: activeRecordingURL,
                        duration: recorder.duration
                    )
                    hasRecoverableAudio = activeRecordingURL != nil
                }
            }
            phase = .failed(error.localizedDescription)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: error.localizedDescription,
                    hasRecoverableAudio: hasRecoverableAudio,
                    recoveryAction: .openContainingApp
                )
            }
            releaseCaptureLease()
        }
    }

    private func hasShownSwitchbackExplanation(
        for bundleIdentifier: String?
    ) -> Bool {
        guard let key = switchbackExplanationKey(for: bundleIdentifier) else {
            return false
        }
        return defaults.bool(forKey: key)
    }

    private func switchbackExplanationKey(
        for bundleIdentifier: String?
    ) -> String? {
        guard
            HostAppSwitcher.supportsAutomaticReturn(to: bundleIdentifier),
            let bundleIdentifier
        else {
            return nil
        }
        return Keys.switchbackExplanationPrefix
            + bundleIdentifier.lowercased()
    }

    private func automaticallyReturnToKeyboardHost(sessionID: UUID) {
        Task { [weak self] in
            guard
                let self,
                self.activeSharedSessionID == sessionID,
                let prompt = self.keyboardReturnPrompt,
                prompt.id == sessionID
            else {
                return
            }

            self.sharedStore.setReturnDiagnostics(
                HostAppSwitcher.anticipatedAttempts(
                    for: prompt.bundleIdentifier,
                    processIdentifier: prompt.processIdentifier
                ),
                sessionID: sessionID
            )

            let outcome = await HostAppSwitcher.open(
                bundleIdentifier: prompt.bundleIdentifier,
                processIdentifier: prompt.processIdentifier,
                onAttemptsChanged: { [sharedStore = self.sharedStore] attempts in
                    sharedStore.setReturnDiagnostics(
                        attempts,
                        sessionID: sessionID
                    )
                }
            )
            self.sharedStore.setReturnDiagnostics(
                outcome.attempts,
                sessionID: sessionID
            )
            guard
                self.activeSharedSessionID == sessionID,
                self.keyboardReturnPrompt?.id == sessionID
            else {
                return
            }
            if outcome.didOpen {
                self.keyboardReturnPrompt = nil
            } else {
                self.showManualReturnHint = true
            }
        }
    }

    func stopAndTranscribe() {
        guard isRecording else { return }
        activeRecordingDuration = recorder.duration
        let finalizedURL = recorder.stop() ?? activeRecordingURL
        releaseCaptureLease()
        activeRecordingURL = finalizeProtectedRecording(
            at: finalizedURL,
            duration: activeRecordingDuration
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard beginBackgroundExecution() else {
            surfaceBackgroundTranscriptionUnavailable()
            return
        }
        transcribeActiveRecording()
    }

    func cancelRecording() {
        guard isRecording else { return }
        activeRecordingDuration = recorder.duration
        let finalizedURL = recorder.stop() ?? activeRecordingURL
        releaseCaptureLease()
        activeRecordingURL = finalizeProtectedRecording(
            at: finalizedURL,
            duration: activeRecordingDuration
        )
        let wasKeyboardDictation = activeSharedSessionID != nil
        guard discardActiveRecording() else {
            if let activeSharedSessionID {
                sharedStore.setPhase(
                    .failed,
                    sessionID: activeSharedSessionID,
                    errorMessage: "SpeakPaste couldn't discard the recording. Retry or discard it again.",
                    hasRecoverableAudio: true,
                    recoveryAction: .openContainingApp
                )
            }
            return
        }
        if let activeSharedSessionID {
            sharedStore.setPhase(.cancelled, sessionID: activeSharedSessionID)
        }
        finishSharedSession(keepSharedResult: wasKeyboardDictation)
        phase = .idle
    }

    func retry() {
        guard activeRecordingURL != nil else { return }
        guard beginBackgroundExecution() else {
            surfaceBackgroundTranscriptionUnavailable()
            return
        }
        transcribeActiveRecording()
    }

    func retryAfterError() {
        if activeRecordingURL != nil {
            retry()
        } else {
            phase = .idle
            Task { await startRecording() }
        }
    }

    func discardRecoverableRecording() {
        guard activeRecordingURL != nil else { return }
        let sharedSessionID = activeSharedSessionID
        guard discardActiveRecording() else { return }
        if let sharedSessionID {
            sharedStore.markHandled(sessionID: sharedSessionID)
        }
        finishSharedSession(keepSharedResult: true)
        recordingNotice = nil
        phase = .idle
    }

    func saveAPIKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try keychain.delete()
        } else {
            try keychain.save(key)
        }
        objectWillChange.send()
    }

    func deleteAPIKey() throws {
        try keychain.delete()
        objectWillChange.send()
    }

    func copyTranscript() {
        let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showCopiedConfirmation()
    }

    func clearTranscript() {
        transcriptText = ""
        phase = .idle
    }

    func useHistoryItem(_ item: TranscriptItem) {
        acknowledgePendingTranscript(for: item)
        transcriptText = item.text
        phase = .idle
        showHistory = false
    }

    func copyHistoryItem(_ item: TranscriptItem) {
        UIPasteboard.general.string = item.text
        acknowledgePendingTranscript(for: item)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func deleteHistoryItem(_ item: TranscriptItem) {
        acknowledgePendingTranscript(for: item)
        history.delete(id: item.id)
    }

    func clearHistory() {
        let pending = sharedStore.load()
        if [.completed, .inserting, .deliveryBlocked].contains(pending.phase) {
            sharedStore.markHandled(sessionID: pending.sessionID)
        }
        history.clear()
    }

    private func acknowledgePendingTranscript(for item: TranscriptItem) {
        let pending = sharedStore.load()
        guard [.completed, .inserting, .deliveryBlocked].contains(pending.phase) else {
            return
        }

        let matchesPendingSession: Bool
        if let sourceSessionID = item.sourceSessionID {
            matchesPendingSession = sourceSessionID == pending.sessionID
        } else {
            // Compatibility for on-device history written before session IDs
            // were stored with background transcripts. If a tagged row exists,
            // an older duplicate must never acknowledge it. For a genuinely
            // legacy pending session, only its newest time-correlated row wins.
            let hasTaggedPendingItem = history.items.contains {
                $0.sourceSessionID == pending.sessionID
            }
            let pendingText = pending.transcript?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyPendingItem = history.items
                .filter {
                    $0.sourceSessionID == nil
                        && $0.createdAt
                            >= pending.startedAt.addingTimeInterval(-1)
                        && $0.text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ) == pendingText
                }
                .max { $0.createdAt < $1.createdAt }
            matchesPendingSession = !hasTaggedPendingItem
                && legacyPendingItem?.id == item.id
        }
        guard matchesPendingSession else { return }
        sharedStore.markHandled(sessionID: pending.sessionID)
    }

    func dismissError() {
        guard activeRecordingURL == nil else { return }
        if case .failed = phase {
            phase = .idle
        }
    }

    private func transcribeActiveRecording() {
        guard
            let audioURL = activeRecordingURL,
            let apiKey = keychain.load(),
            !apiKey.isEmpty
        else {
            let message = "The recording or ElevenLabs API key is missing."
            phase = .failed(message)
            if let activeSharedSessionID {
                sharedStore.setPhase(
                    .failed,
                    sessionID: activeSharedSessionID,
                    errorMessage: message,
                    hasRecoverableAudio: true,
                    recoveryAction: .openContainingApp
                )
            }
            endBackgroundExecution()
            return
        }

        guard transcriptionAttemptID == nil else { return }
        let attemptID = UUID()
        transcriptionAttemptID = attemptID
        phase = .transcribing
        if let activeSharedSessionID {
            sharedStore.setPhase(.transcribing, sessionID: activeSharedSessionID)
        }
        let selectedLanguage = language
        let shouldCleanSpeech = cleanSpeech
        let duration = activeRecordingDuration
        let historySourceSessionID = activeSharedSessionID
            ?? activeRecordingSessionID
            ?? activeRecordingJournalEntry?.id

        let request = Task {
            try await client.transcribe(
                audioURL: audioURL,
                apiKey: apiKey,
                language: selectedLanguage,
                cleanSpeech: shouldCleanSpeech
            )
        }
        transcriptionTask = request

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await request.value
                guard self.transcriptionAttemptID == attemptID else { return }
                self.transcriptionTask = nil
                self.transcriptText = result.text
                let historyPersisted = self.history.add(
                    TranscriptItem(
                        text: result.text,
                        languageCode: result.languageCode,
                        duration: duration,
                        sourceSessionID: historySourceSessionID
                    )
                )
                if let activeSharedSessionID = self.activeSharedSessionID {
                    let published = self.sharedStore.setPhase(
                        .completed,
                        sessionID: activeSharedSessionID,
                        transcript: result.text,
                        historyPersisted: historyPersisted
                    )
                    guard published else {
                        self.transcriptionAttemptID = nil
                        self.phase = .failed(
                            "The transcript finished, but SpeakPaste couldn't deliver it to the keyboard. The recording is saved; retry when storage is available."
                        )
                        self.endBackgroundExecution()
                        self.sharedMonitorTask?.cancel()
                        self.sharedMonitorTask = nil
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        return
                    }
                }
                self.transcriptionAttemptID = nil
                self.phase = .idle
                // Keyboard delivery goes straight to the original field. Also
                // writing the pasteboard leaks dictated text and produces a
                // surprising second side effect.
                if self.autoCopy && self.activeSharedSessionID == nil {
                    self.copyTranscript()
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                self.consumeActiveRecording()
                self.finishSharedSession(keepSharedResult: true)
            } catch {
                guard self.transcriptionAttemptID == attemptID else { return }
                self.transcriptionTask = nil
                self.transcriptionAttemptID = nil
                self.phase = .failed(error.localizedDescription)
                if let activeSharedSessionID = self.activeSharedSessionID {
                    self.sharedStore.setPhase(
                        .failed,
                        sessionID: activeSharedSessionID,
                        errorMessage: error.localizedDescription,
                        hasRecoverableAudio: true,
                        recoveryAction: self.sharedRecoveryAction(for: error)
                    )
                }
                self.endBackgroundExecution()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func startSharedCommandMonitor(sessionID: UUID) {
        sharedMonitorTask?.cancel()
        sharedMonitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, self.activeSharedSessionID == sessionID else { return }

                // Heartbeat so the keyboard can tell a live dictation from one
                // this process no longer owns. Without it a killed app leaves
                // the keyboard showing Listening with no way back.
                tick += 1
                if tick.isMultiple(of: 25) {
                    self.sharedStore.touch(sessionID: sessionID)
                }

                guard self.sharedStore.load().sessionID == sessionID else {
                    continue
                }

                let acceptedCommands: Set<SharedDictationCommand>
                if self.isRecording {
                    acceptedCommands = [.stop, .cancel]
                } else if case .failed = self.phase,
                          self.activeRecordingURL != nil {
                    acceptedCommands = [.retry]
                } else {
                    acceptedCommands = []
                }

                switch self.sharedStore.takePendingCommand(
                    sessionID: sessionID,
                    accepting: acceptedCommands
                ) {
                case .stop where self.isRecording:
                    self.stopAndTranscribe()
                case .cancel where self.isRecording:
                    self.cancelRecording()
                    return
                case .retry where self.activeRecordingURL != nil
                    && !self.isTranscribing:
                    self.sharedStore.setPhase(.transcribing, sessionID: sessionID)
                    self.retry()
                default:
                    break
                }
            }
        }
    }

    private func sharedRecoveryAction(
        for error: Error
    ) -> SharedDictationRecoveryAction {
        if let clientError = error as? ElevenLabsClientError,
           clientError.isRetryable
        {
            return .retryTranscription
        }
        return .openContainingApp
    }

    private func startCaptureLeaseHeartbeat(ownerID: UUID) {
        captureLeaseHeartbeatTask?.cancel()
        captureLeaseHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard
                    let self,
                    self.captureLeaseHeldID == ownerID,
                    self.isRecording || self.isStartingRecording
                else {
                    return
                }
                _ = self.sharedStore.renewCaptureLease(ownerID: ownerID)
            }
        }
    }

    private func releaseCaptureLease() {
        captureLeaseHeartbeatTask?.cancel()
        captureLeaseHeartbeatTask = nil
        guard let captureLeaseHeldID else { return }
        _ = sharedStore.releaseCaptureLease(ownerID: captureLeaseHeldID)
        self.captureLeaseHeldID = nil
    }

    private func finishSharedSession(keepSharedResult: Bool = false) {
        let completedSessionID = activeSharedSessionID
        sharedMonitorTask?.cancel()
        sharedMonitorTask = nil
        activeSharedSessionID = nil
        activeRecordingSessionID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionAttemptID = nil
        releaseCaptureLease()
        pendingAutomaticReturnSessionID = nil
        showSwitchbackExplanation = false
        if !keepSharedResult, let completedSessionID {
            sharedStore.reset(sessionID: completedSessionID)
        }
        endBackgroundExecution()
    }

    @discardableResult
    private func beginBackgroundExecution() -> Bool {
        endBackgroundExecution()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "Finish ElevenLabs transcription"
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.expireBackgroundTranscription()
            }
        }
        return backgroundTaskID != .invalid
    }

    private func surfaceBackgroundTranscriptionUnavailable() {
        let message = "iOS couldn't reserve enough background time to transcribe. The recording is saved; retry in SpeakPaste."
        phase = .failed(message)
        if let activeSharedSessionID {
            _ = sharedStore.setPhase(
                .failed,
                sessionID: activeSharedSessionID,
                errorMessage: message,
                hasRecoverableAudio: true,
                recoveryAction: .retryTranscription
            )
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func expireBackgroundTranscription() {
        guard transcriptionAttemptID != nil else {
            endBackgroundExecution()
            return
        }

        let expiringTaskID = backgroundTaskID
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionAttemptID = nil
        let message = "iOS ended the background transcription window. The recording is saved; retry in SpeakPaste."
        phase = .failed(message)
        if let activeSharedSessionID {
            _ = sharedStore.setPhase(
                .failed,
                sessionID: activeSharedSessionID,
                errorMessage: message,
                hasRecoverableAudio: true,
                recoveryAction: .retryTranscription
            )
        }
        sharedMonitorTask?.cancel()
        sharedMonitorTask = nil
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        endBackgroundExecution(expected: expiringTaskID)
    }

    private func endBackgroundExecution(
        expected taskID: UIBackgroundTaskIdentifier? = nil
    ) {
        if let taskID, backgroundTaskID != taskID { return }
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func finalizeProtectedRecording(
        at finalizedURL: URL?,
        duration: TimeInterval
    ) -> URL? {
        guard let finalizedURL else { return nil }
        if let activeRecordingCapture {
            do {
                let entry = try recordingJournal.finalizeCapture(
                    activeRecordingCapture,
                    duration: duration
                )
                let protectedURL = try recordingJournal.audioURL(for: entry)
                activeRecordingJournalEntry = entry
                self.activeRecordingCapture = nil
                return protectedURL
            } catch {
                // This URL already lives in the journal's private Active area.
                // Keep it and its capture token so relaunch adoption can retry.
                showRecordingNotice(
                    "The recovery recording is safe, but its index could not be finalized yet. Keep SpeakPaste open while it retries."
                )
                return finalizedURL
            }
        }
        if activeRecordingJournalEntry != nil {
            return activeRecordingURL ?? finalizedURL
        }

        do {
            let entry = try recordingJournal.stageRecording(
                at: finalizedURL,
                id: activeRecordingSessionID ?? activeSharedSessionID ?? UUID(),
                duration: duration
            )
            let protectedURL = try recordingJournal.audioURL(for: entry)
            activeRecordingJournalEntry = entry
            if finalizedURL.standardizedFileURL != protectedURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: finalizedURL)
            }
            return protectedURL
        } catch {
            showRecordingNotice(
                "SpeakPaste couldn't create its recovery copy. Keep the app open while this recording transcribes."
            )
            return finalizedURL
        }
    }

    private func consumeActiveRecording() {
        if let activeRecordingCapture {
            if let entry = try? recordingJournal.finalizeCapture(
                activeRecordingCapture,
                duration: activeRecordingDuration
            ) {
                try? recordingJournal.consume(entry)
            }
        } else if let activeRecordingJournalEntry {
            try? recordingJournal.consume(activeRecordingJournalEntry)
        } else if let activeRecordingURL {
            try? FileManager.default.removeItem(at: activeRecordingURL)
        }
        clearActiveRecordingReference()
    }

    @discardableResult
    private func discardActiveRecording() -> Bool {
        do {
            if let activeRecordingCapture {
                let entry = try recordingJournal.finalizeCapture(
                    activeRecordingCapture,
                    duration: activeRecordingDuration
                )
                try recordingJournal.discard(entry)
            } else if let activeRecordingJournalEntry {
                try recordingJournal.discard(activeRecordingJournalEntry)
            } else if let activeRecordingURL {
                try FileManager.default.removeItem(at: activeRecordingURL)
            }
        } catch {
            phase = .failed(
                "SpeakPaste couldn't discard the recovery recording: \(error.localizedDescription)"
            )
            return false
        }
        clearActiveRecordingReference()
        return true
    }

    private func clearActiveRecordingReference() {
        activeRecordingURL = nil
        activeRecordingCapture = nil
        activeRecordingJournalEntry = nil
        activeRecordingDuration = 0
    }

    private func restoreOldestRecoverableRecording(
        preferredSessionID: UUID? = nil
    ) {
        if
            let preferredSessionID,
            activeRecordingURL != nil,
            activeRecordingSessionID != preferredSessionID,
            activeSharedSessionID == nil,
            !isRecording,
            !isTranscribing
        {
            // The existing recovery bundle stays in the journal. A targeted
            // keyboard Retry may safely put its own session in front without
            // deleting or consuming the older standalone recording.
            clearActiveRecordingReference()
            activeRecordingSessionID = nil
        }
        guard
            activeRecordingURL == nil,
            !isRecording,
            !isTranscribing
        else {
            return
        }
        // A stopped recorder may have persisted writer-release proof but lost
        // the final Active -> Entries rename. Adoption is safe to repeat: it
        // refuses live writers and makes an existing scene recover immediately.
        _ = try? recordingJournal.adoptCrashLeftCaptures()
        guard let entries = try? recordingJournal.recoverableEntries() else {
            return
        }

        let shared = sharedStore.load()
        if
            [.starting, .recording, .transcribing].contains(shared.phase),
            Date().timeIntervalSince(shared.updatedAt) < 15
        {
            // A background engine currently owns recording/transcription. Do
            // not surface any journal entry beneath its live work.
            return
        }
        let orderedEntries: [RecordingJournalEntry]
        if let preferredSessionID,
           let preferred = entries.first(where: { $0.id == preferredSessionID })
        {
            orderedEntries = [preferred] + entries.filter {
                $0.id != preferredSessionID
            }
        } else {
            orderedEntries = entries
        }
        for entry in orderedEntries {
            if let committed = history.items.first(where: {
                $0.sourceSessionID == entry.id
            }) {
                if shared.sessionID == entry.id,
                   [.recording, .transcribing, .failed].contains(shared.phase)
                {
                    sharedStore.setPhase(
                        .completed,
                        sessionID: entry.id,
                        transcript: committed.text,
                        historyPersisted: true
                    )
                }
                try? recordingJournal.consume(entry)
                continue
            }
            if shared.sessionID == entry.id,
               [.completed, .inserting, .deliveryBlocked, .inserted, .handled]
                    .contains(shared.phase)
            {
                try? recordingJournal.consume(entry)
                continue
            }
            guard let url = try? recordingJournal.audioURL(for: entry) else {
                continue
            }

            activeRecordingJournalEntry = entry
            activeRecordingURL = url
            activeRecordingDuration = entry.duration
            activeRecordingSessionID = entry.id
            if shared.sessionID == entry.id {
                activeSharedSessionID = entry.id
                sharedStore.setPhase(
                    .failed,
                    sessionID: entry.id,
                    errorMessage: "An interrupted recording was recovered. Retry transcription or discard the audio.",
                    hasRecoverableAudio: true,
                    recoveryAction: .retryTranscription
                )
                startSharedCommandMonitor(sessionID: entry.id)
            }
            phase = .failed(
                "An interrupted recording was recovered. Retry transcription or discard the audio."
            )
            return
        }
    }

    private func handleRecorderEvent(_ event: AudioRecorderEvent) {
        switch event {
        case let .noAudioDetected(elapsed):
            showRecordingNotice(
                "No voice detected after \(Int(elapsed)) seconds. Check the microphone and speak a little closer."
            )
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case let .maximumDurationApproaching(remaining):
            showRecordingNotice(
                "\(Int(remaining.rounded())) seconds remaining. SpeakPaste will stop and transcribe automatically."
            )
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case let .maximumDurationReached(finalizedURL):
            finalizeRecordingAfterSystemStop(
                finalizedURL,
                notice: "Five-minute limit reached. Transcribing now."
            )
        case let .interruptionBegan(finalizedURL):
            finalizeRecordingAfterSystemStop(
                finalizedURL,
                notice: "Recording was interrupted. Transcribing what was captured."
            )
        case let .routeChanged(change):
            if let finalizedURL = change.finalizedRecordingURL {
                finalizeRecordingAfterSystemStop(
                    finalizedURL,
                    notice: "The microphone disconnected. Transcribing what was captured."
                )
            } else if change.hasUsableInput {
                showRecordingNotice("Microphone route changed. Recording continues.")
            }
        case let .recordingEndedUnexpectedly(finalizedURL):
            finalizeRecordingAfterSystemStop(
                finalizedURL,
                notice: "Recording stopped unexpectedly. Transcribing what was captured."
            )
        case .interruptionEnded:
            break
        }
    }

    private func finalizeRecordingAfterSystemStop(
        _ finalizedURL: URL?,
        notice: String
    ) {
        guard isRecording else { return }
        recordingNoticeTask?.cancel()
        recordingNotice = notice
        activeRecordingDuration = recorder.duration
        releaseCaptureLease()
        activeRecordingURL = finalizeProtectedRecording(
            at: finalizedURL ?? activeRecordingURL,
            duration: activeRecordingDuration
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard beginBackgroundExecution() else {
            surfaceBackgroundTranscriptionUnavailable()
            return
        }
        transcribeActiveRecording()
    }

    private func showRecordingNotice(_ message: String) {
        recordingNoticeTask?.cancel()
        recordingNotice = message
        recordingNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.recordingNotice = nil
        }
    }

    private func showCopiedConfirmation() {
        copiedTask?.cancel()
        copiedRecently = true
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copiedRecently = false
        }
    }
}
