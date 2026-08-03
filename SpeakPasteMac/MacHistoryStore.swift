import Combine
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

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        destination: String?,
        deviceName: String,
        recordingDuration: TimeInterval
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.destination = destination
        self.deviceName = deviceName
        self.recordingDuration = recordingDuration
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

    /// Days of history to keep. Zero means keep forever — the one value that
    /// expresses "never delete my transcripts" without a second setting to
    /// contradict this one.
    @Published var retentionDays: Int {
        didSet {
            guard retentionDays != oldValue else { return }
            // Assigning here does not re-enter `didSet`, so the clamped value
            // has to be written through on this pass or a negative setting
            // would show as "Forever" while the old number stayed on disk.
            if retentionDays < 0 {
                retentionDays = 0
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
    /// Nil when Application Support cannot be resolved. History then lasts only
    /// for the session, which is better than refusing to record the dictation
    /// that produced it.
    private let fileURL: URL?

    private static let retentionDaysKey = "mac-history-retention-days"
    private static let defaultRetentionDays = 30

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        let directory = directory ?? Self.applicationSupportDirectory
        fileURL = directory?.appendingPathComponent("history.json", isDirectory: false)
        // `object(forKey:)` rather than `integer(forKey:)`, because an unset
        // key reads back as 0 and 0 already means "keep forever".
        let stored = defaults.object(forKey: Self.retentionDaysKey) as? Int
        retentionDays = max(0, stored ?? Self.defaultRetentionDays)
        records = Self.decodeRecords(at: fileURL)
        sweepExpired()
    }

    /// Records the dictation. Held transcripts are appended when they finally
    /// land, which can be after a later dictation already did, so position is
    /// decided by when the audio was captured rather than by arrival order.
    func append(_ record: MacTranscriptRecord) {
        let index = records.firstIndex { $0.createdAt <= record.createdAt } ?? records.count
        records.insert(record, at: index)
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
        // SpeakPaste is meant to stay running for weeks, so sweeping only at
        // launch would quietly stretch a 30-day promise to however long the Mac
        // has been awake.
        dropExpired()
        persist()
    }

    func delete(_ id: UUID) {
        let remaining = records.filter { $0.id != id }
        guard remaining.count != records.count else { return }
        records = remaining
        persist()
    }

    /// The user's one-click purge, so it has to actually erase: emptying the
    /// array while the file still holds every transcript would be a privacy
    /// promise the app does not keep.
    func deleteAll() {
        records = []
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            // Unlinking failed; overwrite with the now-empty list instead,
            // rather than leaving the old transcripts readable on disk.
            persist()
        }
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

    /// Day arithmetic goes through Calendar rather than a multiple of 86 400 so
    /// that a daylight-saving shift cannot expire a record an hour early.
    private func sweepExpired() {
        guard dropExpired() else { return }
        persist()
    }

    /// Returns whether anything was dropped, so a caller that is about to write
    /// anyway does not write twice.
    @discardableResult
    private func dropExpired() -> Bool {
        guard retentionDays > 0 else { return false }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            return false
        }
        let kept = records.filter { $0.createdAt >= cutoff }
        guard kept.count != records.count else { return false }
        records = kept
        return true
    }

    /// Best effort by design, matching the reliability log: a history write
    /// that fails must never take down the dictation that triggered it, and the
    /// records stay live in memory either way.
    private func persist() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(records) else { return }
        // Atomic, because a partial write would leave the file undecodable and
        // cost the user every past transcript, not just the newest one.
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func decodeRecords(at url: URL?) -> [MacTranscriptRecord] {
        guard
            let url,
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([MacTranscriptRecord].self, from: data)
        else {
            return []
        }
        return Array(decoded.prefix(maximumRecords))
    }

    private static var applicationSupportDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SpeakPaste", isDirectory: true)
    }
}
