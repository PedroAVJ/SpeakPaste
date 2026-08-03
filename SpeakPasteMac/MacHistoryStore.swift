import Combine
import Darwin
import Foundation

/// One dictation, kept after the fact. SpeakPaste carried a single transcript
/// in memory, so anything that failed to reach its destination was gone the
/// moment the next dictation replaced it. A record is the copy that outlives
/// that, and it is written whether or not delivery ever succeeded.
struct MacTranscriptRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    /// The application the text was meant for, when one was known. Nil covers
    /// dictations spoken with SpeakPaste itself frontmost, which have nowhere
    /// else to land.
    let destination: String?
    let deviceName: String
    let recordingDuration: TimeInterval
    /// Basename of an optional private, local copy of the original recording.
    /// Paths never enter History: the audio store validates this value against
    /// its own directory before playback or reprocessing.
    let retainedAudioFileName: String?
    /// Links the durable transcript back to the private audio journal entry
    /// that produced it. On launch this closes the crash window between the
    /// History commit and the journal's completion-marker commit.
    let sourcePendingAudioID: UUID?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        destination: String?,
        deviceName: String,
        recordingDuration: TimeInterval,
        retainedAudioFileName: String? = nil,
        sourcePendingAudioID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.destination = destination
        self.deviceName = deviceName
        self.recordingDuration = recordingDuration
        self.retainedAudioFileName = retainedAudioFileName
        self.sourcePendingAudioID = sourcePendingAudioID
    }
}

/// A same-UUID pending transcript may only be reused when it proves the exact
/// same completed dictation. Silently replacing different text would turn a
/// recovery mechanism into data loss.
enum MacHistoryDeliveryEscrowError: LocalizedError, Equatable {
    case identifierCollision(UUID)

    var errorDescription: String? {
        switch self {
        case let .identifierCollision(id):
            "A different pending transcript already uses recovery identifier \(id.uuidString)."
        }
    }
}

/// Commits finished text to the pending-delivery journal before any History
/// mode is allowed to retire source-audio recovery proof or attempt output.
/// Never Store additionally retires its temporary History row once this handoff
/// and the linked audio-consumption receipt are durable.
///
/// The History UUID is deliberately reused. That makes launch recovery
/// idempotent across every crash boundary: a second commit either finds the
/// exact handoff already durable or fails closed without overwriting it.
@MainActor
enum MacHistoryDeliveryEscrow {
    @discardableResult
    static func commit(
        _ record: MacTranscriptRecord,
        destinationBundleIdentifier: String? = nil,
        to store: MacPendingTranscriptStore
    ) throws -> MacPendingTranscript {
        if let existing = store.transcript(withID: record.id) {
            guard
                existing.text == record.text,
                existing.createdAt == record.createdAt
            else {
                throw MacHistoryDeliveryEscrowError.identifierCollision(record.id)
            }
            return existing
        }

        let pending = pendingTranscript(
            for: record,
            destinationBundleIdentifier: destinationBundleIdentifier
        )
        try store.upsert(pending)
        return pending
    }

    /// Commits a launch-recovery set in one pending-transcript document write.
    /// A later collision or filesystem failure must not leave the first half of
    /// the set externally deliverable while all source audio remains retryable.
    /// Existing exact escrows are reused without rewriting the document.
    @discardableResult
    static func commit(
        _ records: [MacTranscriptRecord],
        to store: MacPendingTranscriptStore
    ) throws -> [MacPendingTranscript] {
        guard !records.isEmpty else { return [] }
        var proposedByID = Dictionary(
            uniqueKeysWithValues: store.transcripts.map { ($0.id, $0) }
        )
        var committed: [MacPendingTranscript] = []
        var changed = false

        for record in records {
            if let existing = proposedByID[record.id] {
                guard
                    existing.text == record.text,
                    existing.createdAt == record.createdAt
                else {
                    throw MacHistoryDeliveryEscrowError.identifierCollision(record.id)
                }
                committed.append(existing)
                continue
            }

            let pending = pendingTranscript(
                for: record,
                destinationBundleIdentifier: nil
            )
            proposedByID[record.id] = pending
            committed.append(pending)
            changed = true
        }

        if changed {
            try store.replaceAll(with: Array(proposedByID.values))
        }
        return committed
    }

