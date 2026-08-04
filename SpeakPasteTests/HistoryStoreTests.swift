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

    func testSeparateStoresMergeBeforeMutatingSharedDefaults() throws {
        let suiteName = "SpeakPasteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let foregroundStore = HistoryStore(defaults: defaults)
        let backgroundStore = HistoryStore(defaults: defaults)
        let backgroundItem = TranscriptItem(
            text: "Background",
            languageCode: "en",
            duration: 1
        )
        let foregroundItem = TranscriptItem(
            text: "Foreground",
            languageCode: "en",
            duration: 1
        )

        backgroundStore.add(backgroundItem)
        foregroundStore.add(foregroundItem)

        XCTAssertEqual(
            HistoryStore(defaults: defaults).items.map(\.text),
            ["Foreground", "Background"]
        )
    }

    func testNeverRetentionPreventsEveryStoreFromSaving() throws {
        let suiteName = "SpeakPasteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = HistoryStore(defaults: defaults)
        let backgroundStore = HistoryStore(defaults: defaults)

        settingsStore.setRetention(.never)
        let didPersist = backgroundStore.add(
            TranscriptItem(
                text: "Private dictation",
                languageCode: "en",
                duration: 2
            )
        )

        XCTAssertFalse(didPersist)
        XCTAssertEqual(backgroundStore.retention, .never)
        XCTAssertTrue(HistoryStore(defaults: defaults).items.isEmpty)
    }

    func testTimedRetentionPrunesOnlyExpiredItems() throws {
        let suiteName = "SpeakPasteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date()
        let store = HistoryStore(defaults: defaults)
        store.add(
            TranscriptItem(
                text: "Old",
                createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
                languageCode: nil,
                duration: 1
            )
        )
        store.add(
            TranscriptItem(
                text: "Recent",
                createdAt: now.addingTimeInterval(-6 * 24 * 60 * 60),
                languageCode: nil,
                duration: 1
            )
        )

        store.setRetention(.sevenDays, asOf: now)

        XCTAssertEqual(store.items.map(\.text), ["Recent"])
        XCTAssertEqual(HistoryStore(defaults: defaults).items.map(\.text), ["Recent"])
    }

    func testEditingTranscriptPreservesDeliveryMetadata() throws {
        let suiteName = "SpeakPasteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HistoryStore(defaults: defaults)
        let sourceSessionID = UUID()
        let original = TranscriptItem(
            text: "Before",
            createdAt: Date(timeIntervalSince1970: 123),
            languageCode: "es",
            duration: 4.5,
            sourceSessionID: sourceSessionID
        )
        store.add(original)

        let updated = try XCTUnwrap(
            store.updateText(id: original.id, text: "After")
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(updated.languageCode, "es")
        XCTAssertEqual(updated.duration, 4.5)
        XCTAssertEqual(updated.sourceSessionID, sourceSessionID)
        XCTAssertEqual(updated.text, "After")
    }

    func testRetryReplacesHistoryForTheSameDeliverySession() throws {
        let suiteName = "SpeakPasteTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HistoryStore(defaults: defaults)
        let sourceSessionID = UUID()

        store.add(
            TranscriptItem(
                text: "First attempt",
                languageCode: "en",
                duration: 3,
                sourceSessionID: sourceSessionID
            )
        )
        store.add(
            TranscriptItem(
                text: "Retry result",
                languageCode: "en",
                duration: 3,
                sourceSessionID: sourceSessionID
            )
        )

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "Retry result")
        XCTAssertEqual(store.items.first?.sourceSessionID, sourceSessionID)
    }
}
