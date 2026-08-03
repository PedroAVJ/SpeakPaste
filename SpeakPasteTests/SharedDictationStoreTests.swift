import XCTest
@testable import SpeakPaste

final class SharedDictationStoreTests: XCTestCase {
    @MainActor
    func testReturnTargetsRejectSystemBrokers() {
        XCTAssertTrue(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.apple.mobilenotes"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.apple.springboard"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.apple.Spotlight"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.example.unknown"
            )
        )
    }

    func testSessionMovesFromLaunchThroughCompletionAndInsertion() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = store.begin(returnBundleIdentifier: "com.openai.chat")
        XCTAssertEqual(store.load().phase, .launching)
        XCTAssertEqual(store.load().returnBundleIdentifier, "com.openai.chat")

        store.setHostResolutionDiagnostics(
            ["environment-host:<nil>", "scene.hostBundleIdentifier:com.openai.chat"],
            sessionID: session.sessionID
        )
        XCTAssertEqual(
            store.load().hostResolutionAttempts,
            ["environment-host:<nil>", "scene.hostBundleIdentifier:com.openai.chat"]
        )

        store.setReturnDiagnostics(
            ["host-url:true"],
            sessionID: session.sessionID
        )
        XCTAssertEqual(
            store.load().returnAttempts,
            ["host-url:true"]
        )

        store.setLaunchDiagnostics(
            ["responder-scene:true"],
            successfulRoute: "scene",
            sessionID: session.sessionID
        )
        XCTAssertEqual(store.load().successfulLaunchRoute, "scene")
        XCTAssertEqual(
            store.load().launchAttempts,
            ["responder-scene:true"]
        )

        store.setIncomingURLContext(
            deliveryRoute: "scene-open-url",
            sourceApplication: "com.apple.mobilenotes",
            sessionID: session.sessionID
        )
        XCTAssertEqual(
            store.load().incomingURLDeliveryRoute,
            "scene-open-url"
        )
        XCTAssertEqual(
            store.load().incomingURLSourceApplication,
            "com.apple.mobilenotes"
        )

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

    func testBackgroundSessionStaysStartingUntilCaptureIsLive() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = try XCTUnwrap(store.beginBackgroundSession())
        XCTAssertEqual(store.load().phase, .starting)

        store.setPhase(.recording, sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .recording)
        XCTAssertGreaterThanOrEqual(store.load().startedAt, session.startedAt)
    }

    func testBackgroundSessionPreservesTranscriptUntilInsertion() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let pending = try XCTUnwrap(store.beginBackgroundSession())
        store.setPhase(
            .completed,
            sessionID: pending.sessionID,
            transcript: "Do not lose me"
        )

        XCTAssertNil(store.beginBackgroundSession())
        XCTAssertEqual(store.load().sessionID, pending.sessionID)
        XCTAssertEqual(store.load().transcript, "Do not lose me")

        store.markHandled(sessionID: pending.sessionID)
        XCTAssertEqual(store.load().phase, .handled)
        XCTAssertNil(store.load().transcript)

        let next = try XCTUnwrap(store.beginBackgroundSession())
        XCTAssertNotEqual(next.sessionID, pending.sessionID)
        XCTAssertEqual(next.phase, .starting)
    }

    func testSourceApplicationCanRepairMissingReturnTarget() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = store.begin(returnBundleIdentifier: nil)
        store.setReturnBundleIdentifier(
            "com.apple.mobilenotes",
            sessionID: session.sessionID
        )

        XCTAssertEqual(
            store.load().returnBundleIdentifier,
            "com.apple.mobilenotes"
        )
    }

    func testLiveActivityStateRoundTripsBetweenAppAndWidget() throws {
        let state = SpeakPasteActivityAttributes.ContentState(
            phase: .recording,
            recordingStartedAt: Date(timeIntervalSince1970: 1_234)
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            SpeakPasteActivityAttributes.ContentState.self,
            from: encoded
        )

        XCTAssertEqual(decoded, state)
    }
}
