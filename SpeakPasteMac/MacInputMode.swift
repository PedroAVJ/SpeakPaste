import Foundation

/// The two built-in capture sources, one per source key. Exact device UIDs come
/// and go; carrying the semantic choice instead keeps an absent iPhone from
/// silently turning into the Mac microphone (or vice versa).
enum MacInputMode: String, CaseIterable, Equatable, Sendable {
    case mac
    case iPhone

    var opposite: MacInputMode {
        self == .mac ? .iPhone : .mac
    }

    var title: String {
        switch self {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        }
    }

    func matches(isContinuityDevice: Bool, isBuiltInDevice: Bool) -> Bool {
        switch self {
        case .mac: isBuiltInDevice
        case .iPhone: isContinuityDevice
        }
    }
}

/// A desktop approximation of iOS audio-session ducking. macOS does not
/// expose AVAudioSession's `duckOthers`, so SpeakPaste owns a short, reversible
/// fade of the current output volume instead of starting a second Voice
/// Processing route. The cosine easing has zero slope at both ends, which
/// avoids the audible step produced by a linear on/off volume change.
enum MacCompetingMediaFadePolicy {
    /// Leaves competing media at about one quarter of its original amplitude.
    static let attenuationDecibels = 12.0
    static let fadeDownDuration: TimeInterval = 0.40
    static let fadeUpDuration: TimeInterval = 0.90
    static let updatesPerSecond = 30.0
    /// Hardware values are read back after every app-owned write, so ownership
    /// checks need only tolerate representation noise. A real slider or volume-
    /// key change, however small, belongs to the user.
    static let ownershipTolerance = 0.001

    static func easedProgress(_ progress: Double) -> Double {
        let clamped = min(max(progress.isFinite ? progress : 0, 0), 1)
        return 0.5 - (0.5 * cos(.pi * clamped))
    }

    static func decibels(
        from start: Float,
        to end: Float,
        progress: Double
    ) -> Float {
        guard start.isFinite, end.isFinite else { return start }
        let eased = easedProgress(progress)
        return Float(Double(start) + (Double(end - start) * eased))
    }

    /// A volume-key press or another app changing the output while SpeakPaste
    /// is faded is user-owned. Once the observed value leaves this tolerance,
    /// SpeakPaste abandons the lease and will not overwrite that new choice.
    static func stillOwns(current: Float, lastWritten: Float) -> Bool {
        current.isFinite
            && lastWritten.isFinite
            && abs(Double(current - lastWritten)) <= ownershipTolerance
    }
}

struct MacCompetingMediaPendingWrite: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case fade
        case restore
    }

    let from: [UInt32: Float]
    let to: [UInt32: Float]
    let kind: Kind
}

struct MacCompetingMediaStoredLease: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let leaseID: UUID
    let deviceUID: String
    let original: [UInt32: Float]
    var committed: [UInt32: Float]
    var pendingWrite: MacCompetingMediaPendingWrite?
    var restoreRequired: Bool

    init(
        leaseID: UUID = UUID(),
        deviceUID: String,
        original: [UInt32: Float],
        committed: [UInt32: Float],
        pendingWrite: MacCompetingMediaPendingWrite? = nil,
        restoreRequired: Bool = true
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.leaseID = leaseID
        self.deviceUID = deviceUID
        self.original = original
        self.committed = committed
        self.pendingWrite = pendingWrite
        self.restoreRequired = restoreRequired
    }
}

enum MacCompetingMediaLeasePolicy {
    static func hasSameElements(
        _ lhs: [UInt32: Float],
        _ rhs: [UInt32: Float]
    ) -> Bool {
        lhs.count == rhs.count && Set(lhs.keys) == Set(rhs.keys)
    }

    static func mapsMatch(
        _ lhs: [UInt32: Float],
        _ rhs: [UInt32: Float]
    ) -> Bool {
        hasSameElements(lhs, rhs) && lhs.allSatisfy { element, value in
            guard let expected = rhs[element] else { return false }
            return MacCompetingMediaFadePolicy.stillOwns(
                current: value,
                lastWritten: expected
            )
        }
    }

    /// Live ownership is deliberately strict. The current map may be the last
    /// committed hardware readback or one side of the write-ahead transaction;
    /// any other value is an external/user change and ends app ownership.
    static func ownsLiveState(
        current: [UInt32: Float],
        lease: MacCompetingMediaStoredLease
    ) -> Bool {
        guard hasSameElements(current, lease.original) else { return false }
        if mapsMatch(current, lease.committed) { return true }
        guard let pending = lease.pendingWrite else { return false }
        return matchesPendingRealization(current, pending: pending)
    }

