import Combine
import CoreFoundation
import Darwin
import Foundation

/// The mechanism SpeakPaste should use for one destination application.
///
/// `automatic` is deliberately the default: it leaves the existing menu-paste
/// and keyboard-shortcut fallback behavior in charge. The other cases are
/// explicit exceptions for applications where that behavior is a poor fit.
enum MacDeliveryMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case menuPaste
    case typeOut
    case clipboardOnly

    var id: Self { self }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode(String.self)
        guard let method = Self(rawValue: stored) else {
            // An older build must never reinterpret a future delivery method as
            // automatic paste while retaining that rule's auto-send/context
            // flags. Throwing here marks the owned document unsupported so the
            // store can fail closed without rewriting any of its bytes.
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported delivery method: \(stored)"
            )
        }
        self = method
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The complete, non-visual delivery contract for one bundle identifier.
///
/// Auto-send and context-derived keyterms are opt-in because each can produce
/// an external side effect: one sends a message, and the other uploads words
/// read from the destination to the transcription service. Type-out fallback
/// is independent of the primary method so an app may prefer menu paste but
/// still remain usable when its menu cannot be reached.
struct MacDeliveryPolicy: Identifiable, Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var applicationName: String?
    var deliveryMethod: MacDeliveryMethod
    var typeOutFallback: Bool
    var autoSend: Bool
    var contextKeyterms: Bool

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        applicationName: String? = nil,
        deliveryMethod: MacDeliveryMethod = .automatic,
        typeOutFallback: Bool = false,
        autoSend: Bool = false,
        contextKeyterms: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.deliveryMethod = deliveryMethod
        self.typeOutFallback = typeOutFallback
        self.autoSend = autoSend
        self.contextKeyterms = contextKeyterms
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case applicationName
        case deliveryMethod
        case typeOutFallback
        case autoSend
        case contextKeyterms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName)
        deliveryMethod = try container.decodeIfPresent(
            MacDeliveryMethod.self,
            forKey: .deliveryMethod
        ) ?? .automatic
        typeOutFallback = try container.decodeIfPresent(
            Bool.self,
            forKey: .typeOutFallback
        ) ?? false
        // Missing fields must stay false when an older file is upgraded. In
        // particular, merely updating SpeakPaste can never start sending text.
        autoSend = try container.decodeIfPresent(Bool.self, forKey: .autoSend) ?? false
        contextKeyterms = try container.decodeIfPresent(Bool.self, forKey: .contextKeyterms) ?? false
    }
}

/// Durable per-application delivery choices, keyed by bundle identifier.
///
/// The store owns data only. It does not paste, type, press Return, or collect
/// context itself; those actions remain explicit decisions at delivery time.
@MainActor
final class MacDeliveryPolicyStore: ObservableObject {
    @Published private(set) var policiesByBundleIdentifier: [String: MacDeliveryPolicy]
    @Published private(set) var lastPersistenceError: String?

