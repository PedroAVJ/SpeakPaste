import Combine
import Darwin
import Foundation

enum MacPendingTranscriptStoreError: LocalizedError {
    case applicationSupportUnavailable
    case existingDocumentRequiresRecovery(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is unavailable."
        case let .existingDocumentRequiresRecovery(message):
            message
        }
    }
}

/// The durable subset of a held transcript.
///
/// Accessibility elements are process-local handles and are intentionally not
/// represented here. A restored value names its former destination for the
/// user, but it grants no authority to deliver there after a restart.
enum MacPendingTranscriptDeliveryState: String, Codable, Equatable, Sendable {
    /// No external paste side effect has started, so retrying is safe.
    case pending
    /// Persisted before attempting a paste. A crash or failed cleanup may mean
    /// the text already reached its destination; automatic/manual retry must
    /// require the user to verify and explicitly accept duplicate risk.
    case deliveryUncertain
}

struct MacPendingTranscript: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var destinationApplicationName: String
    var destinationBundleIdentifier: String?
    let createdAt: Date
    var deliveryState: MacPendingTranscriptDeliveryState

    init(
        id: UUID = UUID(),
        text: String,
        destinationApplicationName: String,
        destinationBundleIdentifier: String?,
        createdAt: Date = Date(),
        deliveryState: MacPendingTranscriptDeliveryState = .pending
    ) {
        self.id = id
        self.text = text
        self.destinationApplicationName = destinationApplicationName
        self.destinationBundleIdentifier = destinationBundleIdentifier
        self.createdAt = createdAt
        self.deliveryState = deliveryState
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case destinationApplicationName
        case destinationBundleIdentifier
        // Compatibility aliases make a hand-written or early prototype file
        // recoverable without weakening the canonical encoded representation.
        case destinationAppName
        case destinationBundleID
        case applicationName
        case bundleIdentifier
        case createdAt
        case deliveryState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        destinationApplicationName = try container.decodeIfPresent(
            String.self,
            forKey: .destinationApplicationName
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .destinationAppName
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .applicationName
        ) ?? "Unknown app"
        destinationBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .destinationBundleIdentifier
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .destinationBundleID
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .bundleIdentifier
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deliveryState = try container.decodeIfPresent(
            MacPendingTranscriptDeliveryState.self,
            forKey: .deliveryState
        ) ?? .pending
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(destinationApplicationName, forKey: .destinationApplicationName)
        try container.encodeIfPresent(
            destinationBundleIdentifier,
            forKey: .destinationBundleIdentifier
        )
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(deliveryState, forKey: .deliveryState)
    }
}

/// Private pasteboard provenance for the one held transcript that can be
/// recovered with Command-V. The exact durable identity prevents duplicate
/// text from being mistaken for ownership, while `clipboardPayload` captures
/// any delivery-time seam fitting applied to the source text.
struct MacHeldClipboardIdentity: Codable, Equatable, Sendable {
    let transcriptID: UUID
    let createdAt: Date
    let sourceText: String
}

struct MacHeldClipboardClaim: Codable, Equatable, Sendable {
    let owner: MacHeldClipboardIdentity
    let clipboardPayload: String
}

enum MacHeldClipboardClaimResolver {
    static func ownerID(
        for claim: MacHeldClipboardClaim?,
        clipboardText: String?,
        heldIdentities: [MacHeldClipboardIdentity]
    ) -> UUID? {
        guard
            let claim,
            clipboardText == claim.clipboardPayload,
            heldIdentities.contains(claim.owner)
        else {
            return nil
        }
        return claim.owner.transcriptID
    }
}

/// Crash- and quit-resistant storage for transcripts awaiting explicit action.
///
/// Loading this store never schedules delivery and never reconstructs a
/// `MacDeliveryTarget`. Restored entries are safe recovery data; a later UI or
/// model integration must require the user to release, copy, or discard them.
@MainActor
final class MacPendingTranscriptStore: ObservableObject {
    @Published private(set) var transcripts: [MacPendingTranscript]
    @Published private(set) var lastPersistenceError: String?

    private let fileURL: URL?
    /// A readable subset may still be useful recovery data, but it is not
    /// authority to replace an existing document we could not fully interpret.
    private var blockedExistingDocumentReason: String?

