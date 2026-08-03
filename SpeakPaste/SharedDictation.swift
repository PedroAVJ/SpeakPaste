import Foundation

enum SharedDictationConstants {
    static let appGroupIdentifier = "group.com.example.SpeakPaste"
    static let storageKey = "active-dictation-session-v1"
    /// The App Group container is not reachable over `devicectl`, so each
    /// process also mirrors its session diagnostics into its own Documents
    /// directory. A device-only launch or return failure stays actionable
    /// without reproducing it while attached to Xcode.
    static let diagnosticsFileName = "last-dictation-session.json"
    static let diagnosticsHistoryFileName = "dictation-sessions.jsonl"
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
    var hostResolutionAttempts: [String]?
    var launchAttempts: [String]?
    var successfulLaunchRoute: String?
    var returnAttempts: [String]?
    var incomingURLDeliveryRoute: String?
    var incomingURLSourceApplication: String?
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
            hostResolutionAttempts: nil,
            launchAttempts: nil,
            successfulLaunchRoute: nil,
            returnAttempts: nil,
            incomingURLDeliveryRoute: nil,
            incomingURLSourceApplication: nil,
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
        // The containing app and keyboard extension are separate processes.
        // Refresh cfprefsd before polling commands written by the other side.
        defaults?.synchronize()
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
            hostResolutionAttempts: nil,
            launchAttempts: nil,
            successfulLaunchRoute: nil,
            returnAttempts: nil,
            incomingURLDeliveryRoute: nil,
            incomingURLSourceApplication: nil,
            startedAt: Date(),
            updatedAt: Date()
        )
        save(snapshot)
        return snapshot
    }

    /// Start a session that is already recording. Intent-driven dictation never
    /// launches anything, so it must not pass through `launching` and make the
    /// keyboard announce an app switch that is not happening.
    @discardableResult
    func beginBackgroundSession() -> SharedDictationSnapshot {
        var snapshot = SharedDictationSnapshot.idle
        snapshot.phase = .recording
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

    func setReturnBundleIdentifier(
        _ bundleIdentifier: String,
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.returnBundleIdentifier = bundleIdentifier
        }
    }

    func setIncomingURLContext(
        deliveryRoute: String,
        sourceApplication: String?,
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.incomingURLDeliveryRoute = deliveryRoute
            snapshot.incomingURLSourceApplication = sourceApplication ?? "<nil>"
        }
    }

    func setLaunchDiagnostics(
        _ attempts: [String],
        successfulRoute: String?,
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.launchAttempts = attempts
            snapshot.successfulLaunchRoute = successfulRoute
        }
    }

    func setHostResolutionDiagnostics(
        _ attempts: [String],
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.hostResolutionAttempts = attempts
        }
    }

    func setReturnDiagnostics(
        _ attempts: [String],
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.returnAttempts = attempts
        }
    }

    /// Refresh `updatedAt` without changing anything else. The containing app
    /// owns every active phase, so a session that stops being touched is one
    /// whose process is gone.
    func touch(sessionID: UUID) {
        update(sessionID: sessionID) { _ in }
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
        // Ensure Stop/Cancel is visible immediately to a background recorder.
        defaults?.synchronize()
        mirrorDiagnostics(snapshot)
    }

    private func mirrorDiagnostics(_ snapshot: SharedDictationSnapshot) {
        guard
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else {
            return
        }

        var mirrored = snapshot
        // The mirror exists to explain routes, never to keep dictated content
        // in cleartext outside the session.
        mirrored.transcript = snapshot.transcript.map { "<\($0.count) characters>" }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(mirrored) else { return }
        try? data.write(
            to: directory.appendingPathComponent(
                SharedDictationConstants.diagnosticsFileName
            ),
            options: .atomic
        )

        // A reset overwrites the latest snapshot, which is exactly when the
        // preceding failure diagnostics matter most. Keep a bounded history so
        // a session can be reconstructed after it ends.
        appendToHistory(mirrored, in: directory)
    }

    private func appendToHistory(
        _ snapshot: SharedDictationSnapshot,
        in directory: URL
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard
            let line = try? encoder.encode(snapshot),
            var text = String(data: line, encoding: .utf8)
        else {
            return
        }
        text += "\n"

        let url = directory.appendingPathComponent(
            SharedDictationConstants.diagnosticsHistoryFileName
        )
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        existing += text
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > 400 {
            existing = lines.suffix(400).joined(separator: "\n") + "\n"
        }
        try? existing.write(to: url, atomically: true, encoding: .utf8)
    }
}