    /// Stable ordering for list- and table-based SwiftUI surfaces.
    var policies: [MacDeliveryPolicy] {
        policiesByBundleIdentifier.values.sorted { lhs, rhs in
            let lhsName = lhs.applicationName ?? lhs.bundleIdentifier
            let rhsName = rhs.applicationName ?? rhs.bundleIdentifier
            let comparison = lhsName.localizedStandardCompare(rhsName)
            if comparison == .orderedSame {
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
            return comparison == .orderedAscending
        }
    }

    private let fileURL: URL?
    /// A document this build could not fully understand remains the authority
    /// until the user moves or removes it. Treating the safely empty in-memory
    /// table as permission to overwrite that file would silently destroy future
    /// rules and could later re-enable delivery behavior with different defaults.
    private var blockedExistingDocumentReason: String?

    /// `directory` makes persistence testable without touching the user's real
    /// Application Support container. Production callers use the default.
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
                permissionWarning = "Could not secure delivery-policy storage: \(error.localizedDescription)"
            }
        } else {
            // Preservation includes metadata. Do not chmod a document that was
            // unreadable, unsafe, malformed, or created by a newer build.
            permissionWarning = nil
        }

        policiesByBundleIdentifier = loaded.policies
        blockedExistingDocumentReason = loaded.blockedExistingDocumentReason
            ?? permissionWarning
        lastPersistenceError = [permissionWarning, loaded.warning]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty
    }

    /// Returns an explicitly configured policy, or nil when the app inherits
    /// SpeakPaste's current global behavior.
    func configuredPolicy(for bundleIdentifier: String) -> MacDeliveryPolicy? {
        policiesByBundleIdentifier[Self.key(for: bundleIdentifier)]
    }

    /// Returns a complete policy for use by delivery code. An unknown app gets
    /// only safe defaults: automatic delivery, no type-out fallback, no Return
    /// key, and no destination text uploaded as context.
    func policy(
        for bundleIdentifier: String,
        applicationName: String? = nil
    ) -> MacDeliveryPolicy {
        configuredPolicy(for: bundleIdentifier) ?? MacDeliveryPolicy(
            bundleIdentifier: bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationName: Self.trimmedName(applicationName)
        )
    }

    /// Creates or replaces a rule. Empty bundle identifiers are refused so no
    /// wildcard-looking entry can accidentally affect unrelated applications.
    @discardableResult
    func upsert(_ policy: MacDeliveryPolicy) -> Bool {
        guard let normalized = Self.normalized(policy) else {
            lastPersistenceError = "A delivery rule needs a non-empty bundle identifier."
            return false
        }
        var proposed = policiesByBundleIdentifier
        proposed[Self.key(for: normalized.bundleIdentifier)] = normalized
        guard persist(proposed) else { return false }
        policiesByBundleIdentifier = proposed
        return true
    }

    /// Convenience CRUD entry point for a SwiftUI form.
    @discardableResult
    func setPolicy(
        for bundleIdentifier: String,
        applicationName: String? = nil,
        deliveryMethod: MacDeliveryMethod = .automatic,
        typeOutFallback: Bool = false,
        autoSend: Bool = false,
        contextKeyterms: Bool = false
    ) -> Bool {
        upsert(
            MacDeliveryPolicy(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName,
                deliveryMethod: deliveryMethod,
                typeOutFallback: typeOutFallback,
                autoSend: autoSend,
                contextKeyterms: contextKeyterms
            )
        )
    }

    @discardableResult
    func removePolicy(for bundleIdentifier: String) -> Bool {
        var proposed = policiesByBundleIdentifier
        guard proposed.removeValue(forKey: Self.key(for: bundleIdentifier)) != nil else {
            return false
        }
        guard persist(proposed) else { return false }
        policiesByBundleIdentifier = proposed
        return true
    }

    /// Replaces the table as one atomic state change. Invalid identifiers refuse
    /// the whole mutation; for case-insensitive duplicates, the last value wins.
    @discardableResult
    func replaceAll(with policies: [MacDeliveryPolicy]) -> Bool {
        var replacement: [String: MacDeliveryPolicy] = [:]
        for policy in policies {
            guard let normalized = Self.normalized(policy) else {
                lastPersistenceError = "A delivery rule needs a non-empty bundle identifier."
                return false
            }
            replacement[Self.key(for: normalized.bundleIdentifier)] = normalized
        }
        guard persist(replacement) else { return false }
        policiesByBundleIdentifier = replacement
        return true
    }

    @discardableResult
    func removeAll() -> Bool {
        // Write even when memory is already empty so a healthy store gets a
        // durable empty document. A blocked document is deliberately different:
        // it must first be moved or removed outside SpeakPaste.
        guard persist([:]) else { return false }
        policiesByBundleIdentifier = [:]
        return true
    }

    @discardableResult
    private func persist(_ proposed: [String: MacDeliveryPolicy]) -> Bool {
        guard let fileURL else {
            lastPersistenceError = "Application Support is unavailable."
            return false
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
                return false
            }
            self.blockedExistingDocumentReason = nil
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                StoredPolicies(
                    schemaVersion: StoredPolicies.currentSchemaVersion,
                    policiesByBundleIdentifier: proposed
                )
            )
            try MacPrivateStoreIO.writeAtomically(data, to: fileURL)
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = error.localizedDescription
            return false
        }
    }

    private static func load(from fileURL: URL?) -> PolicyLoadResult {
        guard let fileURL else {
            return PolicyLoadResult(
                policies: [:],
                warning: nil,
                blockedExistingDocumentReason: nil
            )
        }
        let data: Data
        do {
            guard let loaded = try MacPrivateStoreIO.readExistingData(at: fileURL) else {
                return PolicyLoadResult(
                    policies: [:],
                    warning: nil,
                    blockedExistingDocumentReason: nil
                )
            }
            data = loaded
        } catch {
            return blockedLoad(
                "Delivery-policy storage was unsafe or unreadable; it was left untouched and policy changes are blocked."
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return blockedLoad(
                "Delivery policies were malformed; they were left untouched and policy changes are blocked."
            )
        }
        if let validationFailure = documentValidationFailure(for: object) {
            return blockedLoad(validationFailure)
        }

        let decoder = JSONDecoder()
        let probe = try? decoder.decode(PolicySchemaProbe.self, from: data)
        if let schemaVersion = probe?.schemaVersion,
           schemaVersion != StoredPolicies.currentSchemaVersion {
            return blockedLoad(
                "Delivery policies use unsupported schema \(schemaVersion); they were left untouched and policy changes are blocked."
            )
        }

        let decoded: [String: MacDeliveryPolicy]
        let initiallyDropped: Int
        if probe?.hasDocumentShape == true {
            guard let document = try? decoder.decode(StoredPolicies.self, from: data) else {
                return blockedLoad(
                    "Delivery policies were unreadable; they were left untouched and policy changes are blocked."
                )
            }
            decoded = document.policiesByBundleIdentifier
            initiallyDropped = document.droppedPolicyCount
        } else if let legacyMap = try? decoder.decode(LossyPolicyMap.self, from: data) {
            decoded = legacyMap.values
            initiallyDropped = legacyMap.droppedCount
        } else if let legacyList = try? decoder.decode(LossyPolicyList.self, from: data) {
            decoded = Dictionary(
                legacyList.values.map { (key(for: $0.bundleIdentifier), $0) },
                uniquingKeysWith: { _, newest in newest }
            )
            initiallyDropped = legacyList.droppedCount
        } else {
            return blockedLoad(
                "Delivery policies were unreadable; they were left untouched and policy changes are blocked."
            )
        }

        guard initiallyDropped == 0 else {
            return blockedLoad(
                "Delivery policies contain unsupported or damaged rules; they were left untouched and policy changes are blocked."
            )
        }

        var result: [String: MacDeliveryPolicy] = [:]
        for (storedKey, policy) in decoded {
            var candidate = policy
            if candidate.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidate.bundleIdentifier = storedKey
            }
            guard let normalized = normalized(candidate) else {
                return blockedLoad(
                    "Delivery policies contain unsupported or damaged rules; they were left untouched and policy changes are blocked."
                )
            }
            let normalizedKey = key(for: normalized.bundleIdentifier)
            guard result[normalizedKey] == nil else {
                return blockedLoad(
                    "Delivery policies contain duplicate application rules; they were left untouched and policy changes are blocked."
                )
            }
            result[normalizedKey] = normalized
        }
        return PolicyLoadResult(
            policies: result,
            warning: nil,
            blockedExistingDocumentReason: nil
        )
    }

    private static func blockedLoad(_ message: String) -> PolicyLoadResult {
        PolicyLoadResult(
            policies: [:],
            warning: message,
            blockedExistingDocumentReason: message
        )
    }

    /// Codable intentionally ignores unknown keyed fields. That is convenient
    /// for network payloads but unsafe for an app-owned document because this
    /// build would strip future behavior on its next write. Validate the raw JSON
    /// shape first, including every policy object, before decoding safe defaults.
    private static func documentValidationFailure(for object: Any) -> String? {
        let policyKeys: Set<String> = [
            "bundleIdentifier",
            "applicationName",
            "deliveryMethod",
            "typeOutFallback",
            "autoSend",
            "contextKeyterms",
        ]
        let policyObjectIsSupported: (Any) -> Bool = { value in
            guard let dictionary = value as? [String: Any] else { return false }
            return Set(dictionary.keys).isSubset(of: policyKeys)
        }

        if let dictionary = object as? [String: Any] {
            let documentKeys: Set<String> = [
                "schemaVersion",
                "policiesByBundleIdentifier",
                "policies",
            ]
            let isDocument = !Set(dictionary.keys).isDisjoint(with: documentKeys)
            if isDocument {
                guard Set(dictionary.keys).isSubset(of: documentKeys) else {
                    return "Delivery policies use unsupported document fields; they were left untouched and policy changes are blocked."
                }
                if let storedSchema = dictionary["schemaVersion"] {
                    guard
                        let schemaNumber = storedSchema as? NSNumber,
                        CFGetTypeID(schemaNumber) != CFBooleanGetTypeID(),
                        let schemaVersion = storedSchema as? Int,
                        schemaVersion == StoredPolicies.currentSchemaVersion
                    else {
                        return "Delivery policies use a newer schema or another unsupported schema; they were left untouched and policy changes are blocked."
                    }
                }
                let hasCurrentMap = dictionary["policiesByBundleIdentifier"] != nil
                let hasLegacyMap = dictionary["policies"] != nil
                guard !(hasCurrentMap && hasLegacyMap) else {
                    return "Delivery policies contain ambiguous rule tables; they were left untouched and policy changes are blocked."
                }
                let rawPolicies = dictionary["policiesByBundleIdentifier"]
                    ?? dictionary["policies"]
                if let rawPolicies {
                    guard
                        let map = rawPolicies as? [String: Any],
                        map.values.allSatisfy(policyObjectIsSupported)
                    else {
                        return "Delivery policies contain unsupported or damaged rules; they were left untouched and policy changes are blocked."
                    }
                }
                return nil
            }

            guard dictionary.values.allSatisfy(policyObjectIsSupported) else {
                return "Delivery policies contain unsupported or damaged legacy rules; they were left untouched and policy changes are blocked."
            }
            return nil
        }

        if let list = object as? [Any] {
            guard list.allSatisfy(policyObjectIsSupported) else {
                return "Delivery policies contain unsupported or damaged legacy rules; they were left untouched and policy changes are blocked."
            }
            return nil
        }

        return "Delivery policies use an unsupported document shape; they were left untouched and policy changes are blocked."
    }

    private static func normalized(_ policy: MacDeliveryPolicy) -> MacDeliveryPolicy? {
        var policy = policy
        policy.bundleIdentifier = policy.bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !policy.bundleIdentifier.isEmpty else { return nil }
        policy.applicationName = trimmedName(policy.applicationName)
        // Clipboard-only means no synthetic insertion at all. A type-out
        // fallback would violate that promise, and without an insertion there
        // is nothing that can safely be followed by Return.
        if policy.deliveryMethod == .clipboardOnly {
            policy.typeOutFallback = false
            policy.autoSend = false
        }
        return policy
    }

    private static func trimmedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func key(for bundleIdentifier: String) -> String {
        bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func makeFileURL(in directory: URL?) -> URL? {
        if let directory {
            return directory.appending(path: "delivery-policies.json", directoryHint: .notDirectory)
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
            .appending(path: "delivery-policies.json", directoryHint: .notDirectory)
    }
}

private struct StoredPolicies: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let policiesByBundleIdentifier: [String: MacDeliveryPolicy]
    let droppedPolicyCount: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case policiesByBundleIdentifier
        // Accepted for an early or hand-written document using the shorter
        // name. Encoding always emits the canonical key above.
        case policies
    }

    init(schemaVersion: Int, policiesByBundleIdentifier: [String: MacDeliveryPolicy]) {
        self.schemaVersion = schemaVersion
        self.policiesByBundleIdentifier = policiesByBundleIdentifier
        droppedPolicyCount = 0
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported delivery-policy schema: \(schemaVersion)"
            )
        }
        if container.contains(.policiesByBundleIdentifier) {
            let current = try container.decode(
                LossyPolicyMap.self,
                forKey: .policiesByBundleIdentifier
            )
            policiesByBundleIdentifier = current.values
            droppedPolicyCount = current.droppedCount
        } else if container.contains(.policies) {
            let legacy = try container.decode(LossyPolicyMap.self, forKey: .policies)
            policiesByBundleIdentifier = legacy.values
            droppedPolicyCount = legacy.droppedCount
        } else {
            policiesByBundleIdentifier = [:]
            droppedPolicyCount = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(policiesByBundleIdentifier, forKey: .policiesByBundleIdentifier)
    }
}