    /// `directory` makes reload and corruption behavior testable in a scratch
    /// folder rather than the real Application Support container.
    init(directory: URL? = nil) {
        let resolvedFileURL = Self.makeFileURL(in: directory)
        fileURL = resolvedFileURL

        let loaded = Self.load(from: resolvedFileURL)
        let permissionWarning: String?
        if loaded.blockedExistingDocumentReason == nil {
            do {
                try MacPrivateStoreIO.secureExistingStorage(at: resolvedFileURL)
                permissionWarning = nil
            } catch {
                permissionWarning = "Could not secure pending-transcript storage: \(error.localizedDescription)"
            }
        } else {
            // Never chmod an unreadable entry or follow a symbolic link merely
            // because SpeakPaste launched. The untrusted source stays wholly
            // outside the app's write boundary.
            permissionWarning = nil
        }

        transcripts = loaded.transcripts
        blockedExistingDocumentReason = loaded.blockedExistingDocumentReason
            ?? permissionWarning
        let messages = [permissionWarning, loaded.warning].compactMap { $0 }
        lastPersistenceError = messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    func transcript(withID id: UUID) -> MacPendingTranscript? {
        transcripts.first { $0.id == id }
    }

    /// Appends a newly held transcript and returns its durable identity.
    @discardableResult
    func append(
        text: String,
        destinationApplicationName: String,
        destinationBundleIdentifier: String?,
        createdAt: Date = Date()
    ) throws -> MacPendingTranscript {
        let transcript = MacPendingTranscript(
            text: text,
            destinationApplicationName: destinationApplicationName,
            destinationBundleIdentifier: destinationBundleIdentifier,
            createdAt: createdAt
        )
        try upsert(transcript)
        return transcript
    }

    /// Creates or replaces by UUID. Ordering remains oldest-first so explicit
    /// release can preserve the order in which the user spoke.
    func upsert(_ transcript: MacPendingTranscript) throws {
        let transcript = Self.normalized(transcript)
        var proposed = transcripts
        if let index = proposed.firstIndex(where: { $0.id == transcript.id }) {
            proposed[index] = transcript
        } else {
            proposed.append(transcript)
        }
        proposed = Self.sorted(proposed)
        try persist(proposed)
        transcripts = proposed
    }

    @discardableResult
    func remove(_ id: UUID) throws -> Bool {
        try remove(Set([id])).contains(id)
    }

    /// Removes exactly the reviewed queue entries in one document transition.
    /// Other escrows may belong to later dictations that are still waiting for
    /// ordered delivery and must survive a visible queue action.
    @discardableResult
    func remove(_ identifiers: Set<UUID>) throws -> Set<UUID> {
        guard !identifiers.isEmpty else { return [] }
        let removed = Set(
            transcripts.lazy.filter { identifiers.contains($0.id) }.map(\.id)
        )
        guard !removed.isEmpty else { return [] }
        let remaining = transcripts.filter { !removed.contains($0.id) }
        try persist(remaining)
        transcripts = remaining
        return removed
    }

    /// Replaces the queue in one write. Duplicate UUIDs collapse with the last
    /// supplied value winning, matching an edit made after the original hold.
    func replaceAll(with transcripts: [MacPendingTranscript]) throws {
        var byID: [UUID: MacPendingTranscript] = [:]
        for transcript in transcripts {
            byID[transcript.id] = Self.normalized(transcript)
        }
        let proposed = Self.sorted(Array(byID.values))
        try persist(proposed)
        self.transcripts = proposed
    }

    /// Persists the ambiguity boundary before any external paste side effect.
    /// All requested records transition in one document write or none do.
    func setDeliveryState(
        _ state: MacPendingTranscriptDeliveryState,
        for identifiers: Set<UUID>
    ) throws {
        guard !identifiers.isEmpty else { return }
        var found = Set<UUID>()
        let proposed = transcripts.map { transcript -> MacPendingTranscript in
            guard identifiers.contains(transcript.id) else { return transcript }
            found.insert(transcript.id)
            var updated = transcript
            updated.deliveryState = state
            return updated
        }
        guard found == identifiers else {
            throw CocoaError(.fileNoSuchFile)
        }
        try persist(proposed)
        transcripts = proposed
    }

    func removeAll() throws {
        // Persist even when memory is empty so a trusted queue is durably
        // cleared. An untrusted existing document remains protected below.
        try persist([])
        transcripts = []
    }

    private func persist(_ proposed: [MacPendingTranscript]) throws {
        guard let fileURL else {
            lastPersistenceError = "Application Support is unavailable."
            throw MacPendingTranscriptStoreError.applicationSupportUnavailable
        }

        if let blockedExistingDocumentReason {
            let existingFileWasRemoved: Bool
            do {
                existingFileWasRemoved = try !MacPrivateStoreIO
                    .existingRegularFileIsPresent(at: fileURL)
            } catch {
                existingFileWasRemoved = false
            }
            guard existingFileWasRemoved else {
                lastPersistenceError = blockedExistingDocumentReason
                throw MacPendingTranscriptStoreError.existingDocumentRequiresRecovery(
                    blockedExistingDocumentReason
                )
            }
            self.blockedExistingDocumentReason = nil
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                StoredPendingTranscripts(schemaVersion: 1, transcripts: proposed)
            )
            try MacPrivateStoreIO.writeAtomically(data, to: fileURL)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            throw error
        }
    }

