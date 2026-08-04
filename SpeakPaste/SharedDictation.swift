import Darwin
import Foundation

enum SharedDictationConstants {
    static let appGroupIdentifier: String = {
        let configuredIdentifier = Bundle.main.object(
            forInfoDictionaryKey: "SpeakPasteAppGroupIdentifier"
        ) as? String
        let normalizedIdentifier = configuredIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedIdentifier,
              !normalizedIdentifier.isEmpty,
              !normalizedIdentifier.contains("$(") else {
            return "group.com.example.SpeakPaste"
        }

        return normalizedIdentifier
    }()
    static let storageKey = "active-dictation-session-v1"
    static let stateFileName = "active-dictation-session-v2.json"
    static let stateLockFileName = "active-dictation-session-v2.lock"
    /// The App Group container is not reachable over `devicectl`, so each
    /// process also mirrors its session diagnostics into its own Documents
    /// directory. A device-only launch or return failure stays actionable
    /// without reproducing it while attached to Xcode.
    static let diagnosticsFileName = "last-dictation-session.json"
    static let diagnosticsHistoryFileName = "dictation-sessions.jsonl"
    static let hostApplicationIdentityKey = "host-application-identity-v1"
}

/// A host identity captured while the keyboard is still embedded in another
/// app. The process identifier is intentionally part of the record: a bundle
/// identifier by itself can become stale when the user changes apps.
struct HostApplicationIdentity: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let capturedAt: Date
}

/// A process-local arbiter value is usable only when UIKit published it after
/// the current keyboard appearance began and the host process stayed stable.
/// Keeping this policy in the shared target makes the stale-host boundary
/// directly testable without loading UIKit's private keyboard classes.
enum HostApplicationCapturePolicy {
    static func baselineGeneration(
        currentGeneration: UInt64,
        cleanBoundaryGeneration: UInt64?,
        processHasEstablishedAppearance: Bool
    ) -> UInt64 {
        if let cleanBoundaryGeneration {
            return cleanBoundaryGeneration
        }
        return processHasEstablishedAppearance ? currentGeneration : 0
    }

    static func accepts(
        candidateBundleIdentifier: String,
        captureGeneration: UInt64,
        appearanceBaselineGeneration: UInt64,
        expectedProcessIdentifier: Int32?,
        currentProcessIdentifier: Int32?,
        previousIdentity: HostApplicationIdentity?
    ) -> Bool {
        guard
            let expectedProcessIdentifier,
            expectedProcessIdentifier > 1,
            currentProcessIdentifier == expectedProcessIdentifier
        else {
            return false
        }
        guard captureGeneration > appearanceBaselineGeneration else {
            return false
        }

        // UIKit can deliver a destination callback after the prior host has
        // already disappeared. Never bind that prior bundle to a new PID.
        if rejectsPreviousHost(
            candidateBundleIdentifier: candidateBundleIdentifier,
            expectedProcessIdentifier: expectedProcessIdentifier,
            previousIdentity: previousIdentity
        ) {
            return false
        }
        return true
    }

    static func rejectsPreviousHost(
        candidateBundleIdentifier: String,
        expectedProcessIdentifier: Int32,
        previousIdentity: HostApplicationIdentity?
    ) -> Bool {
        guard
            let previousIdentity,
            previousIdentity.processIdentifier != expectedProcessIdentifier
        else {
            return false
        }
        return previousIdentity.bundleIdentifier.caseInsensitiveCompare(
            candidateBundleIdentifier
        ) == .orderedSame
    }
}

/// Carries a verified keyboard-host identity across extension termination and
/// app upgrades. Reads require the exact live host PID and a short age window;
/// there is deliberately no bundle-only fallback.
struct HostApplicationIdentityCache: @unchecked Sendable {
    /// This is only a last-resort bridge across a short extension restart. A
    /// small lease sharply limits PID-reuse risk; live host evidence wins.
    static let defaultMaximumAge: TimeInterval = 60

    private let defaults: UserDefaults?
    private let storageKey: String