/// Decodes each dictionary value independently only to identify damage without
/// throwing away the rest of the parse. The store rejects the entire document
/// whenever `droppedCount` is nonzero, leaving its original bytes untouched.
private struct LossyPolicyMap: Decodable {
    let values: [String: MacDeliveryPolicy]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicPolicyKey.self)
        var decoded: [String: MacDeliveryPolicy] = [:]
        var droppedCount = 0
        for key in container.allKeys {
            guard let value = try? container.decode(MacDeliveryPolicy.self, forKey: key) else {
                droppedCount += 1
                continue
            }
            decoded[key.stringValue] = value
        }
        values = decoded
        self.droppedCount = droppedCount
    }
}

private struct LossyPolicyList: Decodable {
    let values: [MacDeliveryPolicy]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [MacDeliveryPolicy] = []
        var droppedCount = 0
        while !container.isAtEnd {
            if let wrapper = try? container.decode(LossyPolicyValue.self),
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

private struct LossyPolicyValue: Decodable {
    let value: MacDeliveryPolicy?

    init(from decoder: Decoder) throws {
        value = try? MacDeliveryPolicy(from: decoder)
    }
}

private struct DynamicPolicyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct PolicySchemaProbe: Decodable {
    let schemaVersion: Int?
    let hasDocumentShape: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case policiesByBundleIdentifier
        case policies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        hasDocumentShape = container.contains(.schemaVersion)
            || container.contains(.policiesByBundleIdentifier)
            || container.contains(.policies)
    }
}

private struct PolicyLoadResult {
    let policies: [String: MacDeliveryPolicy]
    let warning: String?
    let blockedExistingDocumentReason: String?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Shared private-storage primitive for every JSON store under SpeakPaste's
/// owned Application Support directory.
///
/// Directory descriptors plus `openat`/`renameat` keep all operations inside
/// the directory that was actually validated. Neither a symlinked storage
/// directory nor a symlinked final entry is followed for read, chmod, or write.
enum MacPrivateStoreIO {
    struct RegularFileEntry: Equatable {
        let name: String
        let createdAt: Date
    }

