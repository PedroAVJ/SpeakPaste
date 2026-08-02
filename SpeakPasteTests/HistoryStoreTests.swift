import XCTest
@testable import SpeakPaste

@MainActor
final class HistoryStoreTests: XCTestCase {
    func testHistoryPersistsNewestFirstAndDeletes() throws {
        let suiteName = "SpeakPasteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = TranscriptItem(text: "First", languageCode: "en", duration: 1)
        let second = TranscriptItem(text: "Second", languageCode: "en", duration: 2)
        let store = HistoryStore(defaults: defaults)
        store.add(first)
        store.add(second)

        XCTAssertEqual(store.items.map(\.text), ["Second", "First"])
        XCTAssertEqual(HistoryStore(defaults: defaults).items.map(\.text), ["Second", "First"])

        store.delete(id: second.id)
        XCTAssertEqual(store.items, [first])
    }

    func testHistoryKeepsOnlyTheMostRecentFiftyItems() throws {
        let suiteName = "SpeakPasteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HistoryStore(defaults: defaults)

        for index in 0..<55 {
            store.add(
                TranscriptItem(
                    text: "Item \(index)",
                    languageCode: nil,
                    duration: 1
                )
            )
        }

        XCTAssertEqual(store.items.count, 50)
        XCTAssertEqual(store.items.first?.text, "Item 54")
        XCTAssertEqual(store.items.last?.text, "Item 5")
    }
}