    init(
        suiteName: String = SharedDictationConstants.appGroupIdentifier,
        storageKey: String = SharedDictationConstants.hostApplicationIdentityKey
    ) {
        defaults = UserDefaults(suiteName: suiteName)
        self.storageKey = storageKey
    }

    func load() -> HostApplicationIdentity? {
        guard
            let data = defaults?.data(forKey: storageKey),
            let identity = try? JSONDecoder().decode(
                HostApplicationIdentity.self,
                from: data
            ),
            identity.processIdentifier > 1,
            !identity.bundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            return nil
        }
        return identity
    }

    func matchingIdentity(
        processIdentifier: Int32?,
        now: Date = Date(),
        maximumAge: TimeInterval = Self.defaultMaximumAge
    ) -> HostApplicationIdentity? {
        guard
            let processIdentifier,
            processIdentifier > 1,
            let identity = load(),
            identity.processIdentifier == processIdentifier
        else {
            return nil
        }
        let age = now.timeIntervalSince(identity.capturedAt)
        guard age >= -5, age <= maximumAge else { return nil }
        return identity
    }

    func save(
        bundleIdentifier: String,
        processIdentifier: Int32,
        capturedAt: Date = Date()
    ) {
        let identifier = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard processIdentifier > 1, !identifier.isEmpty else { return }
        let identity = HostApplicationIdentity(
            bundleIdentifier: identifier,
            processIdentifier: processIdentifier,
            capturedAt: capturedAt
        )
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults?.set(data, forKey: storageKey)
        _ = defaults?.synchronize()
    }

    func clear() {
        defaults?.removeObject(forKey: storageKey)
        _ = defaults?.synchronize()
    }
}

enum SharedDictationPhase: String, Codable {
    case idle
    case launching
    case starting
    case recording
    case transcribing
    case completed
    /// The extension persisted its intent to insert before touching the host
    /// field. If it dies here, automatic replay would risk duplicate text.
    case inserting
    /// Dictation completed, but the host field/cursor changed while the app was
    /// recording. The transcript remains recoverable for explicit insertion.
    case deliveryBlocked
    case failed
    case cancelled
    case inserted
    case handled
}

enum SharedDictationRecoveryAction: String, Codable {
    case openContainingApp
    case retryTranscription
    case insertHere
    case reviewPossibleInsertion
}

enum SharedDictationCommand: String, Codable, Hashable {
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
    /// Whether a History row contains this transcript. `false` is expected
    /// when the user selected the Never retention policy.
    var historyPersisted: Bool? = nil
    /// True only when a private, journaled audio file can be retried after the
    /// process exits. Ordinary setup failures remain safely dismissible.
    var hasRecoverableAudio: Bool? = nil
    /// Privacy-safe hash of the host input context at the moment recording was
    /// requested. The extension compares this before automatic insertion.
    var insertionContextFingerprint: String? = nil
    var recoveryAction: SharedDictationRecoveryAction? = nil
    /// Monotonic counters make cross-process state changes diagnosable and let
    /// the recorder consume each command at most once.
    var revision: UInt64? = nil
    var commandSequence: UInt64? = nil
    var acknowledgedCommandSequence: UInt64? = nil
    /// Cross-entry-point microphone lease. Manual in-app recording does not
    /// need a keyboard-delivery session, but it must still exclude a Back Tap
    /// or App Intent from opening a second AVAudioSession recorder.
    var captureOwnerID: UUID? = nil
    var captureLeaseUpdatedAt: Date? = nil
    var returnBundleIdentifier: String?
    var returnProcessIdentifier: Int32?
    var hostResolutionAttempts: [String]?
    var launchAttempts: [String]?
    var successfulLaunchRoute: String?
    var returnAttempts: [String]?
    var incomingURLDeliveryRoute: String?
    var incomingURLSourceApplication: String?
    /// Historical diagnostic for the retired background-pasteboard experiment.
    /// Keep it optional so sessions written by older builds still decode.
    var clipboardLanded: Bool? = nil
    var startedAt: Date
    var updatedAt: Date