    private static let directoryPermissions: mode_t = 0o700
    private static let filePermissions: mode_t = 0o600
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let fileReadFlags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC

    /// Verifies an existing boundary without changing permissions. A missing
    /// final directory/file is valid; its immediate parent must already be a
    /// real directory so a later create cannot traverse a symlink component
    /// controlled by the caller.
    static func validateExistingStorage(at fileURL: URL?) throws {
        _ = try existingRegularFileIsPresent(at: fileURL)
    }

    /// Reports absence only after validating the owned directory and final
    /// entry without following either one. Unsafe shapes throw rather than
    /// masquerading as a file the user intentionally removed.
    static func existingRegularFileIsPresent(at fileURL: URL?) throws -> Bool {
        guard let fileURL else { return false }
        guard let directoryFD = try openOwnedDirectory(
            at: fileURL.deletingLastPathComponent(),
            createIfMissing: false,
            makePrivate: false
        ) else {
            return false
        }
        defer { Darwin.close(directoryFD) }
        return try regularEntryStatus(
            named: try safeBasename(of: fileURL),
            in: directoryFD,
            path: fileURL.path
        ) != nil
    }

    /// Creates or opens one app-owned directory without traversing a symlink
    /// at that controlled component, and makes the opened inode private.
    static func ensurePrivateDirectory(at directoryURL: URL) throws {
        guard let descriptor = try openOwnedDirectory(
            at: directoryURL,
            createIfMissing: true,
            makePrivate: true
        ) else {
            throw posixError(path: directoryURL.path, code: ENOENT)
        }
        Darwin.close(descriptor)
    }