    /// Replaces every old same-source duplicate escrow with one canonical
    /// History-backed escrow in a single pending-document transition. If any
    /// sibling may already have been delivered, that ambiguity is transferred
    /// to the canonical record before the sibling receipt disappears.
    @discardableResult
    static func canonicalize(
        _ canonicalRecords: [MacTranscriptRecord],
        removing duplicateRecords: [MacTranscriptRecord],
        in store: MacPendingTranscriptStore
    ) throws -> [MacPendingTranscript] {
        guard !canonicalRecords.isEmpty else { return [] }
        var proposedByID = Dictionary(
            uniqueKeysWithValues: store.transcripts.map { ($0.id, $0) }
        )
        let canonicalIDs = Set(canonicalRecords.map(\.id))
        var uncertainSourceIDs = Set<UUID>()

        for record in duplicateRecords where !canonicalIDs.contains(record.id) {
            guard let existing = proposedByID[record.id] else { continue }
            guard
                existing.text == record.text,
                existing.createdAt == record.createdAt
            else {
                throw MacHistoryDeliveryEscrowError.identifierCollision(record.id)
            }
            if existing.deliveryState == .deliveryUncertain,
               let sourceID = record.sourcePendingAudioID {
                uncertainSourceIDs.insert(sourceID)
            }
        }

        var committed: [MacPendingTranscript] = []
        for record in canonicalRecords {
            var pending: MacPendingTranscript
            if let existing = proposedByID[record.id] {
                guard
                    existing.text == record.text,
                    existing.createdAt == record.createdAt
                else {
                    throw MacHistoryDeliveryEscrowError.identifierCollision(record.id)
                }
                pending = existing
            } else {
                pending = pendingTranscript(
                    for: record,
                    destinationBundleIdentifier: nil
                )
            }
            if let sourceID = record.sourcePendingAudioID,
               uncertainSourceIDs.contains(sourceID) {
                pending.deliveryState = .deliveryUncertain
            }
            proposedByID[record.id] = pending
            committed.append(pending)
        }

        for record in duplicateRecords where !canonicalIDs.contains(record.id) {
            proposedByID[record.id] = nil
        }
        let unchanged = proposedByID.count == store.transcripts.count
            && store.transcripts.allSatisfy { proposedByID[$0.id] == $0 }
        if !unchanged {
            try store.replaceAll(with: Array(proposedByID.values))
        }
        return committed
    }

    private static func pendingTranscript(
        for record: MacTranscriptRecord,
        destinationBundleIdentifier: String?
    ) -> MacPendingTranscript {
        let destination = record.destination?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MacPendingTranscript(
            id: record.id,
            text: record.text,
            destinationApplicationName: destination?.isEmpty == false
                ? destination!
                : "SpeakPaste",
            destinationBundleIdentifier: destinationBundleIdentifier,
            createdAt: record.createdAt
        )
    }
}

/// Durable transcript history, newest first.
///
/// Backed by a file rather than UserDefaults, unlike the reliability log next
/// to it: transcripts are unbounded user text, and hundreds of them do not
/// belong in a preferences plist that every launch reads in full.
@MainActor
final class MacHistoryStore: ObservableObject {
    @Published private(set) var records: [MacTranscriptRecord] = []
    @Published private(set) var lastPersistenceError: String? = nil

    /// Days of history to keep. `-1` is never-store and zero is forever.
    /// Never-store still permits a source-linked row while the pending-audio
    /// completion transaction is open; the row disappears as soon as that
    /// private recovery proof is no longer required.
    @Published var retentionDays: Int {
        didSet {
            guard retentionDays != oldValue else { return }
            // Assigning here does not re-enter `didSet`, so the clamped value
            // has to be written through on this pass or a negative setting
            // would show as "Forever" while the old number stayed on disk.
            if retentionDays < -1 {
                retentionDays = -1
            }
            defaults.set(retentionDays, forKey: Self.retentionDaysKey)
            sweepExpired()
        }
    }

    /// A ceiling on how much is kept, so a heavy dictation habit cannot grow
    /// the file without bound. Retention expires records by age; this expires
    /// them by count.
    static let maximumRecords = 500

    private let defaults: UserDefaults
    /// Nil when Application Support cannot be resolved. Mutations then fail
    /// visibly instead of publishing a history state that was never durable.
    private let fileURL: URL?
    /// A pre-existing document that we could not completely understand is
    /// never a blank history. Keep the readable subset visible, but refuse to
    /// replace the source file until the user has moved it out of the way.
    private var blockedExistingDocumentReason: String? = nil
    /// True only after this process loaded a complete current History document
    /// or successfully persisted one. A missing file is not positive proof of
    /// an empty history when pending completion markers say text once existed.
    private var hasDurableDocument = false

    /// Pending-audio completion markers may be retired only when History was
    /// fully understood and has a real persistence destination. An empty list
    /// recovered from corrupt/future bytes, or from unavailable Application
    /// Support, is not authority to delete the audio that may be its only
    /// remaining recoverable source.
    var isPendingAudioRecoveryAuthorityTrusted: Bool {
        fileURL != nil
            && blockedExistingDocumentReason == nil
            && hasDurableDocument
    }