    static var idle: SharedDictationSnapshot {
        SharedDictationSnapshot(
            sessionID: UUID(),
            phase: .idle,
            command: .none,
            transcript: nil,
            errorMessage: nil,
            historyPersisted: nil,
            hasRecoverableAudio: nil,
            insertionContextFingerprint: nil,
            recoveryAction: nil,
            revision: 0,
            commandSequence: 0,
            acknowledgedCommandSequence: 0,
            captureOwnerID: nil,
            captureLeaseUpdatedAt: nil,
            returnBundleIdentifier: nil,
            returnProcessIdentifier: nil,
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
    private let storageDirectory: URL?
    private let requiresSharedContainer: Bool

    init(
        suiteName: String = SharedDictationConstants.appGroupIdentifier,
        storageDirectory: URL? = nil
    ) {
        defaults = UserDefaults(suiteName: suiteName)
        requiresSharedContainer =
            suiteName == SharedDictationConstants.appGroupIdentifier
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else if suiteName == SharedDictationConstants.appGroupIdentifier {
            self.storageDirectory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            )
        } else {
            // Tests and previews can continue to use isolated UserDefaults.
            self.storageDirectory = nil
        }
    }

    var isAvailable: Bool {
        storageDirectory != nil
            || (!requiresSharedContainer && defaults != nil)
    }

    var isCaptureLeaseActive: Bool {
        let snapshot = load()
        return hasLiveCaptureLease(snapshot)
    }

    func load() -> SharedDictationSnapshot {
        withStateLock { loadUnlocked() } ?? loadUnlocked()
    }

    @discardableResult
    func begin(
        returnBundleIdentifier: String?,
        returnProcessIdentifier: Int32? = nil,
        insertionContextFingerprint: String? = nil
    ) -> SharedDictationSnapshot? {
        withStateLock {
            let previous = loadUnlocked()
            guard [
                SharedDictationPhase.idle,
                .inserted,
                .handled,
                .cancelled,
            ].contains(previous.phase) else {
                return nil
            }
            guard !hasLiveCaptureLease(previous) else { return nil }
            let sessionID = UUID()
            let snapshot = SharedDictationSnapshot(
                sessionID: sessionID,
                phase: .launching,
                command: .none,
                transcript: nil,
                errorMessage: nil,
                historyPersisted: nil,
                hasRecoverableAudio: nil,
                insertionContextFingerprint: insertionContextFingerprint,
                recoveryAction: nil,
                revision: (previous.revision ?? 0) + 1,
                commandSequence: 0,
                acknowledgedCommandSequence: 0,
                captureOwnerID: sessionID,
                captureLeaseUpdatedAt: Date(),
                returnBundleIdentifier: returnBundleIdentifier,
                returnProcessIdentifier: returnProcessIdentifier,
                hostResolutionAttempts: nil,
                launchAttempts: nil,
                successfulLaunchRoute: nil,
                returnAttempts: nil,
                incomingURLDeliveryRoute: nil,
                incomingURLSourceApplication: nil,
                startedAt: Date(),
                updatedAt: Date()
            )
            guard saveUnlocked(snapshot) else { return nil }
            return snapshot
        } ?? nil
    }

    /// Atomically turns a keyboard launch into the one foreground capture
    /// attempt for that session. URL delivery and scene activation may both
    /// observe the same launch, so the phase transition and lease renewal must
    /// happen under the same cross-process lock.
    ///
    /// A late URL may arrive after the keyboard's launch watchdog publishes a
    /// failure. That failure is claimable only while this exact session still
    /// owns a live lease. A recorder failure releases the lease first, making
    /// every subsequently queued launch a harmless no-op that cannot replace
    /// the original error.
    func claimLaunchingSession(
        sessionID: UUID
    ) -> SharedDictationSnapshot? {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.sessionID == sessionID else { return nil }

            switch snapshot.phase {
            case .launching:
                // Older snapshots predate the capture-owner fields. The
                // session identifier itself is sufficient to adopt those.
                guard
                    snapshot.captureOwnerID == nil
                        || snapshot.captureOwnerID == sessionID
                else {
                    return nil
                }
            case .failed:
                guard
                    snapshot.captureOwnerID == sessionID,
                    snapshot.hasRecoverableAudio == false,
                    hasLiveCaptureLease(snapshot)
                else {
                    return nil
                }
            default:
                return nil
            }

            snapshot.phase = .starting
            snapshot.errorMessage = nil
            snapshot.hasRecoverableAudio = nil
            snapshot.recoveryAction = nil
            snapshot.captureOwnerID = sessionID
            snapshot.captureLeaseUpdatedAt = Date()
            advanceRevision(&snapshot)
            guard saveUnlocked(snapshot) else { return nil }
            return snapshot
        } ?? nil
    }

