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

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Add your ElevenLabs API key in SpeakPaste before dictating."
            case .microphoneDenied:
                "Microphone access is off. Enable it for SpeakPaste in Settings."
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
            recordingURL = try recorder.start()
        } catch {
            store.setPhase(
                .failed,
                sessionID: snapshot.sessionID,
                errorMessage: error.localizedDescription
            )
            sessionID = nil
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
        let audioURL = recorder.stop() ?? recordingURL
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
        recorder.stop()
        stopHeartbeat()
        store.setPhase(.cancelled, sessionID: sessionID)
        if let recordingURL { cleanUpRecording(at: recordingURL) }
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
