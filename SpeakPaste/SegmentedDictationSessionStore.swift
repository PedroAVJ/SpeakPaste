import Darwin
import Foundation

struct SegmentedDictationSessionManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    enum Lifecycle: String, Codable, Equatable, Sendable {
        case starting
        case recording
        case paused
        case transcribing
        case failed
        case cancelled
        case completed
    }

    struct Segment: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let ordinal: Int
        let duration: TimeInterval
    }

    struct ActiveCapture: Codable, Equatable, Sendable {
        let id: UUID
        let ordinal: Int
    }

    let schemaVersion: Int
    let id: UUID
    var lifecycle: Lifecycle
    var segments: [Segment]
    var activeCapture: ActiveCapture?
    let createdAt: Date
    var updatedAt: Date

    var orderedSegments: [Segment] {
        segments.sorted { $0.ordinal < $1.ordinal }
    }

    var nextOrdinal: Int {
        max(
            orderedSegments.last.map { $0.ordinal + 1 } ?? 0,
            activeCapture.map { $0.ordinal + 1 } ?? 0
        )
    }

    var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + max(0, $1.duration) }
    }
}

struct SegmentedDictationRecoveryGroup: Equatable, Sendable {
    let manifest: SegmentedDictationSessionManifest
    let entries: [RecordingJournalEntry]
}

enum SegmentedDictationSessionStoreError: LocalizedError, Equatable {
    case unavailable
    case unsafeStorage
    case corruptManifest
    case duplicateSession
    case missingSession
    case invalidTransition
    case missingSegment(UUID)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Segmented dictation recovery storage is unavailable."
        case .unsafeStorage:
            "Segmented dictation recovery storage is unsafe."
        case .corruptManifest:
            "The segmented dictation recovery record is corrupt."
        case .duplicateSession:
            "A segmented dictation recovery record already exists."
        case .missingSession:
            "The segmented dictation recovery record is missing."
        case .invalidTransition:
            "The segmented dictation recovery state changed unexpectedly."
        case let .missingSegment(id):
            "A segmented dictation recording is missing: \(id.uuidString)."
        }
    }
}

/// Crash-safe, transcript-free ownership for a parent dictation and its child
/// RecordingJournal entries. The JSON file is the commit boundary: each update
/// is written atomically while an advisory lock excludes another intent process.
final class SegmentedDictationSessionStore: @unchecked Sendable {
    let rootDirectory: URL
    private let lockURL: URL
    private let fileManager: FileManager

