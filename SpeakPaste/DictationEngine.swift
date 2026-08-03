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
        /// iOS refuses to activate a recording session for an app that is not
        /// already running one. Only the call-management frameworks (CallKit,
        /// LiveCommunicationKit, PushToTalk) may start capture from a cold
        /// background launch, so the intent has to continue in the foreground.
        case backgroundCaptureUnavailable

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Add your ElevenLabs API key in SpeakPaste before dictating."
            case .microphoneDenied:
                "Microphone access is off. Enable it for SpeakPaste in Settings."
            case .backgroundCaptureUnavailable:
                "iOS will not start the microphone while SpeakPaste is in the background."
            }
        }
    }

    private let recorder = AudioRecorder()
    private let store = SharedDictationStore()
    private let keychain = KeychainStore()
    private let client: ElevenLabsClientProtocol
    private let defaults: UserDefaults
    private let history = HistoryStore()

    private var sessionID: UUID?
    private var recordingURL: URL?
    private var heartbeatTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let keepAlive = BackgroundAudioKeepAlive()

    private enum KeepAliveKeys {
        static let enabled = "keep-alive-enabled"
        static let mode = "keep-alive-mode"
    }

    var isArmed: Bool { keepAlive.isArmed }

    var keepAliveEnabled: Bool {
        get { defaults.object(forKey: KeepAliveKeys.enabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: KeepAliveKeys.enabled)
            if newValue {
                arm()
            } else {
                keepAlive.disarm()
            }
        }
    }

    /// Arm from the foreground. Every later Back Tap then starts capture on a
    /// session that is already live, which is the only way iOS permits it.
    func arm() {
        guard keepAliveEnabled, !isRecording else { return }
        let stored = defaults.string(forKey: KeepAliveKeys.mode)
            .flatMap(BackgroundAudioKeepAlive.Mode.init(rawValue:))
        let mode = stored ?? .playbackOnly
        var failure: String?
        do {
            try keepAlive.arm(mode: mode)
        } catch {
            failure = error.localizedDescription
        }
        recordKeepAliveState(mode: mode, failure: failure)
    }

    /// Arming decides whether Back Tap works at all, and it happens with no UI
    /// on screen. Persist the outcome so it can be inspected afterwards rather
    /// than inferred from a failed gesture.
    private func recordKeepAliveState(
        mode: BackgroundAudioKeepAlive.Mode,
        failure: String?
    ) {
        guard
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else {
            return
        }
        let report: [String: Any] = [
            "armed": keepAlive.isArmed,
            "requestedMode": mode.rawValue,
            "activeMode": keepAlive.mode?.rawValue ?? "none",
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "failure": failure ?? "none",
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return
        }
        try? data.write(
            to: directory.appendingPathComponent("keepalive-state.json"),
            options: .atomic
        )
    }

    init(
        client: ElevenLabsClientProtocol = ElevenLabsClient(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
    }

    var isRecording: Bool { sessionID != nil && recorder.isRecording }

    /// One gesture for the whole round trip, so a single Back Tap binding both
    /// starts and finishes a dictation.
    @discardableResult
    func toggle() async throws -> String? {
        if isRecording {
            return try await stop()
        }
        try await start()
        return nil
    }

    func start() async throws {
        guard !isRecording else { return }

        guard
            let key = keychain.load()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            throw EngineError.missingAPIKey
        }
        guard await recorder.requestPermission() else {
            throw EngineError.microphoneDenied
        }

        let snapshot = store.beginBackgroundSession()
        sessionID = snapshot.sessionID
        do {
            recordingURL = try beginCapture()
        } catch {
            store.setPhase(
                .failed,
                sessionID: snapshot.sessionID,
                errorMessage: error.localizedDescription
            )
            sessionID = nil
            if
                case let AudioRecorderError.configurationFailed(stage, _) = error,
                stage == "activation",
                UIApplication.shared.applicationState != .active
            {
                throw EngineError.backgroundCaptureUnavailable
            }
            throw error
        }

        // iOS suspends the app the moment the intent returns unless the audio
        // session keeps it alive; the background task covers the transcription
        // request that follows.
        beginBackgroundExecution()
        startHeartbeat(sessionID: snapshot.sessionID)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @discardableResult
    func stop() async throws -> String? {
        guard let sessionID else { return nil }
        let audioURL = recorder.stop(deactivatesSession: !keepAlive.isArmed) ?? recordingURL
        let duration = recorder.duration
        stopHeartbeat()

        guard
            let audioURL,
            let key = keychain.load()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            store.setPhase(
                .failed,
                sessionID: sessionID,
                errorMessage: EngineError.missingAPIKey.localizedDescription
            )
            finish()
            throw EngineError.missingAPIKey
        }

        store.setPhase(.transcribing, sessionID: sessionID)
        do {
            let result = try await client.transcribe(
                audioURL: audioURL,
                apiKey: key,
                language: language,
                cleanSpeech: cleanSpeech
            )
            history.add(
                TranscriptItem(
                    text: result.text,
                    languageCode: result.languageCode,
                    duration: duration
                )
            )
            // The keyboard inserts at the cursor when it is on screen. The
            // clipboard is the fallback for every other host.
            UIPasteboard.general.string = result.text
            store.setPhase(
                .completed,
                sessionID: sessionID,
                transcript: result.text
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            cleanUpRecording(at: audioURL)
            finish()
            return result.text
        } catch {
            store.setPhase(
                .failed,
                sessionID: sessionID,
                errorMessage: error.localizedDescription
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            finish()
            throw error
        }
    }

    func cancel() {
        guard let sessionID else { return }
        recorder.stop(deactivatesSession: !keepAlive.isArmed)
        stopHeartbeat()
        store.setPhase(.cancelled, sessionID: sessionID)
        if let recordingURL { cleanUpRecording(at: recordingURL) }
        finish()
    }

    /// Prefer recording on the keep-alive's live session. If the lighter
    /// playback-only mode will not take input from the background, escalate to
    /// holding input outright and remember that for next time.
    private func beginCapture() throws -> URL {
        guard keepAlive.isArmed else {
            return try recorder.start()
        }

        do {
            try keepAlive.prepareForRecording()
            return try recorder.start(configuresSession: false)
        } catch {
            guard keepAlive.mode == .playbackOnly else { throw error }
            try keepAlive.arm(mode: .holdsInput)
            defaults.set(
                BackgroundAudioKeepAlive.Mode.holdsInput.rawValue,
                forKey: KeepAliveKeys.mode
            )
            return try recorder.start(configuresSession: false)
        }
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.sessionID == sessionID else { return }
                // Without this the keyboard treats the session as abandoned.
                self.store.touch(sessionID: sessionID)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func finish() {
        sessionID = nil
        recordingURL = nil
        stopHeartbeat()
        endBackgroundExecution()
        // Recording ended, so re-establish the resident session that lets the
        // next Back Tap start without a cold activation.
        if keepAliveEnabled, let mode = keepAlive.mode {
            try? keepAlive.arm(mode: mode)
        }
    }

    private func cleanUpRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func beginBackgroundExecution() {
        endBackgroundExecution()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "Finish background dictation"
        ) { [weak self] in
            Task { @MainActor in self?.endBackgroundExecution() }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