    private static func load(from fileURL: URL?) -> PendingTranscriptLoadResult {
        guard let fileURL else {
            return PendingTranscriptLoadResult(
                transcripts: [],
                warning: nil,
                blockedExistingDocumentReason: nil
            )
        }
        let data: Data
        do {
            guard let loaded = try MacPrivateStoreIO.readExistingData(at: fileURL) else {
                return PendingTranscriptLoadResult(
                    transcripts: [],
                    warning: nil,
                    blockedExistingDocumentReason: nil
                )
            }
            data = loaded
        } catch {
            let boundaryWasUnsafe = (error as NSError).domain == NSPOSIXErrorDomain
                && (error as NSError).code == Int(ELOOP)
            let warning = boundaryWasUnsafe
                ? "Pending-transcript storage was unsafe because it is not a regular file; the on-disk queue was left untouched and queue changes are blocked."
                : "Pending transcripts could not be read; the on-disk queue was left untouched and queue changes are blocked."
            return PendingTranscriptLoadResult(
                transcripts: [],
                warning: warning,
                blockedExistingDocumentReason: warning
            )
        }

        let decoder = JSONDecoder()
        let decoded: [MacPendingTranscript]
        let droppedCount: Int
        var blockedReason: String?

        if let probe = try? decoder.decode(PendingTranscriptSchemaProbe.self, from: data),
           probe.hasDocumentShape,
           probe.schemaFieldIsInvalid
            || probe.schemaVersion.map({ $0 != StoredPendingTranscripts.currentSchemaVersion }) == true {
            let recovery = try? decoder.decode(PendingTranscriptRecoveryDocument.self, from: data)
            decoded = recovery?.transcripts ?? []
            droppedCount = recovery?.droppedTranscriptCount ?? 0
            if let schemaVersion = probe.schemaVersion {
                blockedReason = "Pending transcripts use unsupported schema \(schemaVersion); the file was left untouched and queue changes are blocked."
            } else {
                blockedReason = "Pending transcripts use an unsupported schema value; the file was left untouched and queue changes are blocked."
            }
        } else if let document = try? decoder.decode(StoredPendingTranscripts.self, from: data) {
            decoded = document.transcripts
            droppedCount = document.droppedTranscriptCount
        } else if let legacy = try? decoder.decode(LossyPendingTranscriptList.self, from: data) {
            decoded = legacy.values
            droppedCount = legacy.droppedCount
        } else {
            let warning = "Pending transcripts were unreadable; the on-disk queue was left untouched and queue changes are blocked."
            return PendingTranscriptLoadResult(
                transcripts: [],
                warning: warning,
                blockedExistingDocumentReason: warning
            )
        }

        if blockedReason == nil {
            guard let unsupportedFieldCount = unsupportedFieldCount(in: data) else {
                blockedReason = "Pending-transcript structure could not be verified; the file was left untouched and queue changes are blocked."
                return makeLoadResult(
                    decoded,
                    droppedCount: droppedCount,
                    blockedReason: blockedReason
                )
            }
            if unsupportedFieldCount > 0 {
                blockedReason = "Recovered pending transcripts with unsupported fields; the file was left untouched and queue changes are blocked."
            }
        }

        if droppedCount > 0, blockedReason == nil {
            blockedReason = "Recovered the readable pending transcripts but found \(droppedCount) damaged entr\(droppedCount == 1 ? "y" : "ies"); the file was left untouched and queue changes are blocked."
        }

        return makeLoadResult(
            decoded,
            droppedCount: droppedCount,
            blockedReason: blockedReason
        )
    }