    /// Exclusively renames a regular non-symlink source into the opened private
    /// directory, with a durable copy/unlink fallback for cross-volume imports.
    /// The destination path is never resolved independently from its directory.
    static func importRegularFile(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceDirectoryURL = sourceURL.deletingLastPathComponent()
        let sourceDirectoryDescriptor = try openExistingDirectory(
            at: sourceDirectoryURL,
            makePrivate: false
        )
        defer { Darwin.close(sourceDirectoryDescriptor) }
        let sourceName = try safeBasename(of: sourceURL)
        let sourceDescriptor = sourceName.withCString {
            Darwin.openat(sourceDirectoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else { throw posixError(path: sourceURL.path) }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0 else {
            throw posixError(path: sourceURL.path)
        }
        guard
            (sourceStatus.st_mode & S_IFMT) == S_IFREG,
            sourceStatus.st_nlink == 1
        else {
            throw unsafeBoundaryError(path: sourceURL.path)
        }
        guard Darwin.fchmod(sourceDescriptor, filePermissions) == 0 else {
            throw posixError(path: sourceURL.path)
        }
        guard Darwin.fsync(sourceDescriptor) == 0 else {
            throw posixError(path: sourceURL.path)
        }

        guard let directoryDescriptor = try openOwnedDirectory(
            at: destinationURL.deletingLastPathComponent(),
            createIfMissing: false,
            makePrivate: true
        ) else {
            throw posixError(path: destinationURL.deletingLastPathComponent().path, code: ENOENT)
        }
        defer { Darwin.close(directoryDescriptor) }
        let destinationName = try safeBasename(of: destinationURL)

        // Captures normally move from the local temporary directory to local
        // Application Support. Make that operation one exclusive namespace
        // transaction: there is no copy/unlink window in which launch recovery
        // can see both names and register the same speech twice.
        let renameResult = sourceName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    sourceDirectoryDescriptor,
                    source,
                    directoryDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if renameResult == 0 {
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw posixError(path: destinationURL.path)
            }
            guard Darwin.fsync(sourceDirectoryDescriptor) == 0 else {
                throw posixError(path: sourceDirectoryURL.path)
            }
            return
        }
        let renameError = errno
        guard renameError == EXDEV else {
            throw posixError(path: destinationURL.path, code: renameError)
        }

        // Cross-volume imports cannot be renamed. Make the destination entry
        // and its directory durable before unlinking the source. If the process
        // stops anywhere around that unlink, active-capture IDs are preserved
        // by callers so orphan recovery collapses both names to one identity.
        let destinationDescriptor = destinationName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                filePermissions
            )
        }
        guard destinationDescriptor >= 0 else { throw posixError(path: destinationURL.path) }
        var destinationIsDurable = false
        defer {
            Darwin.close(destinationDescriptor)
            if !destinationIsDurable {
                _ = destinationName.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
                _ = Darwin.fsync(directoryDescriptor)
            }
        }