    /// Core Audio may realize a scalar request at a nearby selectable hardware
    /// step, including just past the requested value. The exact pre-write
    /// readback is itself selectable, so a nearest selectable result cannot be
    /// farther from the request than that known value. This bounded interval is
    /// used only while that one durable write is pending; ordinary committed-
    /// state comparisons keep the strict 0.001 tolerance.
    static func matchesPendingRealization(
        _ current: [UInt32: Float],
        pending: MacCompetingMediaPendingWrite
    ) -> Bool {
        guard hasSameElements(current, pending.from),
              hasSameElements(current, pending.to)
        else {
            return false
        }
        return current.allSatisfy { element, value in
            guard let from = pending.from[element], let to = pending.to[element] else {
                return false
            }
            return scalarMatchesPendingRealization(
                value,
                from: from,
                to: to
            )
        }
    }

    /// Recovery also accepts the original value per element. That covers a
    /// crash or HAL failure halfway through a multi-channel restore without
    /// broadening ownership to an arbitrary volume chosen by the user.
    static func ownsRecoverableState(
        current: [UInt32: Float],
        lease: MacCompetingMediaStoredLease
    ) -> Bool {
        guard hasSameElements(current, lease.original) else { return false }
        return current.allSatisfy { element, value in
            let stableCandidates = [lease.original[element], lease.committed[element]]
            if stableCandidates.compactMap({ $0 }).contains(where: {
                MacCompetingMediaFadePolicy.stillOwns(
                    current: value,
                    lastWritten: $0
                )
            }) {
                return true
            }
            guard let pending = lease.pendingWrite,
                  let from = pending.from[element],
                  let to = pending.to[element],
                  let original = lease.original[element]
            else {
                return false
            }
            // The original scalar is an exact prior hardware readback and is
            // therefore already selectable. A direct/final restore to it has
            // no rounding ambiguity: only the new durable pre-restore readback
            // and the original endpoint are ours. This matters when a crash
            // follows a partial multichannel restore whose `from` map is newer
            // than the last committed map.
            if MacCompetingMediaFadePolicy.stillOwns(
                current: to,
                lastWritten: original
            ) {
                return MacCompetingMediaFadePolicy.stillOwns(
                    current: value,
                    lastWritten: from
                ) || MacCompetingMediaFadePolicy.stillOwns(
                    current: value,
                    lastWritten: to
                )
            }
            return scalarMatchesPendingRealization(
                value,
                from: from,
                to: to
            )
        }
    }

    private static func scalarMatchesPendingRealization(
        _ value: Float,
        from: Float,
        to: Float
    ) -> Bool {
        guard value.isFinite, from.isFinite, to.isFinite else { return false }
        let distanceToKnownSelectableValue = abs(to - from)
        let lower = max(
            0,
            min(from, to - distanceToKnownSelectableValue)
        ) - Float(MacCompetingMediaFadePolicy.ownershipTolerance)
        let upper = min(
            1,
            max(from, to + distanceToKnownSelectableValue)
        ) + Float(MacCompetingMediaFadePolicy.ownershipTolerance)
        return value >= lower && value <= upper
    }
}

/// One tiny, fsynced recovery receipt under Application Support/SpeakPaste.
/// `MacPrivateStoreIO` supplies the repository's symlink-safe atomic replace,
/// private permissions, and directory fsync guarantees.
final class MacCompetingMediaLeaseStore: @unchecked Sendable {
    enum StoreError: Error {
        case applicationSupportUnavailable
        case unsupportedSchema
    }

    private let fileURL: URL?
    private let lock = NSLock()

    init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let directory: URL?
        if let applicationSupportDirectory {
            directory = applicationSupportDirectory
        } else if let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            directory = support.appendingPathComponent("SpeakPaste", isDirectory: true)
        } else {
            directory = nil
        }
        fileURL = directory?.appendingPathComponent(
            "competing-media-volume-lease.json",
            isDirectory: false
        )
    }

    func load() throws -> MacCompetingMediaStoredLease? {
        try withLock {
            guard let fileURL else { throw StoreError.applicationSupportUnavailable }
            guard let data = try MacPrivateStoreIO.readExistingData(at: fileURL) else {
                return nil
            }
            let lease = try JSONDecoder().decode(
                MacCompetingMediaStoredLease.self,
                from: data
            )
            guard lease.schemaVersion == MacCompetingMediaStoredLease.currentSchemaVersion else {
                throw StoreError.unsupportedSchema
            }
            return lease
        }
    }

    func save(_ lease: MacCompetingMediaStoredLease) throws {
        try withLock {
            guard let fileURL else { throw StoreError.applicationSupportUnavailable }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try MacPrivateStoreIO.writeAtomically(try encoder.encode(lease), to: fileURL)
        }
    }

    func remove() throws {
        try withLock {
            guard let fileURL else { throw StoreError.applicationSupportUnavailable }
            _ = try MacPrivateStoreIO.removeRegularFile(at: fileURL)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
