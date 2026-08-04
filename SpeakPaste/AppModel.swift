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

    let recorder: AudioRecorder
    let history: HistoryStore

    private let client: ElevenLabsClientProtocol
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let sharedStore: SharedDictationStore
    private var activeRecordingURL: URL?
    private var activeRecordingDuration: TimeInterval = 0
    private var activeSharedSessionID: UUID?
    private var copiedTask: Task<Void, Never>?
    private var sharedMonitorTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isStartingRecording = false
    private var pendingAutomaticReturnSessionID: UUID?

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
        sharedStore: SharedDictationStore = SharedDictationStore()
    ) {
        self.client = client
        self.recorder = recorder ?? AudioRecorder()
        self.history = history ?? HistoryStore()
        self.keychain = keychain
        self.defaults = defaults
        self.sharedStore = sharedStore

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
    }

    var hasAPIKey: Bool {
        guard let key = keychain.load() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isRecording: Bool { phase == .recording }
    var isTranscribing: Bool { phase == .transcribing }
    var isKeyboardDictation: Bool { activeSharedSessionID != nil }
    var canStartRecording: Bool { !isTranscribing }
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
        isStartingRecording = true
        defer { isStartingRecording = false }
        var sharedSnapshot = incomingSharedSnapshot
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
                    errorMessage: message
                )
            }
            return
        }

        let hasPermission = await recorder.requestPermission()
        guard hasPermission else {
            needsMicrophoneSettings = true
            let message = AudioRecorderError.microphoneDenied.localizedDescription
            phase = .failed(message)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: message
                )
            }
            return
        }

        deleteActiveRecording()
        do {
            activeRecordingURL = try await recorder.start()
            phase = .recording
            if let sharedSnapshot {
                activeSharedSessionID = sharedSnapshot.sessionID
                sharedStore.setPhase(.recording, sessionID: sharedSnapshot.sessionID)
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
            phase = .failed(error.localizedDescription)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: error.localizedDescription
                )
            }
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
        activeRecordingURL = recorder.stop() ?? activeRecordingURL
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        beginBackgroundExecution()
        transcribeActiveRecording()
    }

    func cancelRecording() {
        guard isRecording else { return }
        recorder.stop()
        let wasKeyboardDictation = activeSharedSessionID != nil
        if let activeSharedSessionID {
            sharedStore.setPhase(.cancelled, sessionID: activeSharedSessionID)
        }
        finishSharedSession(keepSharedResult: wasKeyboardDictation)
        deleteActiveRecording()
        phase = .idle
    }

    func retry() {
        guard activeRecordingURL != nil else { return }
        beginBackgroundExecution()
        transcribeActiveRecording()
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
        if pending.phase == .completed {
            sharedStore.markHandled(sessionID: pending.sessionID)
        }
        history.clear()
    }

    private func acknowledgePendingTranscript(for item: TranscriptItem) {
        let pending = sharedStore.load()
        guard pending.phase == .completed else { return }

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
            phase = .failed("The recording or ElevenLabs API key is missing.")
            return
        }

        phase = .transcribing
        if let activeSharedSessionID {
            sharedStore.setPhase(.transcribing, sessionID: activeSharedSessionID)
        }
        let selectedLanguage = language
        let shouldCleanSpeech = cleanSpeech
        let duration = activeRecordingDuration

        Task {
            do {
                let result = try await client.transcribe(
                    audioURL: audioURL,
                    apiKey: apiKey,
                    language: selectedLanguage,
                    cleanSpeech: shouldCleanSpeech
                )
                transcriptText = result.text
                history.add(
                    TranscriptItem(
                        text: result.text,
                        languageCode: result.languageCode,
                        duration: duration,
                        sourceSessionID: activeSharedSessionID
                    )
                )
                if let activeSharedSessionID {
                    sharedStore.setPhase(
                        .completed,
                        sessionID: activeSharedSessionID,
                        transcript: result.text
                    )
                }
                phase = .idle
                if autoCopy {
                    copyTranscript()
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                deleteActiveRecording()
                finishSharedSession(keepSharedResult: true)
            } catch {
                phase = .failed(error.localizedDescription)
                if let activeSharedSessionID {
                    sharedStore.setPhase(
                        .failed,
                        sessionID: activeSharedSessionID,
                        errorMessage: error.localizedDescription
                    )
                }
                endBackgroundExecution()
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

                let snapshot = self.sharedStore.load()
                guard snapshot.sessionID == sessionID else { continue }

                switch snapshot.command {
                case .stop where self.isRecording:
                    self.stopAndTranscribe()
                case .cancel where self.isRecording:
                    self.cancelRecording()
                    return
                case .retry:
                    self.sharedStore.setPhase(.transcribing, sessionID: sessionID)
                    self.retry()
                default:
                    break
                }
            }
        }
    }

    private func finishSharedSession(keepSharedResult: Bool = false) {
        sharedMonitorTask?.cancel()
        sharedMonitorTask = nil
        activeSharedSessionID = nil
        pendingAutomaticReturnSessionID = nil
        showSwitchbackExplanation = false
        if !keepSharedResult {
            sharedStore.reset()
        }
        endBackgroundExecution()
    }

    private func beginBackgroundExecution() {
        endBackgroundExecution()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "Finish ElevenLabs transcription"
        ) { [weak self] in
            Task { @MainActor in
                self?.endBackgroundExecution()
            }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func deleteActiveRecording() {
        if let activeRecordingURL {
            try? FileManager.default.removeItem(at: activeRecordingURL)
        }
        activeRecordingURL = nil
        activeRecordingDuration = 0
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