        try copyAll(
            from: sourceDescriptor,
            to: destinationDescriptor,
            path: destinationURL.path
        )
        guard Darwin.fchmod(destinationDescriptor, filePermissions) == 0 else {
            throw posixError(path: destinationURL.path)
        }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw posixError(path: destinationURL.path)
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError(path: destinationURL.path)
        }
        destinationIsDurable = true

        var currentSourceStatus = stat()
        let sourceStillNamesOpenedFile = sourceName.withCString {
            Darwin.fstatat(
                sourceDirectoryDescriptor,
                $0,
                &currentSourceStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        } && currentSourceStatus.st_dev == sourceStatus.st_dev
            && currentSourceStatus.st_ino == sourceStatus.st_ino
            && (currentSourceStatus.st_mode & S_IFMT) == S_IFREG
            && currentSourceStatus.st_nlink == 1
        guard sourceStillNamesOpenedFile else {
            throw unsafeBoundaryError(path: sourceURL.path)
        }
        guard sourceName.withCString({ Darwin.unlinkat(sourceDirectoryDescriptor, $0, 0) }) == 0 else {
            throw posixError(path: sourceURL.path)
        }
        guard Darwin.fsync(sourceDirectoryDescriptor) == 0 else {
            throw posixError(path: sourceDirectoryURL.path)
        }
    }