    /// Establishes an explicit empty History document before a user-requested
    /// privacy action removes retained successful audio. A missing file on a
    /// fresh install is not trusted automatically, because recovery markers
    /// may still need it; the user's direct Never-store/retention-off action is
    /// the boundary that authorizes creating the empty document. Corrupt,
    /// future, permission-blocked, or non-regular existing documents remain
    /// untouched and continue to block cleanup.
    @discardableResult
    func establishDurableDocumentForExplicitPrivacyAction() -> Bool {
        if isPendingAudioRecoveryAuthorityTrusted { return true }
        guard records.isEmpty else { return false }
        return persist([])
    }

    var referencedAudioFileNames: Set<String> {
        Set(records.compactMap(\.retainedAudioFileName))
    }

    private static let retentionDaysKey = "mac-history-retention-days"
    private static let defaultRetentionDays = 30

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        let directory = directory ?? Self.applicationSupportDirectory
        fileURL = directory?.appendingPathComponent("history.json", isDirectory: false)
        // `object(forKey:)` rather than `integer(forKey:)`, because an unset
        // key reads back as 0 and 0 already means "keep forever".
        let stored = defaults.object(forKey: Self.retentionDaysKey) as? Int
        retentionDays = max(-1, stored ?? Self.defaultRetentionDays)
        let loaded = Self.loadRecords(at: fileURL)
        let permissionWarning: String?
        if loaded.blockedExistingDocumentReason == nil {
            do {
                try MacPrivateStoreIO.secureExistingStorage(at: fileURL)
                permissionWarning = nil
            } catch {
                permissionWarning = "Could not secure transcript history: \(error.localizedDescription)"
            }
        } else {
            // Do not chmod an unreadable path or follow a symbolic link merely
            // because the app launched. Preservation includes metadata and the
            // bytes outside SpeakPaste's ownership boundary.
            permissionWarning = nil
        }
        records = loaded.records
        hasDurableDocument = loaded.hasValidDocument
        blockedExistingDocumentReason = loaded.blockedExistingDocumentReason
            ?? permissionWarning
        lastPersistenceError = [permissionWarning, loaded.warning]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty
        // Launch retention is coordinated by AppModel after any completion
        // markers have been reconciled and cleaned. Sweeping here could remove
        // an unlinked row in the crash window before its marker is authorized.
    }

    /// Records the dictation. Held transcripts are appended when they finally
    /// land, which can be after a later dictation already did, so position is
    /// decided by when the audio was captured rather than by arrival order.
    @discardableResult
    func append(_ record: MacTranscriptRecord) -> Bool {
        var proposed = records
        let index = proposed.firstIndex { $0.createdAt <= record.createdAt } ?? proposed.count
        proposed.insert(record, at: index)
        // SpeakPaste is meant to stay running for weeks, so sweeping only at
        // launch would quietly stretch a 30-day promise to however long the Mac
        // has been awake.
        proposed = recordsWithinAutomaticLimits(proposed)
        guard persist(proposed) else { return false }
        records = proposed
        return true
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard let record = records.first(where: { $0.id == id }) else { return false }
        guard record.sourcePendingAudioID == nil else {
            lastPersistenceError = "This transcript still protects recovery audio and cannot be deleted until that audio is safely acknowledged."
            return false
        }
        let remaining = records.filter { $0.id != id }
        guard persist(remaining) else { return false }
        records = remaining
        return true
    }

    @discardableResult
    func updateText(_ id: UUID, to text: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        let current = records[index]
        var proposed = records
        proposed[index] = MacTranscriptRecord(
            id: current.id,
            createdAt: current.createdAt,
            text: text,
            destination: current.destination,
            deviceName: current.deviceName,
            recordingDuration: current.recordingDuration,
            retainedAudioFileName: current.retainedAudioFileName,
            sourcePendingAudioID: current.sourcePendingAudioID
        )
        guard persist(proposed) else { return false }
        records = proposed
        return true
    }

    /// The user's one-click purge, so it has to actually erase: emptying the
    /// array while the file still holds every transcript would be a privacy
    /// promise the app does not keep.
    @discardableResult
    func deleteAll() -> Bool {
        guard records.allSatisfy({ $0.sourcePendingAudioID == nil }) else {
            lastPersistenceError = "Some transcripts still protect recovery audio and cannot be purged until that audio is safely acknowledged."
            return false
        }
        // Persist the empty document before publishing the empty list. If the
        // filesystem refuses the privacy action, the UI must continue showing
        // the records that are still readable on disk.
        guard persist([]) else { return false }
        records = []
        return true
    }

    /// Clears durable cross-store proof only after the pending-audio marker is
    /// committed. The rows themselves deliberately remain until exact-ID audio
    /// cleanup finishes; retention is resumed in a later durable transaction.
    @discardableResult
    func clearSourcePendingAudioLinks(_ pendingAudioIDs: Set<UUID>) -> Bool {
        guard !pendingAudioIDs.isEmpty else { return true }
        var changed = false
        let unlinked = records.map { record -> MacTranscriptRecord in
            guard
                let sourceID = record.sourcePendingAudioID,
                pendingAudioIDs.contains(sourceID)
            else {
                return record
            }
            changed = true
            return MacTranscriptRecord(
                id: record.id,
                createdAt: record.createdAt,
                text: record.text,
                destination: record.destination,
                deviceName: record.deviceName,
                recordingDuration: record.recordingDuration,
                retainedAudioFileName: record.retainedAudioFileName,
                sourcePendingAudioID: nil
            )
        }
        guard changed else { return true }
        guard persist(unlinked) else { return false }
        records = unlinked
        return true
    }

    /// `localizedStandardContains` is the case-, diacritic- and width-
    /// insensitive comparison Finder uses, so "cafe" finds "café" and a Spanish
    /// dictation is searchable from an unaccented keyboard.
    func search(_ query: String) -> [MacTranscriptRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter { record in
            record.text.localizedStandardContains(trimmed)
                || record.destination?.localizedStandardContains(trimmed) == true
        }
    }

    /// Removes local-audio links only after the audio files themselves have
    /// been deleted or scheduled for orphan cleanup by the app coordinator.
    @discardableResult
    func clearRetainedAudioReferences() -> Bool {
        guard records.contains(where: { $0.retainedAudioFileName != nil }) else { return true }
        let proposed = records.map { record in
            MacTranscriptRecord(
                id: record.id,
                createdAt: record.createdAt,
                text: record.text,
                destination: record.destination,
                deviceName: record.deviceName,
                recordingDuration: record.recordingDuration,
                retainedAudioFileName: nil,
                sourcePendingAudioID: record.sourcePendingAudioID
            )
        }
        guard persist(proposed) else { return false }
        records = proposed
        return true
    }

    /// Repairs one row when a provisional successful-audio copy disappears
    /// before it can be published. The transcript remains durable; only the
    /// optional playback link is removed.
    @discardableResult
    func clearRetainedAudioReference(for id: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        let current = records[index]
        guard current.retainedAudioFileName != nil else { return true }
        var proposed = records
        proposed[index] = MacTranscriptRecord(
            id: current.id,
            createdAt: current.createdAt,
            text: current.text,
            destination: current.destination,
            deviceName: current.deviceName,
            recordingDuration: current.recordingDuration,
            retainedAudioFileName: nil,
            sourcePendingAudioID: current.sourcePendingAudioID
        )
        guard persist(proposed) else { return false }
        records = proposed
        return true
    }

    /// Day arithmetic goes through Calendar rather than a multiple of 86 400 so
    /// that a daylight-saving shift cannot expire a record an hour early.
    private func sweepExpired() {
        _ = applyAutomaticLimits()
    }

    @discardableResult
    func applyAutomaticLimits() -> Bool {
        let proposed = recordsWithinAutomaticLimits(records)
        guard proposed != records else { return true }
        guard persist(proposed) else { return false }
        records = proposed
        return true
    }

    private func recordsWithinAutomaticLimits(
        _ candidates: [MacTranscriptRecord]
    ) -> [MacTranscriptRecord] {
        let ageEligible: [MacTranscriptRecord]
        if retentionDays == -1 {
            ageEligible = candidates.filter { $0.sourcePendingAudioID != nil }
        } else if retentionDays > 0,
           let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) {
            ageEligible = candidates.filter {
                $0.sourcePendingAudioID != nil || $0.createdAt >= cutoff
            }
        } else {
            ageEligible = candidates
        }

        let protectedCount = ageEligible.lazy.filter { $0.sourcePendingAudioID != nil }.count
        let unprotectedAllowance = max(0, Self.maximumRecords - protectedCount)
        var keptUnprotected = 0
        return ageEligible.filter { record in
            if record.sourcePendingAudioID != nil { return true }
            guard keptUnprotected < unprotectedAllowance else { return false }
            keptUnprotected += 1
            return true
        }
    }

    /// A failed write never publishes the prospective state. Callers can keep
    /// the source audio or edited text recoverable and the UI continues to
    /// describe exactly what the durable document contains.
    @discardableResult
    private func persist(_ proposed: [MacTranscriptRecord]) -> Bool {
        guard let fileURL else {
            lastPersistenceError = "Application Support is unavailable."
            return false
        }

        if let blockedExistingDocumentReason {
            // An explicit move/delete outside SpeakPaste is the recovery
            // boundary. Replacing the file in place is not enough: this store
            // loaded neither the replacement nor its authority to overwrite.
            let existingFileWasRemoved: Bool
            do {
                existingFileWasRemoved = try !MacPrivateStoreIO
                    .existingRegularFileIsPresent(at: fileURL)
            } catch {
                existingFileWasRemoved = false
            }
            guard existingFileWasRemoved else {
                lastPersistenceError = blockedExistingDocumentReason
                return false
            }
            self.blockedExistingDocumentReason = nil
        }
        do {
            let data = try JSONEncoder().encode(proposed)
            try MacPrivateStoreIO.writeAtomically(data, to: fileURL)
            hasDurableDocument = true
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = error.localizedDescription
            return false
        }
    }

    private static func loadRecords(at url: URL?) -> HistoryLoadResult {
        guard let url else {
            return HistoryLoadResult(records: [], warning: nil, blockedExistingDocumentReason: nil)
        }
        let data: Data
        do {
            guard let loaded = try MacPrivateStoreIO.readExistingData(at: url) else {
                return HistoryLoadResult(
                    records: [],
                    warning: nil,
                    blockedExistingDocumentReason: nil
                )
            }
            data = loaded
        } catch {
            let boundaryWasUnsafe = (error as NSError).domain == NSPOSIXErrorDomain
                && (error as NSError).code == Int(ELOOP)
            let warning = boundaryWasUnsafe
                ? "Transcript history storage was unsafe because it is not a regular file; it was left untouched and history changes are blocked."
                : "Transcript history could not be read; it was left untouched and history changes are blocked."
            return HistoryLoadResult(
                records: [],
                warning: warning,
                blockedExistingDocumentReason: warning
            )
        }

        let decoder = JSONDecoder()
        if let probe = try? decoder.decode(HistorySchemaProbe.self, from: data),
           probe.hasDocumentShape {
            let warning: String
            if let schemaVersion = probe.schemaVersion {
                warning = "Transcript history uses unsupported schema \(schemaVersion); it was left untouched and history changes are blocked."
            } else {
                warning = "Transcript history uses an unsupported document format; it was left untouched and history changes are blocked."
            }
            return HistoryLoadResult(
                records: [],
                warning: warning,
                blockedExistingDocumentReason: warning
            )
        }

        if let decoded = try? decoder.decode([MacTranscriptRecord].self, from: data) {
            guard let unknownFieldCount = unsupportedRecordFieldCount(in: data) else {
                let warning = "Transcript history structure could not be verified; it was left untouched and history changes are blocked."
                return HistoryLoadResult(
                    records: decoded,
                    warning: warning,
                    blockedExistingDocumentReason: warning
                )
            }
            if unknownFieldCount > 0 {
                let warning = "Recovered transcript history with unsupported record fields; the file was left untouched and history changes are blocked."
                return HistoryLoadResult(
                    records: decoded,
                    warning: warning,
                    blockedExistingDocumentReason: warning
                )
            }
            return HistoryLoadResult(
                records: decoded,
                warning: nil,
                blockedExistingDocumentReason: nil,
                hasValidDocument: true
            )
        }

        if let recovered = try? decoder.decode(LossyHistoryRecordList.self, from: data),
           recovered.droppedCount > 0 {
            let count = recovered.droppedCount
            let warning = "Recovered the readable transcript history but found \(count) damaged entr\(count == 1 ? "y" : "ies"); the file was left untouched and history changes are blocked."
            return HistoryLoadResult(
                records: recovered.values,
                warning: warning,
                blockedExistingDocumentReason: warning
            )
        }

        let warning = "Transcript history was unreadable; it was left untouched and history changes are blocked."
        return HistoryLoadResult(
            records: [],
            warning: warning,
            blockedExistingDocumentReason: warning
        )
    }

    private static var applicationSupportDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SpeakPaste", isDirectory: true)
    }

    /// Synthesized Codable intentionally ignores unknown keys. That is useful
    /// for network payloads but unsafe for an owned document: an older build
    /// would load a future record and strip its new fields on the next append.
    private static func unsupportedRecordFieldCount(in data: Data) -> Int? {
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let supportedKeys: Set<String> = [
            "id",
            "text",
            "createdAt",
            "destination",
            "deviceName",
            "recordingDuration",
            "retainedAudioFileName",
            "sourcePendingAudioID",
        ]
        return objects.reduce(into: 0) { count, object in
            if !Set(object.keys).isSubset(of: supportedKeys) {
                count += 1
            }
        }
    }
}