    convenience init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.init(
            rootDirectory: applicationSupport
                .appendingPathComponent("SpeakPaste", isDirectory: true)
                .appendingPathComponent(
                    "SegmentedDictationSessions",
                    isDirectory: true
                ),
            fileManager: fileManager
        )
    }

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        lockURL = self.rootDirectory.appendingPathComponent(
            ".manifest.lock",
            isDirectory: false
        )
        self.fileManager = fileManager
    }

    @discardableResult
    func create(
        sessionID: UUID,
        lifecycle: SegmentedDictationSessionManifest.Lifecycle = .starting,
        now: Date = Date()
    ) throws -> SegmentedDictationSessionManifest {
        try withLock {
            if try loadUnlocked(sessionID: sessionID) != nil {
                throw SegmentedDictationSessionStoreError.duplicateSession
            }
            let manifest = SegmentedDictationSessionManifest(
                schemaVersion: SegmentedDictationSessionManifest.currentSchemaVersion,
                id: sessionID,
                lifecycle: lifecycle,
                segments: [],
                activeCapture: nil,
                createdAt: now,
                updatedAt: now
            )
            try saveUnlocked(manifest)
            return manifest
        }
    }

    func load(
        sessionID: UUID
    ) throws -> SegmentedDictationSessionManifest? {
        try withLock { try loadUnlocked(sessionID: sessionID) }
    }

    func allManifests() throws -> [SegmentedDictationSessionManifest] {
        try withLock {
            try prepareStorage()
            let names = try fileManager.contentsOfDirectory(
                atPath: rootDirectory.path
            )
            return try names
                .filter { $0.hasSuffix(".session.json") }
                .compactMap { name in
                    guard let sessionID = Self.sessionID(from: name) else {
                        throw SegmentedDictationSessionStoreError.corruptManifest
                    }
                    return try loadUnlocked(sessionID: sessionID)
                }
                .sorted {
                    if $0.createdAt == $1.createdAt {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return $0.createdAt < $1.createdAt
                }
        }
    }

    @discardableResult
    func setActiveCapture(
        sessionID: UUID,
        captureID: UUID,
        ordinal: Int,
        lifecycle: SegmentedDictationSessionManifest.Lifecycle = .recording,
        now: Date = Date()
    ) throws -> SegmentedDictationSessionManifest {
        try mutate(sessionID: sessionID, now: now) { manifest in
            if manifest.activeCapture == .init(id: captureID, ordinal: ordinal) {
                manifest.lifecycle = lifecycle
                return
            }
            guard
                manifest.activeCapture == nil,
                ordinal == manifest.nextOrdinal,
                !manifest.segments.contains(where: { $0.id == captureID })
            else {
                throw SegmentedDictationSessionStoreError.invalidTransition
            }
            manifest.activeCapture = .init(id: captureID, ordinal: ordinal)
            manifest.lifecycle = lifecycle
        }
    }

    @discardableResult
    func appendFinalizedSegment(
        sessionID: UUID,
        entry: RecordingJournalEntry,
        ordinal: Int,
        lifecycle: SegmentedDictationSessionManifest.Lifecycle,
        now: Date = Date()
    ) throws -> SegmentedDictationSessionManifest {
        try mutate(sessionID: sessionID, now: now) { manifest in
            let segment = SegmentedDictationSessionManifest.Segment(
                id: entry.id,
                ordinal: ordinal,
                duration: max(0, entry.duration)
            )
            if manifest.segments.contains(segment) {
                manifest.activeCapture = nil
                manifest.lifecycle = lifecycle
                return
            }
            guard
                manifest.activeCapture == .init(id: entry.id, ordinal: ordinal),
                !manifest.segments.contains(where: {
                    $0.id == entry.id || $0.ordinal == ordinal
                })
            else {
                throw SegmentedDictationSessionStoreError.invalidTransition
            }
            manifest.segments.append(segment)
            manifest.segments.sort { $0.ordinal < $1.ordinal }
            manifest.activeCapture = nil
            manifest.lifecycle = lifecycle
        }
    }

    @discardableResult
    func setLifecycle(
        _ lifecycle: SegmentedDictationSessionManifest.Lifecycle,
        sessionID: UUID,
        now: Date = Date()
    ) throws -> SegmentedDictationSessionManifest {
        try mutate(sessionID: sessionID, now: now) { manifest in
            manifest.lifecycle = lifecycle
        }
    }

    @discardableResult
    func clearEmptyActiveCapture(
        sessionID: UUID,
        captureID: UUID,
        ordinal: Int,
        lifecycle: SegmentedDictationSessionManifest.Lifecycle,
        now: Date = Date()
    ) throws -> SegmentedDictationSessionManifest {
        try mutate(sessionID: sessionID, now: now) { manifest in
            guard
                manifest.activeCapture == .init(
                    id: captureID,
                    ordinal: ordinal
                )
            else {
                throw SegmentedDictationSessionStoreError.invalidTransition
            }
            manifest.activeCapture = nil
            manifest.lifecycle = lifecycle
        }
    }

    /// `RecordingJournal` performs the filesystem-safe adoption. This method
    /// binds only the exact child named by the manifest, making unrelated orphan
    /// recordings impossible to absorb into this thought.
    @discardableResult
    func adoptFinalizedActiveCapture(
        sessionID: UUID,
        from entries: [RecordingJournalEntry],
        now: Date = Date()
    ) throws -> SegmentedDictationSessionManifest {
        try mutate(sessionID: sessionID, now: now) { manifest in
            guard let active = manifest.activeCapture else { return }
            guard let entry = entries.first(where: { $0.id == active.id }) else {
                return
            }
            let segment = SegmentedDictationSessionManifest.Segment(
                id: entry.id,
                ordinal: active.ordinal,
                duration: max(0, entry.duration)
            )
            if !manifest.segments.contains(segment) {
                guard !manifest.segments.contains(where: {
                    $0.id == entry.id || $0.ordinal == active.ordinal
                }) else {
                    throw SegmentedDictationSessionStoreError.invalidTransition
                }
                manifest.segments.append(segment)
                manifest.segments.sort { $0.ordinal < $1.ordinal }
            }
            manifest.activeCapture = nil
            manifest.lifecycle = .paused
        }
    }

    func recoveryGroup(
        for manifest: SegmentedDictationSessionManifest,
        journalEntries: [RecordingJournalEntry]
    ) throws -> SegmentedDictationRecoveryGroup {
        let byID = Dictionary(uniqueKeysWithValues: journalEntries.map {
            ($0.id, $0)
        })
        let entries = try manifest.orderedSegments.map { segment in
            guard let entry = byID[segment.id] else {
                throw SegmentedDictationSessionStoreError.missingSegment(
                    segment.id
                )
            }
            return entry
        }
        return SegmentedDictationRecoveryGroup(
            manifest: manifest,
            entries: entries
        )
    }

    func delete(sessionID: UUID) throws {
        try withLock {
            try prepareStorage()
            let url = manifestURL(for: sessionID)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
            try syncDirectory()
        }
    }

    @discardableResult
    private func mutate(
        sessionID: UUID,
        now: Date,
        _ mutation: (inout SegmentedDictationSessionManifest) throws -> Void
    ) throws -> SegmentedDictationSessionManifest {
        try withLock {
            guard var manifest = try loadUnlocked(sessionID: sessionID) else {
                throw SegmentedDictationSessionStoreError.missingSession
            }
            try mutation(&manifest)
            manifest.updatedAt = now
            try validate(manifest, expectedSessionID: sessionID)
            try saveUnlocked(manifest)
            return manifest
        }
    }

    private func loadUnlocked(
        sessionID: UUID
    ) throws -> SegmentedDictationSessionManifest? {
        try prepareStorage()
        let url = manifestURL(for: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            (values.fileSize ?? 0) <= 256 * 1024
        else {
            throw SegmentedDictationSessionStoreError.unsafeStorage
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let manifest: SegmentedDictationSessionManifest
        do {
            manifest = try JSONDecoder().decode(
                SegmentedDictationSessionManifest.self,
                from: data
            )
        } catch {
            throw SegmentedDictationSessionStoreError.corruptManifest
        }
        try validate(manifest, expectedSessionID: sessionID)
        return manifest
    }

    private func saveUnlocked(
        _ manifest: SegmentedDictationSessionManifest
    ) throws {
        try prepareStorage()
        try validate(manifest, expectedSessionID: manifest.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let url = manifestURL(for: manifest.id)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        try syncDirectory()
    }

    private func validate(
        _ manifest: SegmentedDictationSessionManifest,
        expectedSessionID: UUID
    ) throws {
        guard
            manifest.schemaVersion
                == SegmentedDictationSessionManifest.currentSchemaVersion,
            manifest.id == expectedSessionID,
            manifest.createdAt <= manifest.updatedAt,
            manifest.segments.allSatisfy({
                $0.ordinal >= 0 && $0.duration.isFinite && $0.duration >= 0
            })
        else {
            throw SegmentedDictationSessionStoreError.corruptManifest
        }
        let ids = manifest.segments.map(\.id)
        let ordinals = manifest.segments.map(\.ordinal)
        guard Set(ids).count == ids.count,
              Set(ordinals).count == ordinals.count,
              ordinals == ordinals.sorted(),
              manifest.activeCapture.map({ active in
                  active.ordinal >= 0
                      && !ids.contains(active.id)
                      && !ordinals.contains(active.ordinal)
              }) ?? true else {
            throw SegmentedDictationSessionStoreError.corruptManifest
        }
    }

    private func prepareStorage() throws {
        if fileManager.fileExists(atPath: rootDirectory.path) {
            let values = try rootDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SegmentedDictationSessionStoreError.unsafeStorage
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: rootDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw SegmentedDictationSessionStoreError.unavailable
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: rootDirectory.path
        )
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try prepareStorage()
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_EXLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SegmentedDictationSessionStoreError.unavailable
        }
        defer { Darwin.close(descriptor) }
        return try operation()
    }

    private func syncDirectory() throws {
        let descriptor = Darwin.open(rootDirectory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw SegmentedDictationSessionStoreError.unavailable
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SegmentedDictationSessionStoreError.unavailable
        }
    }

    private func manifestURL(for sessionID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).session.json",
            isDirectory: false
        )
    }

    private static func sessionID(from fileName: String) -> UUID? {
        guard fileName.hasSuffix(".session.json") else { return nil }
        return UUID(
            uuidString: String(fileName.dropLast(".session.json".count))
        )
    }
}

