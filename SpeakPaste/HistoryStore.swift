import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [TranscriptItem]

    private let defaults: UserDefaults
    private let storageKey = "transcript-history-v1"
    private let limit = 50

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.loadItems(from: defaults, key: storageKey)
    }

    func reload() {
        items = Self.loadItems(from: defaults, key: storageKey)
    }

    func add(_ item: TranscriptItem) {
        items = Self.loadItems(from: defaults, key: storageKey)
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        persist()
    }

    func delete(id: UUID) {
        items = Self.loadItems(from: defaults, key: storageKey)
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
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