    /// Start an intent-driven session while iOS grants background capture.
    /// Publishing `starting` keeps the keyboard truthful until the recorder
    /// proves that the microphone is live. Never replace a completed transcript
    /// that the keyboard has not inserted yet.
    @discardableResult
    func beginBackgroundSession() -> SharedDictationSnapshot? {
        withStateLock {
            let current = loadUnlocked()
            // A Back Tap/intent and the keyboard can arrive together. Session
            // creation is a compare-and-swap: only terminal sessions may be
            // replaced, so neither entry point can steal an active recorder or
            // a recoverable failed delivery from the other.
            guard [
                SharedDictationPhase.idle,
                .inserted,
                .handled,
                .cancelled,
            ].contains(current.phase) else {
                return nil
            }
            guard !hasLiveCaptureLease(current) else { return nil }

            var snapshot = SharedDictationSnapshot.idle
            snapshot.phase = .starting
            snapshot.revision = (current.revision ?? 0) + 1
            snapshot.captureOwnerID = snapshot.sessionID
            snapshot.captureLeaseUpdatedAt = Date()
            guard saveUnlocked(snapshot) else { return nil }
            return snapshot
        } ?? nil
    }

    @discardableResult
    func setPhase(
        _ phase: SharedDictationPhase,
        sessionID: UUID,
        transcript: String? = nil,
        errorMessage: String? = nil,
        historyPersisted: Bool? = nil,
        hasRecoverableAudio: Bool? = nil,
        recoveryAction: SharedDictationRecoveryAction? = nil,
        clipboardLanded: Bool? = nil,
        startedAt: Date? = nil
    ) -> Bool {
        update(sessionID: sessionID) { snapshot in
            if let startedAt {
                snapshot.startedAt = startedAt
            } else if phase == .recording && snapshot.phase != .recording {
                snapshot.startedAt = Date()
            }
            snapshot.phase = phase
            snapshot.transcript = transcript
            snapshot.errorMessage = errorMessage
            snapshot.historyPersisted = historyPersisted
            if let hasRecoverableAudio {
                snapshot.hasRecoverableAudio = hasRecoverableAudio
            }
            snapshot.recoveryAction = recoveryAction
            snapshot.clipboardLanded = clipboardLanded
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
            snapshot.commandSequence = (snapshot.commandSequence ?? 0) + 1
        }
    }

    /// Reserve the microphone for a foreground recording without creating a
    /// keyboard-delivery session. The lease expires if its owner stops
    /// heartbeating, so a force-quit cannot block dictation forever.
    @discardableResult
    func acquireCaptureLease(ownerID: UUID) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard
                [.idle, .inserted, .handled, .cancelled]
                    .contains(snapshot.phase),
                !hasLiveCaptureLease(snapshot)
                    || snapshot.captureOwnerID == ownerID
            else {
                return false
            }
            snapshot.captureOwnerID = ownerID
            snapshot.captureLeaseUpdatedAt = Date()
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    @discardableResult
    func renewCaptureLease(ownerID: UUID) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.captureOwnerID == ownerID else { return false }
            snapshot.captureLeaseUpdatedAt = Date()
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    @discardableResult
    func releaseCaptureLease(ownerID: UUID) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.captureOwnerID == ownerID else { return false }
            snapshot.captureOwnerID = nil
            snapshot.captureLeaseUpdatedAt = nil
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    /// An App Intent starts outside the keyboard process. If the keyboard is
    /// already visible, let it bind the current host-field fingerprint during
    /// the active session. A late keyboard with no fingerprint must require an
    /// explicit insertion instead of guessing that the field is unchanged.
    @discardableResult
    func claimInsertionContext(
        sessionID: UUID,
        fingerprint: String
    ) -> Bool {
        updateIf(sessionID: sessionID) { snapshot in
            guard
                [.launching, .starting, .recording, .transcribing]
                    .contains(snapshot.phase),
                snapshot.insertionContextFingerprint == nil
            else {
                return false
            }
            snapshot.insertionContextFingerprint = fingerprint
            return true
        }
    }

