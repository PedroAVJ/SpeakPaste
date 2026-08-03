import Darwin
import Foundation

/// A recording that must remain recoverable until a nonempty transcript exists
/// or the user explicitly discards it. The index stores only a basename, never
/// an arbitrary path that could be used to delete files outside SpeakPaste.
struct MacPendingAudioRecord: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case transcribing
        case waiting
    }

    let id: UUID
    let fileName: String
    var deviceName: String
    var recordingDuration: TimeInterval
    var reason: String
    /// Optional for backward-compatible decoding of journals created before
    /// reconnect retry existed. Only explicit `true` authorizes the app to
    /// wake this recording after a later usable-path transition.
    var retryOnReconnect: Bool? = nil
    /// A salvaged partial capture must keep its warning across retry/relaunch;
    /// otherwise a truncated dictation can later look like a clean success.
    var interruptionReason: String? = nil
    var createdAt: Date
    var status: Status
}

/// Durable proof that a pending recording already produced a History record.
/// The marker remains until its audio has been removed and that cleanup has
/// itself been committed, so no crash window can turn consumed audio back into
/// an ordinary retry.
struct MacPendingAudioCompletion: Codable, Equatable, Identifiable {
    var id: UUID { pendingAudioID }

    let pendingAudioID: UUID
    let historyRecordID: UUID
    let fileName: String
    let completedAt: Date
}

enum MacPendingAudioStoreError: LocalizedError {
    case sourceMissing
    case recordMissing
    case unsafeFileName
    case unsafeAudioFile
    case recordAlreadyExists
    case recordNotWaiting
    case recordCompleted
    case inconsistentIndex
    case incompatibleIndexVersion

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "The recorded audio file is no longer available."
        case .recordMissing:
            "The pending recording is no longer in the recovery journal."
        case .unsafeFileName:
            "The recovery journal contained an unsafe audio filename."
        case .unsafeAudioFile:
            "The recovery journal entry does not point to a regular audio file."
        case .recordAlreadyExists:
            "A pending recording already uses that recovery identifier."
        case .recordNotWaiting:
            "The pending recording is already being transcribed."
        case .recordCompleted:
            "The pending recording already produced a saved transcript."
        case .inconsistentIndex:
            "The pending-audio recovery index contains conflicting entries."
        case .incompatibleIndexVersion:
            "The pending-audio recovery index was created by a newer version of SpeakPaste."
        }
    }
}

/// Crash-safe, file-backed journal for captured audio.
///
/// New audio is moved into Application Support before upload. Deletes use a
/// persisted tombstone so a crash between index mutation and file removal does
/// not make an explicitly discarded/successfully transcribed file reappear as
/// an orphan on the next launch.
final class MacPendingAudioStore {
    private static let legacyReconnectReasonPrefixes = [
        "Waiting for an internet connection before sending this recording to ElevenLabs.",
        "A connectivity problem prevented this recording from reaching ElevenLabs.",
    ]

    private struct Index: Codable, Equatable {
        static let currentVersion = 3
        static let supportedVersions = 1 ... currentVersion

        var version = currentVersion
        var records: [MacPendingAudioRecord] = []
        var tombstones: [String] = []
        var completions: [MacPendingAudioCompletion] = []

        private enum CodingKeys: String, CodingKey {
            case version
            case records
            case tombstones
            case completions
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            records = try container.decodeIfPresent(
                [MacPendingAudioRecord].self,
                forKey: .records
            ) ?? []
            tombstones = try container.decodeIfPresent([String].self, forKey: .tombstones) ?? []
            completions = try container.decodeIfPresent(
                [MacPendingAudioCompletion].self,
                forKey: .completions
            ) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(records, forKey: .records)
            try container.encode(tombstones, forKey: .tombstones)
            try container.encode(completions, forKey: .completions)
        }
    }

    private struct IndexVersionProbe: Decodable {
        let version: Int?
    }

    let directoryURL: URL
    private let indexURL: URL
    /// Test seam for deterministic crash-window coverage. Production leaves it
    /// nil; every injected failure occurs before the atomic rename.
    private let beforeIndexWrite: (() throws -> Void)?
    private var index = Index()
    private var persistenceLocked = false
    /// History is a second durable source of completion truth. Keep confirmed
    /// IDs hidden even if committing the journal marker fails in this process.
    private var historyConfirmedIDs = Set<UUID>()
    /// Unlike the in-memory retry guard above, this set only advances after a
    /// completion marker was read from or committed to the durable index. It
    /// gates deletion of History's last cross-store recovery proof.
    private var durablyConfirmedIDs = Set<UUID>()

