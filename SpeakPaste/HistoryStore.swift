import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [TranscriptItem]

    private let defaults: UserDefaults
    private let storageKey = "transcript-history-v1"
    private let limit = 50

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([TranscriptItem].self, from: data)
        else {
            items = []
            return
        }
        items = decoded
    }

    func add(_ item: TranscriptItem) {
        items.insert(item, at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        persist()
    }

    func delete(id: UUID) {
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
}
