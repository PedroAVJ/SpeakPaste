import Combine
import Foundation

struct KeyboardAppLaunchOutcome: Equatable, Sendable {
    let didOpen: Bool
    let route: String?
    let attempts: [String]

    static func opened(
        route: String,
        attempts: [String]
    ) -> KeyboardAppLaunchOutcome {
        KeyboardAppLaunchOutcome(
            didOpen: true,
            route: route,
            attempts: attempts
        )
    }

    static func failed(attempts: [String]) -> KeyboardAppLaunchOutcome {
        KeyboardAppLaunchOutcome(
            didOpen: false,
            route: nil,
            attempts: attempts
        )
    }
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var snapshot: SharedDictationSnapshot
    @Published var hasFullAccess = false
    @Published private(set) var localError: String?

    private let store: SharedDictationStore
    private let resolveHostApplication: () -> HostApplicationResolution
    private let openContainingApp: (URL) async -> KeyboardAppLaunchOutcome
    private let insertTranscript: (String) -> Void
    private let insertText: (String) -> Void
    private let deleteBackward: () -> Void
    private let advanceToNextKeyboard: () -> Void
    private var pollTask: Task<Void, Never>?
    private var insertedSessionIDs: Set<UUID> = []

    init(
        store: SharedDictationStore = SharedDictationStore(),
        resolveHostApplication: @escaping () -> HostApplicationResolution,
        openContainingApp: @escaping (URL) async -> KeyboardAppLaunchOutcome,
        insertTranscript: @escaping (String) -> Void,
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        advanceToNextKeyboard: @escaping () -> Void
    ) {
        self.store = store
        self.snapshot = store.load()
        self.resolveHostApplication = resolveHostApplication
        self.openContainingApp = openContainingApp
        self.insertTranscript = insertTranscript
        self.insertText = insertText
        self.deleteBackward = deleteBackward
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

        let hostResolution = resolveHostApplication()
        let newSnapshot = store.begin(
            returnBundleIdentifier: hostResolution.bundleIdentifier
        )
        store.setHostResolutionDiagnostics(
            hostResolution.attempts,
            sessionID: newSnapshot.sessionID
        )
        snapshot = newSnapshot
        guard let url = URL(
            string: "speakpaste://dictate/start?session=\(newSnapshot.sessionID.uuidString)"
        ) else {
            return
        }

        Task {
            let outcome = await openContainingApp(url)
            store.setLaunchDiagnostics(
                outcome.attempts,
                successfulRoute: outcome.route,
                sessionID: newSnapshot.sessionID
            )
            if outcome.didOpen {
                try? await Task.sleep(for: .seconds(4))
                let latest = store.load()
                guard
                    latest.sessionID == newSnapshot.sessionID,
                    latest.phase == .launching
                else {
                    return
                }
            }

            let message = "SpeakPaste did not open. Dismiss this message and try again."
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

    func type(_ text: String) {
        insertText(text)
    }

    func backspace() {
        deleteBackward()
    }

    func dismissError() {
        localError = nil
        store.reset()
        refresh()
    }

    private func refresh() {
        var latest = store.load()
        if
            latest.phase == .launching,
            Date().timeIntervalSince(latest.updatedAt) > 15
        {
            store.reset()
            latest = store.load()
            localError = nil
        }
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
