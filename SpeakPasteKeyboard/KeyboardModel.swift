import Combine
import Foundation

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var snapshot: SharedDictationSnapshot
    @Published var hasFullAccess = false
    @Published private(set) var localError: String?

    private let store: SharedDictationStore
    private let resolveHostBundleIdentifier: () -> String?
    private let openContainingApp: (URL) async -> Bool
    private let insertTranscript: (String) -> Void
    private let advanceToNextKeyboard: () -> Void
    private var pollTask: Task<Void, Never>?
    private var insertedSessionIDs: Set<UUID> = []

    init(
        store: SharedDictationStore = SharedDictationStore(),
        resolveHostBundleIdentifier: @escaping () -> String?,
        openContainingApp: @escaping (URL) async -> Bool,
        insertTranscript: @escaping (String) -> Void,
        advanceToNextKeyboard: @escaping () -> Void
    ) {
        self.store = store
        self.snapshot = store.load()
        self.resolveHostBundleIdentifier = resolveHostBundleIdentifier
        self.openContainingApp = openContainingApp
        self.insertTranscript = insertTranscript
        self.advanceToNextKeyboard = advanceToNextKeyboard
    }

    var isIdle: Bool {
        [.idle, .inserted, .cancelled].contains(snapshot.phase)
    }

    var isLaunching: Bool { snapshot.phase == .launching }
    var isRecording: Bool { snapshot.phase == .recording }
    var isTranscribing: Bool { snapshot.phase == .transcribing }
    var didFail: Bool { snapshot.phase == .failed }

    func startPolling() {
        pollTask?.cancel()
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func startDictation() {
        localError = nil
        guard hasFullAccess else {
            localError = "Enable Allow Full Access for SpeakPaste in Keyboard Settings."
            return
        }
        guard store.isAvailable else {
            localError = "SpeakPaste's shared app group is unavailable. Reinstall the signed app."
            return
        }

        let newSnapshot = store.begin(
            returnBundleIdentifier: resolveHostBundleIdentifier()
        )
        snapshot = newSnapshot
        guard let url = URL(
            string: "speakpaste://dictate/start?session=\(newSnapshot.sessionID.uuidString)"
        ) else {
            return
        }

        Task {
            let didOpen = await openContainingApp(url)
            guard !didOpen else { return }
            let message = "SpeakPaste could not open. Open the app once, then try again."
            store.setPhase(
                .failed,
                sessionID: newSnapshot.sessionID,
                errorMessage: message
            )
            localError = message
            refresh()
        }
    }

    func stopAndTranscribe() {
        store.send(.stop, sessionID: snapshot.sessionID)
        refresh()
    }

    func cancel() {
        store.send(.cancel, sessionID: snapshot.sessionID)
        refresh()
    }

    func retry() {
        localError = nil
        store.send(.retry, sessionID: snapshot.sessionID)
        refresh()
    }

    func openSpeakPaste() {
        guard let url = URL(string: "speakpaste://settings") else { return }
        Task { _ = await openContainingApp(url) }
    }

    func nextKeyboard() {
        advanceToNextKeyboard()
    }

    func dismissError() {
        localError = nil
        store.reset()
        refresh()
    }

    private func refresh() {
        let latest = store.load()
        snapshot = latest

        guard
            latest.phase == .completed,
            !insertedSessionIDs.contains(latest.sessionID),
            let transcript = latest.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
            !transcript.isEmpty
        else {
            return
        }

        insertedSessionIDs.insert(latest.sessionID)
        insertTranscript(transcript)
        store.markInserted(sessionID: latest.sessionID)
        snapshot = store.load()
    }
}
