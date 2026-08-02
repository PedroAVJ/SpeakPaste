import Foundation

enum SharedDictationConstants {
    static let appGroupIdentifier = "group.com.example.SpeakPaste"
    static let storageKey = "active-dictation-session-v1"
}

enum SharedDictationPhase: String, Codable {
    case idle
    case launching
    case recording
    case transcribing
    case completed
    case failed
    case cancelled
    case inserted
}

enum SharedDictationCommand: String, Codable {
    case none
    case stop
    case cancel
    case retry
}

struct SharedDictationSnapshot: Codable, Equatable {
    var sessionID: UUID
    var phase: SharedDictationPhase
    var command: SharedDictationCommand
    var transcript: String?
    var errorMessage: String?
    var returnBundleIdentifier: String?
    var startedAt: Date
    var updatedAt: Date

    static var idle: SharedDictationSnapshot {
        SharedDictationSnapshot(
            sessionID: UUID(),
            phase: .idle,
            command: .none,
            transcript: nil,
            errorMessage: nil,
            returnBundleIdentifier: nil,
            startedAt: Date(),
            updatedAt: Date()
        )
    }
}

struct SharedDictationStore: @unchecked Sendable {
    private let defaults: UserDefaults?

    init(suiteName: String = SharedDictationConstants.appGroupIdentifier) {
        defaults = UserDefaults(suiteName: suiteName)
    }

    var isAvailable: Bool { defaults != nil }

    func load() -> SharedDictationSnapshot {
        guard
            let data = defaults?.data(forKey: SharedDictationConstants.storageKey),
            let snapshot = try? JSONDecoder().decode(SharedDictationSnapshot.self, from: data)
        else {
            return .idle
        }
        return snapshot
    }

    @discardableResult
    func begin(returnBundleIdentifier: String?) -> SharedDictationSnapshot {
        let snapshot = SharedDictationSnapshot(
            sessionID: UUID(),
            phase: .launching,
            command: .none,
            transcript: nil,
            errorMessage: nil,
            returnBundleIdentifier: returnBundleIdentifier,
            startedAt: Date(),
            updatedAt: Date()
        )
        save(snapshot)
        return snapshot
    }

    func setPhase(
        _ phase: SharedDictationPhase,
        sessionID: UUID,
        transcript: String? = nil,
        errorMessage: String? = nil
    ) {
        update(sessionID: sessionID) { snapshot in
            if phase == .recording && snapshot.phase != .recording {
                snapshot.startedAt = Date()
            }
            snapshot.phase = phase
            snapshot.command = .none
            snapshot.transcript = transcript
            snapshot.errorMessage = errorMessage
        }
    }

    func send(_ command: SharedDictationCommand, sessionID: UUID) {
        update(sessionID: sessionID) { snapshot in
            snapshot.command = command
        }
    }

    func markInserted(sessionID: UUID) {
        update(sessionID: sessionID) { snapshot in
            snapshot.phase = .inserted
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.errorMessage = nil
        }
    }

    func reset() {
        save(.idle)
    }

    private func update(
        sessionID: UUID,
        mutation: (inout SharedDictationSnapshot) -> Void
    ) {
        var snapshot = load()
        guard snapshot.sessionID == sessionID else { return }
        mutation(&snapshot)
        snapshot.updatedAt = Date()
        save(snapshot)
    }

    private func save(_ snapshot: SharedDictationSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: SharedDictationConstants.storageKey)
    }
}