    /// Atomically consumes a keyboard command. Polling the same snapshot twice
    /// cannot trigger two retries, and a heartbeat can no longer overwrite a
    /// command written between its read and write.
    func takePendingCommand(
        sessionID: UUID,
        accepting allowedCommands: Set<SharedDictationCommand>
    ) -> SharedDictationCommand {
        withStateLock {
            var snapshot = loadUnlocked()
            guard
                snapshot.sessionID == sessionID,
                snapshot.command != .none,
                allowedCommands.contains(snapshot.command)
            else {
                return .none
            }

            let command = snapshot.command
            snapshot.command = .none
            snapshot.acknowledgedCommandSequence = snapshot.commandSequence
            advanceRevision(&snapshot)
            guard saveUnlocked(snapshot) else { return .none }
            return command
        } ?? .none
    }

    /// Persist the insertion boundary before mutating the host document. A
    /// crash after this point becomes an explicit recovery choice instead of
    /// silently replaying text into the field.
    @discardableResult
    func markInsertionStarted(sessionID: UUID) -> Bool {
        updateIf(sessionID: sessionID) { snapshot in
            guard
                snapshot.phase == .completed,
                snapshot.transcript?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
            else {
                return false
            }
            snapshot.phase = .inserting
            snapshot.command = .none
            snapshot.errorMessage = "SpeakPaste may already have inserted this dictation. Review the field before inserting again."
            snapshot.recoveryAction = .reviewPossibleInsertion
            return true
        }
    }

    func blockDelivery(sessionID: UUID, message: String) {
        update(sessionID: sessionID) { snapshot in
            guard snapshot.phase == .completed else { return }
            snapshot.phase = .deliveryBlocked
            snapshot.command = .none
            snapshot.errorMessage = message
            snapshot.recoveryAction = .insertHere
        }
    }

    /// Explicit recovery after a context change or uncertain prior insertion.
    /// It deliberately returns to `completed`; the caller immediately records
    /// `inserting` again before touching the document proxy.
    func allowExplicitInsertion(sessionID: UUID) {
        update(sessionID: sessionID) { snapshot in
            guard [.deliveryBlocked, .inserting].contains(snapshot.phase) else {
                return
            }
            snapshot.phase = .completed
            snapshot.errorMessage = nil
            snapshot.recoveryAction = nil
            snapshot.hasRecoverableAudio = nil
        }
    }

    func markInserted(sessionID: UUID) {
        update(sessionID: sessionID) { snapshot in
            snapshot.phase = .inserted
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.errorMessage = nil
            snapshot.recoveryAction = nil
            snapshot.hasRecoverableAudio = nil
        }
    }

    /// A History copy/open/delete is an explicit fallback delivery when the
    /// keyboard cannot insert (for example, in a secure field).
    func markHandled(sessionID: UUID) {
        update(sessionID: sessionID) { snapshot in
            snapshot.phase = .handled
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.errorMessage = nil
            snapshot.recoveryAction = nil
        }
    }

    @discardableResult
    func reset(sessionID: UUID) -> Bool {
        withStateLock {
            let current = loadUnlocked()
            guard current.sessionID == sessionID else { return false }
            var idle = SharedDictationSnapshot.idle
            idle.revision = (current.revision ?? 0) + 1
            return saveUnlocked(idle)
        } ?? false
    }

