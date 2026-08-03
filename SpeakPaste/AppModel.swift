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
        static let didShowSwitchbackExplanation = "did-show-switchback-explanation"
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
    var canStartRecording: Bool { !isTranscribing }

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
            HostAppSwitcher.anticipatedAttempts(for: prompt.bundleIdentifier),
            sessionID: prompt.id
        )
        Task {
            let outcome = await HostAppSwitcher.open(
                bundleIdentifier: prompt.bundleIdentifier,
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
        defaults.set(true, forKey: Keys.didShowSwitchbackExplanation)
        showSwitchbackExplanation = false
        guard let sessionID = pendingAutomaticReturnSessionID else { return }
        pendingAutomaticReturnSessionID = nil
        automaticallyReturnToKeyboardHost(sessionID: sessionID)
    }

    private func startRecording(for sharedSnapshot: SharedDictationSnapshot?) async {
        guard !isRecording, !isTranscribing, !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
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
            activeRecordingURL = try recorder.start()
            phase = .recording
            if let sharedSnapshot {
                activeSharedSessionID = sharedSnapshot.sessionID
                sharedStore.setPhase(.recording, sessionID: sharedSnapshot.sessionID)
                startSharedCommandMonitor(sessionID: sharedSnapshot.sessionID)
                keyboardReturnPrompt = KeyboardReturnPrompt(
                    id: sharedSnapshot.sessionID,
                    bundleIdentifier: sharedSnapshot.returnBundleIdentifier,
                    appName: HostAppSwitcher.displayName(
                        for: sharedSnapshot.returnBundleIdentifier
                    )
                )
                if defaults.bool(forKey: Keys.didShowSwitchbackExplanation) {
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
                    for: prompt.bundleIdentifier
                ),
                sessionID: sessionID
            )

            let outcome = await HostAppSwitcher.open(
                bundleIdentifier: prompt.bundleIdentifier,
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
        if let activeSharedSessionID {
            sharedStore.setPhase(.cancelled, sessionID: activeSharedSessionID)
        }
        finishSharedSession()
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
            keychain.delete()
        } else {
            try keychain.save(key)
        }
        objectWillChange.send()
    }

    func deleteAPIKey() {
        keychain.delete()
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
        transcriptText = item.text
        phase = .idle
        showHistory = false
    }

    func deleteHistoryItem(_ item: TranscriptItem) {
        history.delete(id: item.id)
    }

    func clearHistory() {
        history.clear()
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
                        duration: duration
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