private struct HistoryLoadResult {
    let records: [MacTranscriptRecord]
    let warning: String?
    let blockedExistingDocumentReason: String?
    let hasValidDocument: Bool

    init(
        records: [MacTranscriptRecord],
        warning: String?,
        blockedExistingDocumentReason: String?,
        hasValidDocument: Bool = false
    ) {
        self.records = records
        self.warning = warning
        self.blockedExistingDocumentReason = blockedExistingDocumentReason
        self.hasValidDocument = hasValidDocument
    }
}

/// This probe exists only to recognize versioned/object-shaped documents as a
/// different format. SpeakPaste's current and legacy history format is the
/// top-level record array; guessing at the meaning of a future object would be
/// less safe than preserving it for a newer build.
private struct HistorySchemaProbe: Decodable {
    let schemaVersion: Int?
    let hasDocumentShape: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
        case history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        hasDocumentShape = container.contains(.schemaVersion)
            || container.contains(.records)
            || container.contains(.history)
    }
}

/// Decodes every array element independently. A single hand-edited or damaged
/// record can therefore be shown and copied around without granting permission
/// to rewrite the rest of the original file.
private struct LossyHistoryRecordList: Decodable {
    let values: [MacTranscriptRecord]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [MacTranscriptRecord] = []
        var droppedCount = 0
        while !container.isAtEnd {
            let wrapper = try container.decode(LossyHistoryRecord.self)
            if let value = wrapper.value {
                values.append(value)
            } else {
                droppedCount += 1
            }
        }
        self.values = values
        self.droppedCount = droppedCount
    }
}