/// Repairs the one false-positive recovery state that can be proven harmless
/// without opening the containing app: a failed segmented parent whose journal
/// child is absent or zero-byte. Any finalized segment or non-empty active file
/// makes this a no-op, preserving even extremely short recordings.
enum SegmentedDictationFailureRepair {
    @discardableResult
    static func resetIfProvablyEmpty(
        snapshot: SharedDictationSnapshot,
        sharedStore: SharedDictationStore,
        sessionStore: SegmentedDictationSessionStore,
        recordingJournal: RecordingJournal
    ) -> Bool {
        guard
            snapshot.phase == .failed,
            // Older snapshots predate `sessionKind`. The exact matching
            // segmented manifest below is sufficient lane proof for nil; a
            // legacy keyboard round trip never created this manifest.
            snapshot.sessionKind == .segmentedIntent
                || snapshot.sessionKind == nil,
            snapshot.hasRecoverableAudio == true,
            !sharedStore.isCaptureLeaseActive,
            let loaded = try? sessionStore.load(
                sessionID: snapshot.sessionID
            ),
            loaded.lifecycle == .failed,
            loaded.segments.isEmpty,
            loaded.activeCapture != nil
        else {
            return false
        }

        do {
            var manifest = try sessionStore.adoptFinalizedActiveCapture(
                sessionID: snapshot.sessionID,
                from: recordingJournal.recoverableEntries()
            )
            guard manifest.segments.isEmpty else { return false }

            if let activeCapture = manifest.activeCapture {
                guard try recordingJournal.abandonCrashLeftEmptyCapture(
                    id: activeCapture.id
                ) else {
                    return false
                }
                manifest = try sessionStore.clearEmptyActiveCapture(
                    sessionID: snapshot.sessionID,
                    captureID: activeCapture.id,
                    ordinal: activeCapture.ordinal,
                    lifecycle: .failed
                )
            }

            guard manifest.activeCapture == nil, manifest.segments.isEmpty else {
                return false
            }
            try sessionStore.delete(sessionID: snapshot.sessionID)
            guard sharedStore.transitionPhase(
                from: [.failed],
                to: .failed,
                sessionID: snapshot.sessionID,
                errorMessage: snapshot.errorMessage,
                hasRecoverableAudio: false,
                recoveryAction: nil
            ) else {
                return false
            }
            return sharedStore.resetNonrecoverableFailure(
                sessionID: snapshot.sessionID
            )
        } catch {
            return false
        }
    }
}
