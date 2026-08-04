import Foundation

enum HistoryRetentionPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case never
    case oneDay
    case sevenDays
    case thirtyDays
    case ninetyDays
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .oneDay: "1 Day"
        case .sevenDays: "7 Days"
        case .thirtyDays: "30 Days"
        case .ninetyDays: "90 Days"
        case .forever: "Forever"
        }
    }

    var settingsDescription: String {
        switch self {
        case .never:
            "Don't save completed transcripts."
        case .oneDay:
            "Delete transcripts after one day."
        case .sevenDays:
            "Delete transcripts after seven days."
        case .thirtyDays:
            "Delete transcripts after 30 days."
        case .ninetyDays:
            "Delete transcripts after 90 days."
        case .forever:
            "Keep transcripts until you delete them."
        }
    }

    fileprivate var maximumAge: TimeInterval? {
        switch self {
        case .never: 0
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        case .ninetyDays: 90 * 24 * 60 * 60
        case .forever: nil
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [TranscriptItem]
    @Published private(set) var retention: HistoryRetentionPolicy

    private let defaults: UserDefaults
    private let storageKey = "transcript-history-v1"
    private let retentionKey = "transcript-history-retention-v1"
    private let limit = 50

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let savedRetention = defaults.string(forKey: retentionKey)
            .flatMap(HistoryRetentionPolicy.init(rawValue:))
            ?? .forever
        let loadedItems = Self.loadItems(from: defaults, key: storageKey)
        let retainedItems = Self.retainedItems(
            loadedItems,
            for: savedRetention,
            asOf: Date()
        )

        retention = savedRetention
        items = Array(retainedItems.prefix(limit))

        if items != loadedItems {
            Self.persist(items, to: defaults, key: storageKey)
        }
    }

    func reload(asOf date: Date = Date()) {
        let savedRetention = defaults.string(forKey: retentionKey)
            .flatMap(HistoryRetentionPolicy.init(rawValue:))
            ?? .forever
        if retention != savedRetention {
            retention = savedRetention
        }
        let loadedItems = Self.loadItems(from: defaults, key: storageKey)
        items = Array(
            Self.retainedItems(loadedItems, for: retention, asOf: date)
                .prefix(limit)
        )
        if items != loadedItems {
            persist()
        }
    }

    @discardableResult
    func add(_ item: TranscriptItem) -> Bool {
        reload()
        guard retention != .never else { return false }

        items.removeAll {
            $0.id == item.id
                || (item.sourceSessionID != nil
                    && $0.sourceSessionID == item.sourceSessionID)
        }
        items.insert(item, at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        persist()
        return true
    }

    @discardableResult
    func updateText(id: UUID, text: String) -> TranscriptItem? {
        reload()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let previous = items[index]
        let updated = TranscriptItem(
            id: previous.id,
            text: text,
            createdAt: previous.createdAt,
            languageCode: previous.languageCode,
            duration: previous.duration,
            sourceSessionID: previous.sourceSessionID
        )
        items[index] = updated
        persist()
        return updated
    }

    func delete(id: UUID) {
        reload()
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    func itemsRemoved(
        by policy: HistoryRetentionPolicy,
        asOf date: Date = Date()
    ) -> Int {
        let loadedItems = Self.loadItems(from: defaults, key: storageKey)
        let retainedIDs = Set(
            Self.retainedItems(loadedItems, for: policy, asOf: date).map(\.id)
        )
        return loadedItems.reduce(into: 0) { count, item in
            if !retainedIDs.contains(item.id) {
                count += 1
            }
        }
    }

    func setRetention(
        _ policy: HistoryRetentionPolicy,
        asOf date: Date = Date()
    ) {
        retention = policy
        defaults.set(policy.rawValue, forKey: retentionKey)
        reload(asOf: date)
    }

    private func persist() {
        Self.persist(items, to: defaults, key: storageKey)
    }

    private static func persist(
        _ items: [TranscriptItem],
        to defaults: UserDefaults,
        key: String
    ) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }

    private static func retainedItems(
        _ items: [TranscriptItem],
        for policy: HistoryRetentionPolicy,
        asOf date: Date
    ) -> [TranscriptItem] {
        guard let maximumAge = policy.maximumAge else { return items }
        guard maximumAge > 0 else { return [] }
        let cutoff = date.addingTimeInterval(-maximumAge)
        return items.filter { $0.createdAt >= cutoff }
    }

    private static func loadItems(
        from defaults: UserDefaults,
        key: String
    ) -> [TranscriptItem] {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(
                [TranscriptItem].self,
                from: data
            )
        else {
            return []
        }
        return decoded
    }
}