private struct LossyHistoryRecord: Decodable {
    let value: MacTranscriptRecord?

    init(from decoder: Decoder) throws {
        value = try? MacTranscriptRecord(from: decoder)
    }
}

enum MacHistoryAudioStoreError: LocalizedError {
    case unsupportedAudioType
    case unsafeFileName
    case audioMissing
    case unsafeAudioSource
    case retainedAudioQuotaExceeded(limitBytes: Int64)
    case insufficientFreeSpace(requiredBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioType:
            "The recording format cannot be retained in History."
        case .unsafeFileName:
            "History contained an unsafe audio filename."
        case .audioMissing:
            "The retained recording is no longer available."
        case .unsafeAudioSource:
            "The recording could not be measured safely before retaining it in History."
        case let .retainedAudioQuotaExceeded(limitBytes):
            "This recording would exceed SpeakPaste's \(Self.byteCount(limitBytes)) retained History-audio limit."
        case let .insufficientFreeSpace(requiredBytes, availableBytes):
            "This recording was not retained because SpeakPaste needs \(Self.byteCount(requiredBytes)) of free disk space before copying it; \(Self.byteCount(max(availableBytes, 0))) is available."
        }
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// Private successful-audio storage used only when the user keeps History
/// audio. It is intentionally separate from PendingAudio: the latter is a
/// recovery authority and may not be repurposed as a media library after its
/// completion transaction closes.
final class MacHistoryAudioStore: @unchecked Sendable {
    typealias AvailableCapacityProvider = @Sendable (URL) throws -> Int64