    private(set) var lastPersistenceError: String?
    var hasPendingCompletionCleanup: Bool { !index.completions.isEmpty }
    func completedPendingAudioIDs(
        linkedToHistoryRecordIDs historyRecordIDs: Set<UUID>
    ) -> Set<UUID> {
        Set(index.completions.compactMap { completion in
            historyRecordIDs.contains(completion.historyRecordID)
                ? completion.pendingAudioID
                : nil
        })
    }
    /// A durable completion marker is the authoritative member of an old
    /// duplicate History group. Startup should escrow that exact row instead of
    /// choosing a newer duplicate and then failing the marker-pair check.
    func completedHistoryRecordID(forPendingAudioID id: UUID) -> UUID? {
        index.completions.first { $0.pendingAudioID == id }?.historyRecordID
    }
    var records: [MacPendingAudioRecord] {
        index.records.filter { !historyConfirmedIDs.contains($0.id) }
    }

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        beforeIndexWrite: (() throws -> Void)? = nil
    ) {
        self.beforeIndexWrite = beforeIndexWrite
        let applicationSupportURL = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.directoryURL = directoryURL
            ?? applicationSupportURL
                .appendingPathComponent("SpeakPaste", isDirectory: true)
                .appendingPathComponent("PendingAudio", isDirectory: true)
        indexURL = self.directoryURL.appendingPathComponent("pending-audio-index.json")

        var initializationError: String?
        do {
            try ensurePrivateDirectory()
            try loadIndex()
            historyConfirmedIDs.formUnion(index.completions.map(\.pendingAudioID))
            durablyConfirmedIDs.formUnion(index.completions.map(\.pendingAudioID))
        } catch {
            initializationError = error.localizedDescription
            // Even a corrupt/missing index must not hide valid audio. Files are
            // reconstructed below without trusting its metadata or paths.
            index = Index()
        }

        // Completion markers deliberately survive construction. Only the app-
        // level History coordinator may retire one, after it has loaded History
        // as trusted recovery authority and durably cleared the matching source
        // link. Constructor cleanup would create a kill window in which both
        // cross-store proofs disappear in different processes.
        do {
            try finishTombstones()
        } catch {
            initializationError = error.localizedDescription
        }
        do {
            try recoverOrphans()
        } catch {
            initializationError = error.localizedDescription
        }
        // A successful orphan-recovery commit must not erase the warning that
        // caused that recovery (for example a corrupt or conflicting index).
        if let initializationError {
            lastPersistenceError = initializationError
        }
    }

    @discardableResult
    func stage(
        sourceURL: URL,
        id: UUID = UUID(),
        deviceName: String,
        recordingDuration: TimeInterval,
        reason: String = "Transcription in progress.",
        retryOnReconnect: Bool = false,
        interruptionReason: String? = nil,
        createdAt: Date = Date(),
        initialStatus: MacPendingAudioRecord.Status = .transcribing
    ) throws -> MacPendingAudioRecord {
        guard !persistenceLocked else {
            throw MacPendingAudioStoreError.incompatibleIndexVersion
        }
        try ensurePrivateDirectory()
        guard isRegularNonSymbolicFile(at: sourceURL) else {
            throw MacPendingAudioStoreError.sourceMissing
        }

        let fileExtension = safeExtension(sourceURL.pathExtension)
        let fileName = "\(id.uuidString).\(fileExtension)"
        let destinationURL = try safeAudioURL(forFileName: fileName)
        guard
            !historyConfirmedIDs.contains(id),
            !index.records.contains(where: { $0.id == id || $0.fileName == fileName }),
            !index.completions.contains(where: {
                $0.pendingAudioID == id || fileIdentityKey($0.fileName) == fileIdentityKey(fileName)
            })
        else {
            throw MacPendingAudioStoreError.recordAlreadyExists
        }
        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            // Never replace an unindexed orphan or an existing journal file.
            // A caller-supplied duplicate ID must not destroy recoverable audio.
            let destinationExists: Bool
            do {
                destinationExists = try MacPrivateStoreIO
                    .existingRegularFileIsPresent(at: destinationURL)
            } catch {
                throw MacPendingAudioStoreError.recordAlreadyExists
            }
            guard !destinationExists else {
                throw MacPendingAudioStoreError.recordAlreadyExists
            }
            try MacPrivateStoreIO.importRegularFile(from: sourceURL, to: destinationURL)
        }
        guard isRegularNonSymbolicFile(at: destinationURL) else {
            throw MacPendingAudioStoreError.unsafeAudioFile
        }
        try makePrivateFile(destinationURL)

        let record = MacPendingAudioRecord(
            id: id,
            fileName: fileName,
            deviceName: deviceName,
            recordingDuration: max(0, recordingDuration),
            reason: reason,
            retryOnReconnect: retryOnReconnect,
            interruptionReason: interruptionReason,
            createdAt: createdAt,
            status: initialStatus
        )
        var prospective = index
        prospective.tombstones.removeAll { $0 == fileName }
        prospective.records.append(record)
        try commit(prospective)
        return record
    }

    func markWaiting(
        _ id: UUID,
        reason: String,
        retryOnReconnect: Bool? = nil
    ) throws -> MacPendingAudioRecord {
        guard !historyConfirmedIDs.contains(id) else {
            throw MacPendingAudioStoreError.recordCompleted
        }
        var prospective = index
        guard let position = prospective.records.firstIndex(where: { $0.id == id }) else {
            throw MacPendingAudioStoreError.recordMissing
        }
        prospective.records[position].status = .waiting
        prospective.records[position].reason = reason
        if let retryOnReconnect {
            prospective.records[position].retryOnReconnect = retryOnReconnect
        }
        try commit(prospective)
        return prospective.records[position]
    }

    func markTranscribing(_ id: UUID) throws -> MacPendingAudioRecord {
        guard !historyConfirmedIDs.contains(id) else {
            throw MacPendingAudioStoreError.recordCompleted
        }
        var prospective = index
        guard let position = prospective.records.firstIndex(where: { $0.id == id }) else {
            throw MacPendingAudioStoreError.recordMissing
        }
        guard prospective.records[position].status == .waiting else {
            throw MacPendingAudioStoreError.recordNotWaiting
        }
        _ = try audioURL(for: prospective.records[position])
        prospective.records[position].status = .transcribing
        prospective.records[position].reason = "Transcription in progress."
        try commit(prospective)
        return prospective.records[position]
    }

    func updateMetadata(
        _ id: UUID,
        deviceName: String,
        recordingDuration: TimeInterval,
        reason: String,
        createdAt: Date
    ) throws -> MacPendingAudioRecord {
        guard !historyConfirmedIDs.contains(id) else {
            throw MacPendingAudioStoreError.recordCompleted
        }
        var prospective = index
        guard let position = prospective.records.firstIndex(where: { $0.id == id }) else {
            throw MacPendingAudioStoreError.recordMissing
        }
        _ = try audioURL(for: prospective.records[position])
        prospective.records[position].deviceName = deviceName
        prospective.records[position].recordingDuration = max(0, recordingDuration)
        prospective.records[position].reason = reason
        prospective.records[position].createdAt = createdAt
        prospective.records[position].status = .waiting
        try commit(prospective)
        return prospective.records[position]
    }

    /// Atomically moves an active recording out of the retry set and records
    /// which durable History entry consumed it. This is the commit that must
    /// happen before unlinking audio.
    @discardableResult
    func markCompleted(
        _ id: UUID,
        historyRecordID: UUID,
        completedAt: Date = Date()
    ) throws -> MacPendingAudioCompletion {
        if let existing = index.completions.first(where: { $0.pendingAudioID == id }) {
            guard existing.historyRecordID == historyRecordID else {
                throw MacPendingAudioStoreError.inconsistentIndex
            }
            historyConfirmedIDs.insert(id)
            durablyConfirmedIDs.insert(id)
            return existing
        }
        guard let record = index.records.first(where: { $0.id == id }) else {
            throw MacPendingAudioStoreError.recordMissing
        }
        guard !index.completions.contains(where: {
            $0.historyRecordID == historyRecordID
        }) else {
            throw MacPendingAudioStoreError.inconsistentIndex
        }
        historyConfirmedIDs.insert(id)
        let completion = MacPendingAudioCompletion(
            pendingAudioID: id,
            historyRecordID: historyRecordID,
            fileName: record.fileName,
            completedAt: completedAt
        )
        var prospective = index
        prospective.records.removeAll { $0.id == id }
        prospective.completions.append(completion)
        try commit(prospective)
        durablyConfirmedIDs.insert(id)
        return completion
    }

    /// Repairs the one ordering gap the audio journal cannot close alone: the
    /// app may die after History commits but before `markCompleted` commits.
    /// Confirmed IDs are hidden in memory before the repair write is attempted.
    func reconcileCompletedHistory(_ historyByPendingAudioID: [UUID: UUID]) throws {
        guard !historyByPendingAudioID.isEmpty else { return }
        guard !persistenceLocked else {
            throw MacPendingAudioStoreError.incompatibleIndexVersion
        }
        historyConfirmedIDs.formUnion(historyByPendingAudioID.keys)

        var prospective = index
        var knownCompletionIDs = Set(prospective.completions.map(\.pendingAudioID))
        var knownCompletionHistoryIDs = Set(prospective.completions.map(\.historyRecordID))
        var newlyDurableIDs = Set<UUID>()
        let tombstonedFiles = Set(prospective.tombstones.map(fileIdentityKey))
        var audioFilesByBasenameID: [UUID: [String]] = [:]
        for entry in try MacPrivateStoreIO.regularFileEntries(in: directoryURL) {
            guard (try? safeAudioURL(forFileName: entry.name)) != nil else { continue }
            guard let id = UUID(
                uuidString: URL(fileURLWithPath: entry.name)
                    .deletingPathExtension()
                    .lastPathComponent
            ) else {
                continue
            }
            audioFilesByBasenameID[id, default: []].append(entry.name)
        }

        var changed = false
        for (pendingAudioID, historyRecordID) in historyByPendingAudioID {
            let matchingFiles = audioFilesByBasenameID[pendingAudioID] ?? []
            guard matchingFiles.count <= 1 else {
                throw MacPendingAudioStoreError.inconsistentIndex
            }

            if let existing = prospective.completions.first(where: {
                $0.pendingAudioID == pendingAudioID
            }) {
                guard
                    existing.historyRecordID == historyRecordID,
                    matchingFiles.allSatisfy({
                        fileIdentityKey($0) == fileIdentityKey(existing.fileName)
                    })
                else {
                    throw MacPendingAudioStoreError.inconsistentIndex
                }
                durablyConfirmedIDs.insert(pendingAudioID)
                continue
            }

            let indexedRecord = prospective.records.first { $0.id == pendingAudioID }
            let fileName: String
            if let indexedRecord {
                guard matchingFiles.allSatisfy({
                    fileIdentityKey($0) == fileIdentityKey(indexedRecord.fileName)
                }) else {
                    throw MacPendingAudioStoreError.inconsistentIndex
                }
                fileName = indexedRecord.fileName
                prospective.records.removeAll { $0.id == pendingAudioID }
            } else if let orphanFileName = matchingFiles.first {
                // An earlier orphan-recovery index commit may have failed. The
                // exact UUID-named regular audio is still completion evidence,
                // so commit its marker before History is allowed to unpin it.
                guard !tombstonedFiles.contains(fileIdentityKey(orphanFileName)) else {
                    throw MacPendingAudioStoreError.inconsistentIndex
                }
                fileName = orphanFileName
            } else {
                // Absence is safe only when this process previously loaded or
                // committed the marker and then cleaned it up. An arbitrary
                // missing index entry is not authority to erase History proof.
                guard durablyConfirmedIDs.contains(pendingAudioID) else {
                    throw MacPendingAudioStoreError.recordMissing
                }
                continue
            }

            guard knownCompletionIDs.insert(pendingAudioID).inserted else {
                throw MacPendingAudioStoreError.inconsistentIndex
            }
            guard knownCompletionHistoryIDs.insert(historyRecordID).inserted else {
                throw MacPendingAudioStoreError.inconsistentIndex
            }
            prospective.completions.append(
                MacPendingAudioCompletion(
                    pendingAudioID: pendingAudioID,
                    historyRecordID: historyRecordID,
                    fileName: fileName,
                    completedAt: Date()
                )
            )
            newlyDurableIDs.insert(pendingAudioID)
            changed = true
        }
        if changed {
            try commit(prospective)
            durablyConfirmedIDs.formUnion(newlyDurableIDs)
        }
    }

    /// Removes a successful or explicitly discarded recording. The tombstone
    /// is durable before unlinking the audio, making every crash ordering safe.
    func remove(_ id: UUID) throws {
        guard !historyConfirmedIDs.contains(id) else {
            throw MacPendingAudioStoreError.recordCompleted
        }
        guard let record = index.records.first(where: { $0.id == id }) else {
            throw MacPendingAudioStoreError.recordMissing
        }
        try removeRecord(record)
    }

    /// Discards only a recording that is still waiting for user action. A
    /// stale retry-row action must never remove audio claimed by a concurrent
    /// transcription attempt.
    func discardWaiting(_ id: UUID) throws {
        guard !historyConfirmedIDs.contains(id) else {
            throw MacPendingAudioStoreError.recordCompleted
        }
        guard let record = index.records.first(where: { $0.id == id }) else {
            throw MacPendingAudioStoreError.recordMissing
        }
        guard record.status == .waiting else {
            throw MacPendingAudioStoreError.recordNotWaiting
        }
        try removeRecord(record)
    }

    private func removeRecord(_ record: MacPendingAudioRecord) throws {
        var tombstoned = index
        tombstoned.records.removeAll { $0.id == record.id }
        if !tombstoned.tombstones.contains(record.fileName) {
            tombstoned.tombstones.append(record.fileName)
        }
        try commit(tombstoned)

        let url = try safeAudioURL(forFileName: record.fileName)
        do {
            _ = try MacPrivateStoreIO.removeRegularFile(at: url)
        } catch {
            // The durable tombstone remains, so an unexpected directory or
            // link can never be recursively deleted or recovered as audio.
            if Self.isUnsafeBoundaryError(error) {
                throw MacPendingAudioStoreError.unsafeAudioFile
            }
            throw error
        }
        var cleaned = index
        cleaned.tombstones.removeAll { $0 == record.fileName }
        try commit(cleaned)
    }

    func audioURL(for record: MacPendingAudioRecord) throws -> URL {
        guard !historyConfirmedIDs.contains(record.id) else {
            throw MacPendingAudioStoreError.recordCompleted
        }
        guard index.records.contains(where: { current in
            current.id == record.id && current.fileName == record.fileName
        }) else {
            throw MacPendingAudioStoreError.recordMissing
        }
        try ensurePrivateDirectory()
        let url = try safeAudioURL(forFileName: record.fileName)
        do {
            guard try MacPrivateStoreIO.existingRegularFileIsPresent(at: url) else {
                throw MacPendingAudioStoreError.sourceMissing
            }
        } catch let error as MacPendingAudioStoreError {
            throw error
        } catch {
            throw MacPendingAudioStoreError.unsafeAudioFile
        }
        return url
    }

    func record(withID id: UUID) -> MacPendingAudioRecord? {
        guard !historyConfirmedIDs.contains(id) else { return nil }
        return index.records.first { $0.id == id }
    }

    // MARK: Persistence

    private func loadIndex() throws {
        let data: Data
        do {
            guard let loaded = try MacPrivateStoreIO.readExistingData(at: indexURL) else {
                index = Index()
                return
            }
            data = loaded
        } catch {
            throw MacPendingAudioStoreError.unsafeFileName
        }
        guard isRegularNonSymbolicFile(at: indexURL) else {
            index = Index()
            throw MacPendingAudioStoreError.unsafeFileName
        }
        try validateIndexSchema(in: data)
        var loaded = try JSONDecoder().decode(Index.self, from: data)
        let sourceVersion = loaded.version
        // Fail closed for future incompatible schemas. The audio scan below can
        // still recover files without trusting unknown metadata/behavior.
        guard Index.supportedVersions.contains(loaded.version) else {
            index = Index()
            throw CocoaError(.fileReadCorruptFile)
        }
        // New commits use the latest schema even when the source document was
        // an older compatible version. Otherwise adding reconnect metadata to
        // a v1/v2 record would write future keys under the old version number.
        loaded.version = Index.currentVersion
        var seenRecordIDs = Set<UUID>()
        var seenRecordFiles = Set<String>()
        var validRecords: [MacPendingAudioRecord] = []
        for record in loaded.records {
            guard
                let url = try? safeAudioURL(forFileName: record.fileName),
                isRegularNonSymbolicFile(at: url)
            else {
                continue
            }
            guard
                seenRecordIDs.insert(record.id).inserted,
                seenRecordFiles.insert(fileIdentityKey(record.fileName)).inserted
            else {
                throw MacPendingAudioStoreError.inconsistentIndex
            }
            try makePrivateFile(url)
            validRecords.append(record)
        }
        loaded.records = validRecords
        if sourceVersion < 3 {
            // A short-lived pre-v3 build encoded reconnect intent only in the
            // known English reason. Convert that exact legacy format once and
            // commit it before AppModel can claim/upload the recording; all
            // runtime decisions after this migration use only the typed bit.
            for position in loaded.records.indices
                where loaded.records[position].retryOnReconnect == nil {
                let reason = loaded.records[position].reason
                let retriesOnReconnect = Self
                    .legacyReconnectReasonPrefixes
                    .contains { reason.hasPrefix($0) }
                loaded.records[position].retryOnReconnect = retriesOnReconnect
            }
        }

        var seenCompletionIDs = Set<UUID>()
        var seenCompletionHistoryIDs = Set<UUID>()
        var seenCompletionFiles = Set<String>()
        var validCompletions: [MacPendingAudioCompletion] = []
        for completion in loaded.completions {
            guard (try? safeAudioURL(forFileName: completion.fileName)) != nil else {
                throw MacPendingAudioStoreError.inconsistentIndex
            }
            guard
                seenCompletionIDs.insert(completion.pendingAudioID).inserted,
                seenCompletionHistoryIDs.insert(completion.historyRecordID).inserted,
                seenCompletionFiles.insert(fileIdentityKey(completion.fileName)).inserted
            else {
                throw MacPendingAudioStoreError.inconsistentIndex
            }
            validCompletions.append(completion)
        }
        loaded.completions = validCompletions

        // A completion marker is the durable result of atomically removing the
        // matching active record. If an interrupted/manual index contains both,
        // accept only an exact pair and let completion win; partial conflicts
        // are ambiguous and must fail closed.
        for completion in loaded.completions {
            let conflicts = loaded.records.filter {
                $0.id == completion.pendingAudioID
                    || fileIdentityKey($0.fileName) == fileIdentityKey(completion.fileName)
            }
            guard conflicts.allSatisfy({
                $0.id == completion.pendingAudioID
                    && fileIdentityKey($0.fileName) == fileIdentityKey(completion.fileName)
            }) else {
                throw MacPendingAudioStoreError.inconsistentIndex
            }
        }
        let completedIDs = Set(loaded.completions.map(\.pendingAudioID))
        let completedFiles = Set(loaded.completions.map { fileIdentityKey($0.fileName) })
        loaded.records.removeAll {
            completedIDs.contains($0.id) || completedFiles.contains(fileIdentityKey($0.fileName))
        }

        var seenTombstones = Set<String>()
        loaded.tombstones = loaded.tombstones.filter { fileName in
            guard
                (try? safeAudioURL(forFileName: fileName)) != nil,
                seenTombstones.insert(fileIdentityKey(fileName)).inserted
            else {
                return false
            }
            return true
        }
        guard Set(loaded.records.map { fileIdentityKey($0.fileName) })
            .isDisjoint(with: seenTombstones)
        else {
            // Prefer recovering the audio to trusting an ambiguous instruction
            // that could otherwise delete an active pending recording.
            throw MacPendingAudioStoreError.inconsistentIndex
        }
        try makePrivateFile(indexURL)
        index = loaded
        if sourceVersion < Index.currentVersion {
            try commit(loaded)
        }
    }

    /// JSONDecoder deliberately ignores unknown keys. For an owned journal that
    /// would let this build erase future completion semantics on its next
    /// write, so recognized-version documents are shape-checked as well.
    private func validateIndexSchema(in data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Malformed JSON follows the existing orphan-recovery path. It has
            // no trustworthy deletion/completion instruction to preserve.
            return
        }

        let version: Int
        if object.keys.contains("version") {
            guard
                let probe = try? JSONDecoder().decode(IndexVersionProbe.self, from: data),
                let decodedVersion = probe.version
            else {
                persistenceLocked = true
                throw MacPendingAudioStoreError.incompatibleIndexVersion
            }
            version = decodedVersion
        } else {
            version = 1
        }
        guard Index.supportedVersions.contains(version) else {
            persistenceLocked = true
            throw MacPendingAudioStoreError.incompatibleIndexVersion
        }

        let topLevelKeys: Set<String> = version == 1
            ? ["version", "records", "tombstones"]
            : ["version", "records", "tombstones", "completions"]
        var recordKeys: Set<String> = [
            "id",
            "fileName",
            "deviceName",
            "recordingDuration",
            "reason",
            "createdAt",
            "status",
        ]
        if version >= 3 {
            recordKeys.formUnion(["retryOnReconnect", "interruptionReason"])
        }
        let completionKeys: Set<String> = [
            "pendingAudioID",
            "historyRecordID",
            "fileName",
            "completedAt",
        ]
        let recordsHaveFutureFields = (object["records"] as? [[String: Any]])?.contains {
            !Set($0.keys).isSubset(of: recordKeys)
        } == true
        let completionsHaveFutureFields = (object["completions"] as? [[String: Any]])?.contains {
            !Set($0.keys).isSubset(of: completionKeys)
        } == true
        guard
            Set(object.keys).isSubset(of: topLevelKeys),
            !recordsHaveFutureFields,
            !completionsHaveFutureFields
        else {
            persistenceLocked = true
            throw MacPendingAudioStoreError.incompatibleIndexVersion
        }
    }

    /// Replays durable completion markers. Successfully consumed files are
    /// removed first; only then is the marker retired in another atomic index
    /// commit. If that commit fails, the old marker remains durable and keeps
    /// the absent file from becoming a retry on the next launch.
    func finishCompletedCleanup(
        authorizedPendingAudioIDs: Set<UUID>
    ) throws {
        guard
            !authorizedPendingAudioIDs.isEmpty,
            index.completions.contains(where: {
                authorizedPendingAudioIDs.contains($0.pendingAudioID)
            })
        else {
            return
        }
        try ensurePrivateDirectory()
        var remaining: [MacPendingAudioCompletion] = []
        var cleanupError: Error?
        for completion in index.completions {
            guard authorizedPendingAudioIDs.contains(completion.pendingAudioID) else {
                remaining.append(completion)
                continue
            }
            guard let url = try? safeAudioURL(forFileName: completion.fileName) else {
                remaining.append(completion)
                cleanupError = cleanupError ?? MacPendingAudioStoreError.unsafeFileName
                continue
            }
            do {
                _ = try MacPrivateStoreIO.removeRegularFile(at: url)
            } catch {
                remaining.append(completion)
                cleanupError = cleanupError ?? (Self.isUnsafeBoundaryError(error)
                    ? MacPendingAudioStoreError.unsafeAudioFile
                    : error)
            }
        }

        var prospective = index
        prospective.completions = remaining
        if prospective != index { try commit(prospective) }
        if let cleanupError { throw cleanupError }
    }

    private func finishTombstones() throws {
        guard !index.tombstones.isEmpty else { return }
        try ensurePrivateDirectory()
        var remaining: [String] = []
        var replayError: Error?
        for fileName in index.tombstones {
            guard let url = try? safeAudioURL(forFileName: fileName) else { continue }
            do {
                _ = try MacPrivateStoreIO.removeRegularFile(at: url)
            } catch {
                // A transient unlink failure must retain the tombstone. The
                // orphan scan below will therefore continue to ignore it.
                remaining.append(fileName)
                replayError = replayError ?? (Self.isUnsafeBoundaryError(error)
                    ? MacPendingAudioStoreError.unsafeAudioFile
                    : error)
            }
        }
        var prospective = index
        prospective.tombstones = remaining
        if prospective != index { try commit(prospective) }
        if let replayError { throw replayError }
    }

    private func recoverOrphans() throws {
        try ensurePrivateDirectory()
        let entries = try MacPrivateStoreIO.regularFileEntries(in: directoryURL)
        var prospective = index
        let referenced = Set(prospective.records.map { fileIdentityKey($0.fileName) })
        let tombstoned = Set(prospective.tombstones.map(fileIdentityKey))
        let completed = Set(prospective.completions.map { fileIdentityKey($0.fileName) })
        var usedIDs = Set(prospective.records.map(\.id))
        usedIDs.formUnion(prospective.completions.map(\.pendingAudioID))
        for entry in entries {
            let url = directoryURL.appendingPathComponent(entry.name, isDirectory: false)
            guard
                !entry.name.hasPrefix("."),
                url.lastPathComponent != indexURL.lastPathComponent,
                !referenced.contains(fileIdentityKey(url.lastPathComponent)),
                !tombstoned.contains(fileIdentityKey(url.lastPathComponent)),
                !completed.contains(fileIdentityKey(url.lastPathComponent)),
                (try? safeAudioURL(forFileName: url.lastPathComponent)) != nil
            else {
                continue
            }
            try makePrivateFile(url)
            var id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            while usedIDs.contains(id) { id = UUID() }
            usedIDs.insert(id)
            prospective.records.append(
                MacPendingAudioRecord(
                    id: id,
                    fileName: url.lastPathComponent,
                    deviceName: "Recovered recording",
                    recordingDuration: 0,
                    reason: "Recovered after an interrupted session.",
                    createdAt: entry.createdAt,
                    status: .waiting
                )
            )
        }
        // Any interrupted `transcribing` entry becomes actionable on launch.
        for position in prospective.records.indices
            where prospective.records[position].status == .transcribing {
            prospective.records[position].status = .waiting
            prospective.records[position].reason = "Recovered after an interrupted transcription."
        }
        if prospective != index {
            if persistenceLocked {
                // Safe read-only recovery: preserve the unknown index bytes,
                // but keep every regular audio file visible to the current UI.
                index = prospective
            } else {
                try commit(prospective)
            }
        }
    }

    private func commit(_ prospective: Index) throws {
        guard !persistenceLocked else {
            let error = MacPendingAudioStoreError.incompatibleIndexVersion
            lastPersistenceError = error.localizedDescription
            throw error
        }
        do {
            var prospective = prospective
            prospective.version = Index.currentVersion
            let data = try JSONEncoder().encode(prospective)
            try writeIndexAtomically(data)
            index = prospective
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            throw error
        }
    }

    private func ensurePrivateDirectory() throws {
        // PendingAudio and its SpeakPaste parent are both app-controlled path
        // components. Validate/create them independently so a symlink at
        // either level cannot redirect chmod, reads, moves, or unlinks.
        try MacPrivateStoreIO.ensurePrivateDirectory(
            at: directoryURL.deletingLastPathComponent()
        )
        try MacPrivateStoreIO.ensurePrivateDirectory(at: directoryURL)
    }

    private func writeIndexAtomically(_ data: Data) throws {
        try ensurePrivateDirectory()
        try beforeIndexWrite?()
        try MacPrivateStoreIO.writeAtomically(data, to: indexURL)
    }

    private func makePrivateFile(_ url: URL) throws {
        try ensurePrivateDirectory()
        try MacPrivateStoreIO.secureExistingStorage(at: url)
    }

    private func safeURL(forFileName fileName: String) throws -> URL {
        guard
            !fileName.isEmpty,
            fileName == URL(fileURLWithPath: fileName).lastPathComponent,
            fileName != ".",
            fileName != ".."
        else {
            throw MacPendingAudioStoreError.unsafeFileName
        }
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        let directoryPath = directoryURL.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(directoryPath) else {
            throw MacPendingAudioStoreError.unsafeFileName
        }
        return url
    }

    private func safeAudioURL(forFileName fileName: String) throws -> URL {
        let url = try safeURL(forFileName: fileName)
        guard
            url.lastPathComponent != indexURL.lastPathComponent,
            Self.audioExtensions.contains(url.pathExtension.lowercased())
        else {
            throw MacPendingAudioStoreError.unsafeFileName
        }
        return url
    }

    private func isRegularNonSymbolicFile(at url: URL) -> Bool {
        (try? MacPrivateStoreIO.existingRegularFileIsPresent(at: url)) == true
    }

    private func fileIdentityKey(_ fileName: String) -> String {
        fileName.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func safeExtension(_ candidate: String) -> String {
        let normalized = candidate.lowercased()
        return Self.audioExtensions.contains(normalized) ? normalized : "wav"
    }

    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "mp4", "mov", "ogg", "opus", "flac", "aac",
        "aif", "aiff", "caf", "webm", "mkv", "mpeg", "mpg", "3gp", "3gpp",
        "wma", "amr",
    ]

    private static func isUnsafeBoundaryError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ELOOP)
    }
}