    /// Copies a regular, single-link file into an already-owned private
    /// directory without following either endpoint. Unlike `importRegularFile`,
    /// this deliberately leaves the source in place; successful dictation uses
    /// it to retain an optional History copy before the recovery journal is
    /// allowed to retire its authoritative source.
    static func copyRegularFile(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceDirectoryDescriptor = try openExistingDirectory(
            at: sourceURL.deletingLastPathComponent(),
            makePrivate: false
        )
        defer { Darwin.close(sourceDirectoryDescriptor) }
        let sourceName = try safeBasename(of: sourceURL)
        let sourceDescriptor = sourceName.withCString {
            Darwin.openat(sourceDirectoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else { throw posixError(path: sourceURL.path) }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0 else {
            throw posixError(path: sourceURL.path)
        }
        guard
            (sourceStatus.st_mode & S_IFMT) == S_IFREG,
            sourceStatus.st_nlink == 1
        else {
            throw unsafeBoundaryError(path: sourceURL.path)
        }

        guard let destinationDirectoryDescriptor = try openOwnedDirectory(
            at: destinationURL.deletingLastPathComponent(),
            createIfMissing: false,
            makePrivate: true
        ) else {
            throw posixError(
                path: destinationURL.deletingLastPathComponent().path,
                code: ENOENT
            )
        }
        defer { Darwin.close(destinationDirectoryDescriptor) }
        let destinationName = try safeBasename(of: destinationURL)
        let destinationDescriptor = destinationName.withCString {
            Darwin.openat(
                destinationDirectoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                filePermissions
            )
        }
        guard destinationDescriptor >= 0 else {
            throw posixError(path: destinationURL.path)
        }
        var destinationIsDurable = false
        defer {
            Darwin.close(destinationDescriptor)
            if !destinationIsDurable {
                _ = destinationName.withCString {
                    Darwin.unlinkat(destinationDirectoryDescriptor, $0, 0)
                }
                _ = Darwin.fsync(destinationDirectoryDescriptor)
            }
        }

        try copyAll(
            from: sourceDescriptor,
            to: destinationDescriptor,
            path: destinationURL.path
        )
        guard Darwin.fchmod(destinationDescriptor, filePermissions) == 0 else {
            throw posixError(path: destinationURL.path)
        }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw posixError(path: destinationURL.path)
        }
        guard Darwin.fsync(destinationDirectoryDescriptor) == 0 else {
            throw posixError(path: destinationURL.path)
        }
        destinationIsDurable = true
    }

    /// Unlinks only a validated regular, single-link entry through its opened
    /// private directory. Missing files are reported as false.
    @discardableResult
    static func removeRegularFile(at fileURL: URL) throws -> Bool {
        guard let directoryDescriptor = try openOwnedDirectory(
            at: fileURL.deletingLastPathComponent(),
            createIfMissing: false,
            makePrivate: true
        ) else {
            return false
        }
        defer { Darwin.close(directoryDescriptor) }
        let name = try safeBasename(of: fileURL)
        guard try regularEntryStatus(named: name, in: directoryDescriptor, path: fileURL.path) != nil else {
            return false
        }
        let result = name.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
        guard result == 0 else { throw posixError(path: fileURL.path) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError(path: fileURL.deletingLastPathComponent().path)
        }
        return true
    }

    /// Enumerates regular single-link files from the opened directory itself.
    /// Symlinks, directories, sockets, and hard links are never surfaced as
    /// pending audio candidates.
    static func regularFileEntries(in directoryURL: URL) throws -> [RegularFileEntry] {
        guard let directoryDescriptor = try openOwnedDirectory(
            at: directoryURL,
            createIfMissing: false,
            makePrivate: true
        ) else {
            return []
        }
        defer { Darwin.close(directoryDescriptor) }
        let iterationDescriptor = Darwin.dup(directoryDescriptor)
        guard iterationDescriptor >= 0 else { throw posixError(path: directoryURL.path) }
        guard let stream = Darwin.fdopendir(iterationDescriptor) else {
            Darwin.close(iterationDescriptor)
            throw posixError(path: directoryURL.path)
        }
        defer { Darwin.closedir(stream) }

        var entries: [RegularFileEntry] = []
        while true {
            errno = 0
            guard let rawEntry = Darwin.readdir(stream) else {
                guard errno == 0 else { throw posixError(path: directoryURL.path) }
                break
            }
            let name = withUnsafePointer(to: rawEntry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            var status = stat()
            let lookup = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard lookup == 0 else {
                if errno == ENOENT { continue }
                throw posixError(path: directoryURL.appendingPathComponent(name).path)
            }
            guard
                (status.st_mode & S_IFMT) == S_IFREG,
                status.st_nlink == 1
            else {
                continue
            }
            let timestamp = status.st_birthtimespec
            let createdAt = Date(
                timeIntervalSince1970: TimeInterval(timestamp.tv_sec)
                    + TimeInterval(timestamp.tv_nsec) / 1_000_000_000
            )
            entries.append(RegularFileEntry(name: name, createdAt: createdAt))
        }
        return entries
    }

    static func secureExistingStorage(at fileURL: URL?) throws {
        guard let fileURL else { return }
        guard let directoryFD = try openOwnedDirectory(
            at: fileURL.deletingLastPathComponent(),
            createIfMissing: false,
            makePrivate: true
        ) else {
            return
        }
        defer { Darwin.close(directoryFD) }

        let fileName = try safeBasename(of: fileURL)
        guard try regularEntryStatus(named: fileName, in: directoryFD, path: fileURL.path) != nil else {
            return
        }
        let fileFD = fileName.withCString {
            Darwin.openat(directoryFD, $0, fileReadFlags)
        }
        guard fileFD >= 0 else { throw posixError(path: fileURL.path) }
        defer { Darwin.close(fileFD) }
        try requirePrivateRegularFileDescriptor(fileFD, path: fileURL.path)
        guard Darwin.fchmod(fileFD, filePermissions) == 0 else {
            throw posixError(path: fileURL.path)
        }
    }

    /// Reads only through a validated directory descriptor. Nil means the
    /// directory or final entry genuinely does not exist; every unsafe shape
    /// throws and therefore remains outside the store's ownership boundary.
    static func readExistingData(at fileURL: URL?) throws -> Data? {
        guard let fileURL else { return nil }
        guard let directoryFD = try openOwnedDirectory(
            at: fileURL.deletingLastPathComponent(),
            createIfMissing: false,
            makePrivate: false
        ) else {
            return nil
        }
        defer { Darwin.close(directoryFD) }

        let fileName = try safeBasename(of: fileURL)
        guard try regularEntryStatus(named: fileName, in: directoryFD, path: fileURL.path) != nil else {
            return nil
        }
        let fileFD = fileName.withCString {
            Darwin.openat(directoryFD, $0, fileReadFlags)
        }
        guard fileFD >= 0 else { throw posixError(path: fileURL.path) }
        do {
            try requirePrivateRegularFileDescriptor(fileFD, path: fileURL.path)
        } catch {
            Darwin.close(fileFD)
            throw error
        }
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    static func writeAtomically(_ data: Data, to fileURL: URL) throws {
        guard let directoryFD = try openOwnedDirectory(
            at: fileURL.deletingLastPathComponent(),
            createIfMissing: true,
            makePrivate: true
        ) else {
            throw posixError(path: fileURL.deletingLastPathComponent().path, code: ENOENT)
        }
        defer { Darwin.close(directoryFD) }

        let fileName = try safeBasename(of: fileURL)
        _ = try regularEntryStatus(named: fileName, in: directoryFD, path: fileURL.path)

        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        var temporaryFD = temporaryName.withCString {
            Darwin.openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                filePermissions
            )
        }
        guard temporaryFD >= 0 else { throw posixError(path: fileURL.path) }
        defer {
            if temporaryFD >= 0 { Darwin.close(temporaryFD) }
            _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
        }

        do {
            try writeAll(data, to: temporaryFD, path: fileURL.path)
            guard Darwin.fchmod(temporaryFD, filePermissions) == 0 else {
                throw posixError(path: fileURL.path)
            }
            guard Darwin.fsync(temporaryFD) == 0 else {
                throw posixError(path: fileURL.path)
            }
        } catch {
            throw error
        }
        guard Darwin.close(temporaryFD) == 0 else {
            temporaryFD = -1
            throw posixError(path: fileURL.path)
        }
        temporaryFD = -1

        let renameStatus = temporaryName.withCString { source in
            fileName.withCString { destination in
                Darwin.renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard renameStatus == 0 else { throw posixError(path: fileURL.path) }
        // Callers may clear the only cross-store recovery proof immediately
        // after this returns, so the renamed directory entry must be durable.
        guard Darwin.fsync(directoryFD) == 0 else {
            throw posixError(path: fileURL.deletingLastPathComponent().path)
        }
    }

    private static func openOwnedDirectory(
        at directoryURL: URL,
        createIfMissing: Bool,
        makePrivate: Bool
    ) throws -> Int32? {
        var entry = stat()
        let exists = directoryURL.path.withCString { Darwin.lstat($0, &entry) == 0 }
        if !exists {
            let lookupError = errno
            guard lookupError == ENOENT else {
                throw posixError(path: directoryURL.path, code: lookupError)
            }
            let parentURL = directoryURL.deletingLastPathComponent()
            let parentFD = try openExistingDirectory(at: parentURL, makePrivate: false)
            defer { Darwin.close(parentFD) }
            guard createIfMissing else { return nil }
            let directoryName = try safeBasename(of: directoryURL)
            let createStatus = directoryName.withCString {
                Darwin.mkdirat(parentFD, $0, directoryPermissions)
            }
            if createStatus != 0 {
                let createError = errno
                guard createError == EEXIST else {
                    throw posixError(path: directoryURL.path, code: createError)
                }
            }
            // A caller may immediately move the only recording into this new
            // child and sync that child. The parent-to-child directory entry
            // therefore has to be durable first, or a power loss could erase
            // the whole private boundary together with its moved audio.
            guard Darwin.fsync(parentFD) == 0 else {
                throw posixError(path: parentURL.path)
            }
        } else {
            guard (entry.st_mode & S_IFMT) == S_IFDIR else {
                throw unsafeBoundaryError(path: directoryURL.path)
            }
        }
        return try openExistingDirectory(at: directoryURL, makePrivate: makePrivate)
    }

    private static func openExistingDirectory(
        at directoryURL: URL,
        makePrivate: Bool
    ) throws -> Int32 {
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, directoryOpenFlags)
        }
        guard descriptor >= 0 else { throw posixError(path: directoryURL.path) }
        do {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw posixError(path: directoryURL.path)
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                throw unsafeBoundaryError(path: directoryURL.path)
            }
            if makePrivate, Darwin.fchmod(descriptor, directoryPermissions) != 0 {
                throw posixError(path: directoryURL.path)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func regularEntryStatus(
        named fileName: String,
        in directoryFD: Int32,
        path: String
    ) throws -> stat? {
        var status = stat()
        let result = fileName.withCString {
            Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            let lookupError = errno
            if lookupError == ENOENT { return nil }
            throw posixError(path: path, code: lookupError)
        }
        guard
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_nlink == 1
        else {
            throw unsafeBoundaryError(path: path)
        }
        return status
    }

    private static func requirePrivateRegularFileDescriptor(
        _ descriptor: Int32,
        path: String
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError(path: path)
        }
        guard
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_nlink == 1
        else {
            throw unsafeBoundaryError(path: path)
        }
    }

    private static func safeBasename(of url: URL) throws -> String {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw unsafeBoundaryError(path: url.path)
        }
        return name
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: path)
                }
                guard written > 0 else {
                    throw posixError(path: path, code: EIO)
                }
                offset += written
            }
        }
    }

    private static func copyAll(from source: Int32, to destination: Int32, path: String) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(source, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(path: path)
            }
            if count == 0 { return }
            try buffer.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(
                        destination,
                        baseAddress.advanced(by: offset),
                        count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError(path: path)
                    }
                    guard written > 0 else { throw posixError(path: path, code: EIO) }
                    offset += written
                }
            }
        }
    }

    private static func unsafeBoundaryError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ELOOP),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "The private storage boundary contains a symbolic link or non-owned entry.",
            ]
        )
    }

    private static func posixError(
        path: String,
        code: Int32 = errno
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