    /// Successful recordings are useful, but they must never become an
    /// unbounded media cache. One GiB is intentionally conservative while
    /// still allowing many ordinary dictations to retain their source audio.
    static let maximumRetainedHistoryAudioBytes: Int64 = 1 * 1_024 * 1_024 * 1_024

    /// Do not spend the last usable disk space on an optional History copy.
    static let minimumFreeSpaceAfterRetentionBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    let directoryURL: URL
    private let retainedAudioByteQuota: Int64
    private let freeSpaceReserveBytes: Int64
    private let availableCapacityProvider: AvailableCapacityProvider
    private let lock = NSLock()
    private var persistenceError: String?
    /// A detached copy exists before its History row can be committed on the
    /// main actor. Reconciliation must not classify that short-lived file as
    /// an orphan. The set is process-local on purpose: after a crash, launch
    /// reconciliation should remove any copy that never gained a durable row.
    private var provisionalFileNames = Set<String>()

    var lastPersistenceError: String? {
        withLock { persistenceError }
    }

    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "mp4", "mov", "ogg", "opus", "flac", "aac",
        "aif", "aiff", "caf", "webm", "mkv", "mpeg", "mpg", "3gp", "3gpp",
        "wma", "amr",
    ]

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumRetainedHistoryAudioBytes: Int64 = MacHistoryAudioStore.maximumRetainedHistoryAudioBytes,
        minimumFreeSpaceAfterRetentionBytes: Int64 = MacHistoryAudioStore.minimumFreeSpaceAfterRetentionBytes,
        availableCapacityProvider: AvailableCapacityProvider? = nil
    ) {
        let applicationSupportURL = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.directoryURL = directoryURL
            ?? applicationSupportURL
                .appendingPathComponent("SpeakPaste", isDirectory: true)
                .appendingPathComponent("HistoryAudio", isDirectory: true)
        retainedAudioByteQuota = max(maximumRetainedHistoryAudioBytes, 0)
        freeSpaceReserveBytes = max(minimumFreeSpaceAfterRetentionBytes, 0)
        self.availableCapacityProvider = availableCapacityProvider
            ?? MacHistoryAudioStore.defaultAvailableCapacity
        do {
            try ensurePrivateDirectory()
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    /// Makes a durable copy while PendingAudio still owns the source. The
    /// History record is committed only after this succeeds, so a referenced
    /// retained file is never merely aspirational.
    func retain(sourceURL: URL, historyRecordID: UUID) throws -> String {
        try withLock {
            do {
                let extensionName = sourceURL.pathExtension.lowercased()
                guard Self.audioExtensions.contains(extensionName) else {
                    throw MacHistoryAudioStoreError.unsupportedAudioType
                }
                try ensurePrivateDirectory()
                let fileName = "\(historyRecordID.uuidString.lowercased()).\(extensionName)"
                let destinationURL = try safeAudioURL(for: fileName, requireExisting: false)
                let sourceBytes = try Self.regularFileSize(at: sourceURL)
                try verifyRetentionCapacity(sourceBytes: sourceBytes)
                try MacPrivateStoreIO.copyRegularFile(from: sourceURL, to: destinationURL)
                provisionalFileNames.insert(fileName.lowercased())
                persistenceError = nil
                return fileName
            } catch {
                persistenceError = error.localizedDescription
                throw error
            }
        }
    }

    /// Publishes a retained copy only after the History row that references it
    /// is durable. Until this call, ordinary History reconciliation skips it.
    @discardableResult
    func publish(_ fileName: String) -> Bool {
        withLock {
            let normalized = fileName.precomposedStringWithCanonicalMapping.lowercased()
            guard provisionalFileNames.remove(normalized) != nil else {
                persistenceError = "The retained audio copy was not awaiting publication."
                return false
            }
            do {
                _ = try safeAudioURL(for: fileName, requireExisting: true)
                persistenceError = nil
                return true
            } catch {
                persistenceError = error.localizedDescription
                return false
            }
        }
    }

    func audioURL(for fileName: String) throws -> URL {
        try withLock {
            try safeAudioURL(for: fileName, requireExisting: true)
        }
    }

    @discardableResult
    func remove(_ fileName: String) -> Bool {
        withLock {
            provisionalFileNames.remove(
                fileName.precomposedStringWithCanonicalMapping.lowercased()
            )
            do {
                let url = try safeAudioURL(for: fileName, requireExisting: false)
                _ = try MacPrivateStoreIO.removeRegularFile(at: url)
                persistenceError = nil
                return true
            } catch {
                persistenceError = error.localizedDescription
                return false
            }
        }
    }

    /// Removes only files whose basename is a History UUID. Unknown regular
    /// files are left untouched instead of treating directory ownership as
    /// permission to erase data this build does not understand.
    @discardableResult
    func reconcile(referencedFileNames: Set<String>) -> Bool {
        withLock {
            do {
                try ensurePrivateDirectory()
                let normalizedReferences = Set(
                    referencedFileNames.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
                )
                for entry in try MacPrivateStoreIO.regularFileEntries(in: directoryURL) {
                    let normalized = entry.name.precomposedStringWithCanonicalMapping.lowercased()
                    guard
                        !normalizedReferences.contains(normalized),
                        !provisionalFileNames.contains(normalized),
                        Self.isManagedFileName(entry.name)
                    else {
                        continue
                    }
                    let url = try safeAudioURL(for: entry.name, requireExisting: true)
                    _ = try MacPrivateStoreIO.removeRegularFile(at: url)
                }
                persistenceError = nil
                return true
            } catch {
                persistenceError = error.localizedDescription
                return false
            }
        }
    }

    private func verifyRetentionCapacity(sourceBytes: Int64) throws {
        let managedBytes = try managedRetainedAudioBytes()
        let (projectedBytes, quotaOverflow) = managedBytes.addingReportingOverflow(sourceBytes)
        guard
            !quotaOverflow,
            sourceBytes <= retainedAudioByteQuota,
            projectedBytes <= retainedAudioByteQuota
        else {
            throw MacHistoryAudioStoreError.retainedAudioQuotaExceeded(
                limitBytes: retainedAudioByteQuota
            )
        }

        let availableBytes = try availableCapacityProvider(directoryURL)
        let (requiredBytes, capacityOverflow) = sourceBytes.addingReportingOverflow(
            freeSpaceReserveBytes
        )
        guard !capacityOverflow, availableBytes >= requiredBytes else {
            throw MacHistoryAudioStoreError.insufficientFreeSpace(
                requiredBytes: capacityOverflow ? Int64.max : requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    /// Counts only this schema's regular, single-link UUID audio entries. The
    /// directory and each entry are inspected with no-follow syscalls, so an
    /// unknown file or managed-looking symlink can neither consume the quota
    /// nor redirect accounting outside the owned directory.
    private func managedRetainedAudioBytes() throws -> Int64 {
        let entries = try MacPrivateStoreIO.regularFileEntries(in: directoryURL)
            .filter { Self.isManagedFileName($0.name) }
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw Self.posixError(path: directoryURL.path)
        }
        defer { Darwin.close(directoryDescriptor) }

        var totalBytes: Int64 = 0
        for entry in entries {
            var status = stat()
            let result = entry.name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else {
                if errno == ENOENT { continue }
                throw Self.posixError(
                    path: directoryURL.appendingPathComponent(entry.name).path
                )
            }
            guard
                (status.st_mode & S_IFMT) == S_IFREG,
                status.st_nlink == 1,
                status.st_size >= 0
            else {
                continue
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(Int64(status.st_size))
            guard !overflow else {
                throw MacHistoryAudioStoreError.retainedAudioQuotaExceeded(
                    limitBytes: retainedAudioByteQuota
                )
            }
            totalBytes = nextTotal
        }
        return totalBytes
    }

    private func ensurePrivateDirectory() throws {
        try MacPrivateStoreIO.ensurePrivateDirectory(at: directoryURL.deletingLastPathComponent())
        try MacPrivateStoreIO.ensurePrivateDirectory(at: directoryURL)
    }

    private func safeAudioURL(for fileName: String, requireExisting: Bool) throws -> URL {
        guard Self.isManagedFileName(fileName) else {
            throw MacHistoryAudioStoreError.unsafeFileName
        }
        let url = directoryURL
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        guard url.deletingLastPathComponent() == directoryURL.standardizedFileURL else {
            throw MacHistoryAudioStoreError.unsafeFileName
        }
        if requireExisting,
           try !MacPrivateStoreIO.existingRegularFileIsPresent(at: url) {
            throw MacHistoryAudioStoreError.audioMissing
        }
        return url
    }

    private static func isManagedFileName(_ fileName: String) -> Bool {
        guard
            !fileName.isEmpty,
            fileName == URL(fileURLWithPath: fileName).lastPathComponent,
            audioExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
        else {
            return false
        }
        return UUID(
            uuidString: URL(fileURLWithPath: fileName)
                .deletingPathExtension()
                .lastPathComponent
        ) != nil
    }

    private static func regularFileSize(at sourceURL: URL) throws -> Int64 {
        let sourceName = sourceURL.lastPathComponent
        guard
            !sourceName.isEmpty,
            sourceName != ".",
            sourceName != "..",
            sourceName == URL(fileURLWithPath: sourceName).lastPathComponent
        else {
            throw MacHistoryAudioStoreError.unsafeAudioSource
        }

        let sourceDirectoryURL = sourceURL.deletingLastPathComponent()
        let sourceDirectoryDescriptor = Darwin.open(
            sourceDirectoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDirectoryDescriptor >= 0 else {
            if errno == ELOOP {
                throw MacHistoryAudioStoreError.unsafeAudioSource
            }
            throw posixError(path: sourceDirectoryURL.path)
        }
        defer { Darwin.close(sourceDirectoryDescriptor) }

        let sourceDescriptor = sourceName.withCString {
            Darwin.openat(
                sourceDirectoryDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard sourceDescriptor >= 0 else {
            if errno == ELOOP {
                throw MacHistoryAudioStoreError.unsafeAudioSource
            }
            throw posixError(path: sourceURL.path)
        }
        defer { Darwin.close(sourceDescriptor) }

        var status = stat()
        guard Darwin.fstat(sourceDescriptor, &status) == 0 else {
            throw posixError(path: sourceURL.path)
        }
        guard
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_nlink == 1,
            status.st_size >= 0
        else {
            throw MacHistoryAudioStoreError.unsafeAudioSource
        }
        return Int64(status.st_size)
    }

    private static func defaultAvailableCapacity(at directoryURL: URL) throws -> Int64 {
        // Retained audio is optional storage, so use currently free capacity
        // rather than the more permissive "important usage" estimate that can
        // include space macOS might reclaim from other applications.
        let values = try directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: directoryURL.path
        )
        if let capacity = attributes[.systemFreeSize] as? NSNumber {
            return capacity.int64Value
        }
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [
                NSFilePathErrorKey: directoryURL.path,
                NSLocalizedDescriptionKey: "Available disk space could not be determined safely.",
            ]
        )
    }

    private static func posixError(path: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
