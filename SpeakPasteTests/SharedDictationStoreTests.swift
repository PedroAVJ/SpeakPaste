import XCTest
@testable import SpeakPaste

final class SharedDictationStoreTests: XCTestCase {
    func testSessionMovesFromLaunchThroughCompletionAndInsertion() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = store.begin(returnBundleIdentifier: "com.openai.chat")
        XCTAssertEqual(store.load().phase, .launching)
        XCTAssertEqual(store.load().returnBundleIdentifier, "com.openai.chat")

        store.setPhase(.recording, sessionID: session.sessionID)
        store.send(.stop, sessionID: session.sessionID)
        XCTAssertEqual(store.load().command, .stop)

        store.setPhase(.completed, sessionID: session.sessionID, transcript: "Hello world")
        XCTAssertEqual(store.load().transcript, "Hello world")
        XCTAssertEqual(store.load().command, .none)

        store.markInserted(sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .inserted)
        XCTAssertNil(store.load().transcript)
    }

    func testStaleSessionCannotOverwriteCurrentSession() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let stale = store.begin(returnBundleIdentifier: nil)
        let current = store.begin(returnBundleIdentifier: "com.apple.MobileSMS")
        store.setPhase(.failed, sessionID: stale.sessionID, errorMessage: "Stale")

        XCTAssertEqual(store.load().sessionID, current.sessionID)
        XCTAssertEqual(store.load().phase, .launching)
        XCTAssertNil(store.load().errorMessage)
    }
}