    private static func makeLoadResult(
        _ decoded: [MacPendingTranscript],
        droppedCount: Int,
        blockedReason: String?
    ) -> PendingTranscriptLoadResult {
        var byID: [UUID: MacPendingTranscript] = [:]
        var duplicateCount = 0
        for transcript in decoded {
            if byID.updateValue(normalized(transcript), forKey: transcript.id) != nil {
                duplicateCount += 1
            }
        }
        let effectiveBlockedReason = blockedReason ?? (duplicateCount > 0
            ? "Recovered pending transcripts with duplicate identifiers; the file was left untouched and queue changes are blocked."
            : nil)
        let warning = effectiveBlockedReason ?? (droppedCount > 0
            ? "Recovered the readable pending transcripts and ignored \(droppedCount) damaged entr\(droppedCount == 1 ? "y" : "ies")."
            : nil)
        return PendingTranscriptLoadResult(
            transcripts: sorted(Array(byID.values)),
            warning: warning,
            blockedExistingDocumentReason: effectiveBlockedReason
        )
    }

    private static func normalized(_ transcript: MacPendingTranscript) -> MacPendingTranscript {
        var transcript = transcript
        let appName = transcript.destinationApplicationName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        transcript.destinationApplicationName = appName.isEmpty ? "Unknown app" : appName
        if let bundleIdentifier = transcript.destinationBundleIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) {
            transcript.destinationBundleIdentifier = bundleIdentifier.isEmpty ? nil : bundleIdentifier
        }
        return transcript
    }

    private static func sorted(
        _ transcripts: [MacPendingTranscript]
    ) -> [MacPendingTranscript] {
        transcripts.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private static func makeFileURL(in directory: URL?) -> URL? {
        if let directory {
            return directory.appending(
                path: "pending-transcripts.json",
                directoryHint: .notDirectory
            )
        }
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else {
            return nil
        }
        return support
            .appending(path: "SpeakPaste", directoryHint: .isDirectory)
            .appending(path: "pending-transcripts.json", directoryHint: .notDirectory)
    }

    /// Codable ignores unknown keys. Inspecting the JSON shape prevents an old
    /// build from loading future metadata and silently stripping it on write.
    private static func unsupportedFieldCount(in data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let recordKeys: Set<String> = [
            "id",
            "text",
            "destinationApplicationName",
            "destinationBundleIdentifier",
            "destinationAppName",
            "destinationBundleID",
            "applicationName",
            "bundleIdentifier",
            "createdAt",
            "deliveryState",
        ]

        func countRecordFields(in values: [Any]) -> Int {
            values.reduce(into: 0) { count, value in
                guard let object = value as? [String: Any] else { return }
                if !Set(object.keys).isSubset(of: recordKeys) {
                    count += 1
                }
                let nameAliases = [
                    "destinationApplicationName",
                    "destinationAppName",
                    "applicationName",
                ]
                let bundleAliases = [
                    "destinationBundleIdentifier",
                    "destinationBundleID",
                    "bundleIdentifier",
                ]
                if nameAliases.filter(object.keys.contains).count > 1
                    || bundleAliases.filter(object.keys.contains).count > 1 {
                    count += 1
                }
            }
        }

        if let legacy = root as? [Any] {
            return countRecordFields(in: legacy)
        }
        guard let document = root as? [String: Any] else { return nil }
        let documentKeys: Set<String> = ["schemaVersion", "transcripts", "pendingTranscripts"]
        var count = Set(document.keys).isSubset(of: documentKeys) ? 0 : 1
        let hasCurrentRecords = document["transcripts"] != nil
        let hasLegacyRecords = document["pendingTranscripts"] != nil
        if hasCurrentRecords == hasLegacyRecords {
            // Both aliases are ambiguous; neither means this is not a complete
            // pending-transcript document despite Codable's default empty list.
            count += 1
        }
        let values: [Any]
        if let current = document["transcripts"] {
            guard let current = current as? [Any] else { return nil }
            values = current
        } else if let legacy = document["pendingTranscripts"] {
            guard let legacy = legacy as? [Any] else { return nil }
            values = legacy
        } else {
            values = []
        }
        count += countRecordFields(in: values)
        return count
    }
}

