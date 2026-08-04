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
    @Published private(set) var recentlyInserted = false

    private let store: SharedDictationStore
    private let resolveHostApplication: () -> HostApplicationResolution
    private let openContainingApp: (URL) async -> KeyboardAppLaunchOutcome
    private let currentInsertionContextFingerprint: () -> String
    private let insertTranscript: (String) -> Void
    private let insertText: (String) -> Void
    private let deleteBackward: () -> Void
    private let advanceToNextKeyboard: () -> Void
    private var pollTask: Task<Void, Never>?
    private var insertedConfirmationTask: Task<Void, Never>?
    private var startedSessionID: UUID?
    private var pollingStartedAt: Date?

    init(
        store: SharedDictationStore = SharedDictationStore(),
        resolveHostApplication: @escaping () -> HostApplicationResolution,
        openContainingApp: @escaping (URL) async -> KeyboardAppLaunchOutcome,
        currentInsertionContextFingerprint: @escaping () -> String,
        insertTranscript: @escaping (String) -> Void,
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        advanceToNextKeyboard: @escaping () -> Void
    ) {
        self.store = store
        self.snapshot = store.load()
        self.resolveHostApplication = resolveHostApplication
        self.openContainingApp = openContainingApp
        self.currentInsertionContextFingerprint = currentInsertionContextFingerprint
        self.insertTranscript = insertTranscript
        self.insertText = insertText
        self.deleteBackward = deleteBackward
        self.advanceToNextKeyboard = advanceToNextKeyboard
    }

    var isIdle: Bool {
        [.idle, .inserted, .handled, .cancelled].contains(snapshot.phase)
    }

    var isStarting: Bool {
        snapshot.phase == .starting || snapshot.phase == .launching
    }
    var isRecording: Bool { snapshot.phase == .recording }
    var isTranscribing: Bool { snapshot.phase == .transcribing }
    var didFail: Bool {
        [.failed, .deliveryBlocked, .inserting].contains(snapshot.phase)
    }
    var recoveryButtonTitle: String {
        switch snapshot.recoveryAction {
        case .openContainingApp:
            "Open SpeakPaste"
        case .insertHere:
            "Insert Here"
        case .reviewPossibleInsertion:
            "Insert Again"
        case .retryTranscription, nil:
            "Retry"
        }
    }
    var errorDismissalButtonTitle: String {
        guard [.deliveryBlocked, .inserting].contains(snapshot.phase) else {
            return "Dismiss"
        }
        return snapshot.historyPersisted == true
            ? "Keep in History"
            : "Discard Transcript"
    }
    var canDismissError: Bool {
        localError != nil
            || [.deliveryBlocked, .inserting].contains(snapshot.phase)
            || (snapshot.phase == .failed
                && snapshot.hasRecoverableAudio != true)
    }

    func startPolling() {
        pollTask?.cancel()
        pollingStartedAt = Date()
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
        pollingStartedAt = nil
    }

    func startDictation() {
        localError = nil
        guard isIdle else { return }
        guard hasFullAccess else {
            localError = "Enable Allow Full Access for SpeakPaste in Keyboard Settings."
            return
        }
        guard store.isAvailable else {
            localError = "SpeakPaste's shared app group is unavailable. Reinstall the signed app."
            return
        }

        let hostResolution = resolveHostApplication()
        guard let newSnapshot = store.begin(
            returnBundleIdentifier: hostResolution.bundleIdentifier,
            returnProcessIdentifier: hostResolution.processIdentifier,
            insertionContextFingerprint: currentInsertionContextFingerprint()
        ) else {
            snapshot = store.load()
            localError = "Another SpeakPaste dictation is still active or waiting for recovery."
            return
        }
        startedSessionID = newSnapshot.sessionID
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
                errorMessage: message,
                hasRecoverableAudio: false,
                recoveryAction: .openContainingApp
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
        switch snapshot.recoveryAction {
        case .openContainingApp:
            openSpeakPaste()
        case .insertHere, .reviewPossibleInsertion:
            insertPendingHere()
        case .retryTranscription:
            store.send(.retry, sessionID: snapshot.sessionID)
            wakeContainingAppForRecovery(sessionID: snapshot.sessionID)
            refresh()
        case nil:
            store.send(.retry, sessionID: snapshot.sessionID)
            wakeContainingAppForRecovery(sessionID: snapshot.sessionID)
            refresh()
        }
    }

    func openSpeakPaste() {
        guard let url = URL(string: "speakpaste://settings") else { return }
        Task { _ = await openContainingApp(url) }
    }

    private func wakeContainingAppForRecovery(sessionID: UUID) {
        guard let url = URL(
            string: "speakpaste://recover?session=\(sessionID.uuidString)"
        ) else {
            return
        }
        Task {
            let outcome = await openContainingApp(url)
            if !outcome.didOpen {
                localError = "Open SpeakPaste to retry the recovered recording."
            }
        }
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
        let hadLocalError = localError != nil
        localError = nil
        let current = store.load()
        if hadLocalError, startedSessionID != current.sessionID {
            // Full-access and CAS failures are local UI state. Never let their
            // Dismiss button mutate a session owned by the other process.
            snapshot = current
            return
        }
        if [.deliveryBlocked, .inserting].contains(current.phase) {
            // The label says whether this keeps a durable History copy or is
            // explicitly discarding the only transcript under Never retention.
            store.markHandled(sessionID: current.sessionID)
            if startedSessionID == current.sessionID {
                startedSessionID = nil
            }
        } else if current.phase == .failed,
                  current.hasRecoverableAudio != true {
            // Setup/open failures have no private audio bundle to protect. A
            // recreated extension must still be able to clear them and start.
            store.reset(sessionID: current.sessionID)
            if startedSessionID == current.sessionID {
                startedSessionID = nil
            }
        } else if startedSessionID == current.sessionID {
            store.reset(sessionID: current.sessionID)
            startedSessionID = nil
        }
        refresh()
    }

    /// The containing app heartbeats every few seconds while it owns a session.
    /// Well past that interval means the app is gone and the session will never
    /// finish on its own.
    private static func abandonedSessionTimeout(
        for phase: SharedDictationPhase
    ) -> TimeInterval {
        switch phase {
        case .launching, .starting:
            // Permission sheets and cold app launches are user-paced.
            return 90
        case .recording, .transcribing:
            return 15
        default:
            return 0
        }
    }
    private static func isOwnedByContainingApp(
        _ phase: SharedDictationPhase
    ) -> Bool {
        switch phase {
        case .launching, .starting, .recording, .transcribing:
            return true
        case .idle, .completed, .inserting, .deliveryBlocked, .failed,
             .cancelled, .inserted, .handled:
            return false
        }
    }

    private func refresh() {
        var latest = store.load()
        if
            latest.phase == .starting,
            latest.insertionContextFingerprint == nil,
            Date().timeIntervalSince(latest.startedAt) < 2,
            let pollingStartedAt,
            pollingStartedAt <= latest.startedAt.addingTimeInterval(0.5)
        {
            _ = store.claimInsertionContext(
                sessionID: latest.sessionID,
                fingerprint: currentInsertionContextFingerprint()
            )
            latest = store.load()
        }
        if
            Self.isOwnedByContainingApp(latest.phase),
            Date().timeIntervalSince(latest.updatedAt)
                > Self.abandonedSessionTimeout(for: latest.phase)
        {
            // Preserve the session ID so a journaled recording can be matched
            // after a force quit or background termination.
            let hasRecoverableAudio = latest.hasRecoverableAudio == true
            store.setPhase(
                .failed,
                sessionID: latest.sessionID,
                errorMessage: hasRecoverableAudio
                    ? "Dictation was interrupted. Open SpeakPaste to recover the recording."
                    : "Dictation was interrupted before audio was saved. Dismiss this message and try again.",
                hasRecoverableAudio: hasRecoverableAudio,
                recoveryAction: .openContainingApp
            )
            latest = store.load()
            localError = nil
        }
        snapshot = latest

        deliverCompletedTranscript(latest, validateOriginalContext: true)
    }

    private func insertPendingHere() {
        let pending = store.load()
        guard [.deliveryBlocked, .inserting].contains(pending.phase) else {
            return
        }
        store.allowExplicitInsertion(sessionID: pending.sessionID)
        let completed = store.load()
        snapshot = completed
        deliverCompletedTranscript(completed, validateOriginalContext: false)
    }

    private func deliverCompletedTranscript(
        _ latest: SharedDictationSnapshot,
        validateOriginalContext: Bool
    ) {
        guard
            latest.phase == .completed,
            let transcript = latest.transcript?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !transcript.isEmpty
        else {
            return
        }

        if validateOriginalContext {
            guard let originalFingerprint = latest.insertionContextFingerprint else {
                store.blockDelivery(
                    sessionID: latest.sessionID,
                    message: "SpeakPaste couldn't verify the original text field. Tap Insert Here to place the transcript at the current cursor."
                )
                snapshot = store.load()
                return
            }
            guard originalFingerprint == currentInsertionContextFingerprint() else {
                store.blockDelivery(
                    sessionID: latest.sessionID,
                    message: "The text field changed while you were dictating. Tap Insert Here to put the transcript at the current cursor."
                )
                snapshot = store.load()
                return
            }
        }

        guard store.markInsertionStarted(sessionID: latest.sessionID) else {
            snapshot = store.load()
            return
        }
        snapshot = store.load()
        insertTranscript(transcript)
        store.markInserted(sessionID: latest.sessionID)
        if startedSessionID == latest.sessionID {
            startedSessionID = nil
        }
        snapshot = store.load()
        showInsertedConfirmation()
    }

    private func showInsertedConfirmation() {
        insertedConfirmationTask?.cancel()
        recentlyInserted = true
        insertedConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.recentlyInserted = false
        }
    }
}