    /// Clears only a failed setup attempt that cannot contain user audio and
    /// no longer owns the recorder. This lets an updated or relaunched app
    /// repair stale launch state without racing a late, still-live launch or
    /// discarding a recoverable recording.
    @discardableResult
    func resetNonrecoverableFailure(sessionID: UUID) -> Bool {
        withStateLock {
            let current = loadUnlocked()
            guard
                current.sessionID == sessionID,
                current.phase == .failed,
                current.hasRecoverableAudio != true,
                !hasLiveCaptureLease(current)
            else {
                return false
            }
            var idle = SharedDictationSnapshot.idle
            idle.revision = (current.revision ?? 0) + 1
            return saveUnlocked(idle)
        } ?? false
    }

    @discardableResult
    private func update(
        sessionID: UUID,
        mutation: (inout SharedDictationSnapshot) -> Void
    ) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.sessionID == sessionID else { return false }
            mutation(&snapshot)
            if snapshot.captureOwnerID == sessionID {
                snapshot.captureLeaseUpdatedAt = Date()
            }
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    @discardableResult
    private func updateIf(
        sessionID: UUID,
        mutation: (inout SharedDictationSnapshot) -> Bool
    ) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.sessionID == sessionID, mutation(&snapshot) else {
                return false
            }
            if snapshot.captureOwnerID == sessionID {
                snapshot.captureLeaseUpdatedAt = Date()
            }
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    private func loadUnlocked() -> SharedDictationSnapshot {
        // The JSON file plus flock is the source of truth in production. The
        // defaults value remains a migration/fallback path for older installs
        // and isolated unit-test suites.
        if
            let stateURL,
            let data = try? Data(contentsOf: stateURL),
            let snapshot = try? JSONDecoder().decode(
                SharedDictationSnapshot.self,
                from: data
            )
        {
            // Once the locked app-group file exists it is authoritative. The
            // defaults mirror is written second and may legitimately lag if a
            // process dies between the two writes.
            return snapshot
        }

        defaults?.synchronize()
        guard
            let data = defaults?.data(
                forKey: SharedDictationConstants.storageKey
            ),
            let snapshot = try? JSONDecoder().decode(
                SharedDictationSnapshot.self,
                from: data
            )
        else {
            return .idle
        }
        return snapshot
    }

    @discardableResult
    private func saveUnlocked(_ snapshot: SharedDictationSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return false
        }
        if let stateURL {
            do {
                try FileManager.default.createDirectory(
                    at: stateURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: stateURL, options: [.atomic])
            } catch {
                return false
            }
        } else {
            guard defaults != nil else { return false }
        }
        defaults?.set(data, forKey: SharedDictationConstants.storageKey)
        // Ensure Stop/Cancel is visible immediately to a background recorder.
        defaults?.synchronize()
        mirrorDiagnostics(snapshot)
        return true
    }

    private var stateURL: URL? {
        storageDirectory?.appendingPathComponent(
            SharedDictationConstants.stateFileName,
            isDirectory: false
        )
    }

    private var lockURL: URL? {
        storageDirectory?.appendingPathComponent(
            SharedDictationConstants.stateLockFileName,
            isDirectory: false
        )
    }

    private func advanceRevision(_ snapshot: inout SharedDictationSnapshot) {
        snapshot.revision = (snapshot.revision ?? 0) + 1
        snapshot.updatedAt = Date()
    }

    private func hasLiveCaptureLease(
        _ snapshot: SharedDictationSnapshot,
        now: Date = Date()
    ) -> Bool {
        guard
            snapshot.captureOwnerID != nil,
            let updatedAt = snapshot.captureLeaseUpdatedAt
        else {
            return false
        }
        return now.timeIntervalSince(updatedAt) < 15
    }

    private func withStateLock<T>(_ operation: () -> T) -> T? {
        guard let lockURL else { return operation() }
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_EXLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        // `O_EXLOCK` acquires the advisory lock atomically with open; closing
        // the descriptor releases it on every Darwin platform.
        defer { Darwin.close(descriptor) }
        return operation()
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