private struct StoredPendingTranscripts: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let transcripts: [MacPendingTranscript]
    let droppedTranscriptCount: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case transcripts
        // Accept the product-language alias while writing one stable schema.
        case pendingTranscripts
    }

    init(schemaVersion: Int, transcripts: [MacPendingTranscript]) {
        self.schemaVersion = schemaVersion
        self.transcripts = transcripts
        droppedTranscriptCount = 0
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported pending-transcript schema: \(schemaVersion)"
            )
        }
        if container.contains(.transcripts) {
            let current = try container.decode(
                LossyPendingTranscriptList.self,
                forKey: .transcripts
            )
            transcripts = current.values
            droppedTranscriptCount = current.droppedCount
        } else if container.contains(.pendingTranscripts) {
            let legacy = try container.decode(
                LossyPendingTranscriptList.self,
                forKey: .pendingTranscripts
            )
            transcripts = legacy.values
            droppedTranscriptCount = legacy.droppedCount
        } else {
            transcripts = []
            droppedTranscriptCount = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(transcripts, forKey: .transcripts)
    }
}

/// Reads only enough of an object-shaped document to decide whether this build
/// owns its schema. A malformed schema value is not silently reinterpreted as
/// version 1.
private struct PendingTranscriptSchemaProbe: Decodable {
    let schemaVersion: Int?
    let schemaFieldIsInvalid: Bool
    let hasDocumentShape: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case transcripts
        case pendingTranscripts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasDocumentShape = container.contains(.schemaVersion)
            || container.contains(.transcripts)
            || container.contains(.pendingTranscripts)
        if container.contains(.schemaVersion) {
            do {
                schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
                schemaFieldIsInvalid = false
            } catch {
                schemaVersion = nil
                schemaFieldIsInvalid = true
            }
        } else {
            schemaVersion = nil
            schemaFieldIsInvalid = false
        }
    }
}

/// A future document does not grant write authority, but known transcript
/// fields can still be exposed so the user can copy their held speech out.
private struct PendingTranscriptRecoveryDocument: Decodable {
    let transcripts: [MacPendingTranscript]
    let droppedTranscriptCount: Int

    private enum CodingKeys: String, CodingKey {
        case transcripts
        case pendingTranscripts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recovered: LossyPendingTranscriptList
        if container.contains(.transcripts) {
            recovered = try container.decode(
                LossyPendingTranscriptList.self,
                forKey: .transcripts
            )
        } else if container.contains(.pendingTranscripts) {
            recovered = try container.decode(
                LossyPendingTranscriptList.self,
                forKey: .pendingTranscripts
            )
        } else {
            transcripts = []
            droppedTranscriptCount = 0
            return
        }
        transcripts = recovered.values
        droppedTranscriptCount = recovered.droppedCount
    }
}

/// Decodes records independently so one damaged transcript does not hide all
/// other recoverable speech in the file.
private struct LossyPendingTranscriptList: Decodable {
    let values: [MacPendingTranscript]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [MacPendingTranscript] = []
        var droppedCount = 0
        while !container.isAtEnd {
            if let wrapper = try? container.decode(LossyPendingTranscriptValue.self),
               let value = wrapper.value {
                decoded.append(value)
            } else {
                droppedCount += 1
            }
        }
        values = decoded
        self.droppedCount = droppedCount
    }
}

private struct LossyPendingTranscriptValue: Decodable {
    let value: MacPendingTranscript?

    init(from decoder: Decoder) throws {
        value = try? MacPendingTranscript(from: decoder)
    }
}

private struct PendingTranscriptLoadResult {
    let transcripts: [MacPendingTranscript]
    let warning: String?
    let blockedExistingDocumentReason: String?
}
