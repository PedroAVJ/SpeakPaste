import XCTest
@testable import SpeakPaste

final class SharedDictationStoreTests: XCTestCase {
    private func withIsolatedSharedStores(
        _ body: (
            SharedDictationStore,
            SharedDictationStore
        ) throws -> Void
    ) throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        try body(
            SharedDictationStore(
                suiteName: suiteName,
                storageDirectory: directory
            ),
            SharedDictationStore(
                suiteName: suiteName,
                storageDirectory: directory
            )
        )
    }

    func testHostCaptureBaselinePreservesCallbacksAfterCleanHandoff() {
        XCTAssertEqual(
            HostApplicationCapturePolicy.baselineGeneration(
                currentGeneration: 1,
                cleanBoundaryGeneration: nil,
                processHasEstablishedAppearance: false
            ),
            0
        )
        XCTAssertEqual(
            HostApplicationCapturePolicy.baselineGeneration(
                currentGeneration: 3,
                cleanBoundaryGeneration: 2,
                processHasEstablishedAppearance: true
            ),
            2
        )
        XCTAssertEqual(
            HostApplicationCapturePolicy.baselineGeneration(
                currentGeneration: 3,
                cleanBoundaryGeneration: nil,
                processHasEstablishedAppearance: true
            ),
            3
        )
    }

    func testHostCapturePolicyRequiresNewGenerationAndStableProcess() {
        XCTAssertTrue(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 12,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 474,
                previousIdentity: nil
            )
        )
        XCTAssertFalse(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 11,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 474,
                previousIdentity: nil
            )
        )
        XCTAssertFalse(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 12,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 475,
                previousIdentity: nil
            )
        )
        XCTAssertFalse(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 12,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: nil,
                currentProcessIdentifier: nil,
                previousIdentity: nil
            )
        )
    }

    func testHostCapturePolicyRejectsTransientBrokerAndCorruptedCache() {
        let supported = [
            "com.apple.mobilenotes",
            "net.whatsapp.WhatsApp",
        ]
        XCTAssertEqual(
            HostApplicationCapturePolicy.canonicalSupportedBundleIdentifier(
                " net.whatsapp.whatsapp ",
                supportedBundleIdentifiers: supported
            ),
            "net.whatsapp.WhatsApp"
        )
        XCTAssertNil(
            HostApplicationCapturePolicy.canonicalSupportedBundleIdentifier(
                "com.apple.SafariViewService",
                supportedBundleIdentifiers: supported
            )
        )

        let corrupted = HostApplicationIdentity(
            bundleIdentifier: "com.apple.SafariViewService",
            processIdentifier: 474,
            capturedAt: Date()
        )
        XCTAssertNil(
            HostApplicationCapturePolicy.supportedIdentity(
                corrupted,
                supportedBundleIdentifiers: supported
            )
        )
    }

    func testHostCapturePolicyQuarantinesLatePreviousHostCallback() {
        let now = Date(timeIntervalSince1970: 30_000)
        let previousNotes = HostApplicationIdentity(
            bundleIdentifier: "com.apple.mobilenotes",
            processIdentifier: 801,
            capturedAt: now.addingTimeInterval(-1)
        )

        XCTAssertFalse(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "com.apple.mobilenotes",
                captureGeneration: 22,
                appearanceBaselineGeneration: 21,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 474,
                previousIdentity: previousNotes
            )
        )
        XCTAssertTrue(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 23,
                appearanceBaselineGeneration: 21,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 474,
                previousIdentity: previousNotes
            )
        )
    }

    func testHostIdentityCacheRequiresExactLiveProcess() throws {
        let suiteName = "HostApplicationIdentityCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = HostApplicationIdentityCache(suiteName: suiteName)
        let capturedAt = Date(timeIntervalSince1970: 10_000)

        cache.save(
            bundleIdentifier: "net.whatsapp.WhatsApp",
            processIdentifier: 474,
            capturedAt: capturedAt
        )

        XCTAssertEqual(
            cache.matchingIdentity(
                processIdentifier: 474,
                now: capturedAt.addingTimeInterval(60)
            )?.bundleIdentifier,
            "net.whatsapp.WhatsApp"
        )
        XCTAssertNil(
            cache.matchingIdentity(
                processIdentifier: 475,
                now: capturedAt.addingTimeInterval(60)
            )
        )
        XCTAssertNil(
            cache.matchingIdentity(
                processIdentifier: nil,
                now: capturedAt.addingTimeInterval(60)
            )
        )
    }

    func testHostIdentityCacheRejectsExpiredAndFutureRecords() throws {
        let suiteName = "HostApplicationIdentityCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = HostApplicationIdentityCache(suiteName: suiteName)
        let capturedAt = Date(timeIntervalSince1970: 20_000)

        cache.save(
            bundleIdentifier: "com.apple.mobilenotes",
            processIdentifier: 801,
            capturedAt: capturedAt
        )

        XCTAssertNil(
            cache.matchingIdentity(
                processIdentifier: 801,
                now: capturedAt.addingTimeInterval(
                    HostApplicationIdentityCache.defaultMaximumAge + 1
                )
            )
        )
        XCTAssertNil(
            cache.matchingIdentity(
                processIdentifier: 801,
                now: capturedAt.addingTimeInterval(-6)
            )
        )
    }

    func testHostIdentityCacheReplacesAndClearsRecord() throws {
        let suiteName = "HostApplicationIdentityCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = HostApplicationIdentityCache(suiteName: suiteName)

        cache.save(
            bundleIdentifier: "com.apple.mobilenotes",
            processIdentifier: 700
        )
        cache.save(
            bundleIdentifier: "net.whatsapp.WhatsApp",
            processIdentifier: 701
        )

        XCTAssertNil(cache.matchingIdentity(processIdentifier: 700))
        XCTAssertEqual(
            cache.matchingIdentity(processIdentifier: 701)?.bundleIdentifier,
            "net.whatsapp.WhatsApp"
        )
        cache.clear()
        XCTAssertNil(cache.load())
    }

    @MainActor
    func testWisprStyleCatalogUsesStaticHostURLs() throws {
        let notes = try XCTUnwrap(
            HostAppSwitcher.appInfo(for: "com.apple.mobilenotes")
        )
        XCTAssertEqual(notes.displayName, "Notes")
        XCTAssertEqual(notes.launchURL.absoluteString, "mobilenotes://")
        XCTAssertTrue(
            HostAppSwitcher.supportsAutomaticReturn(
                to: "com.openai.chat"
            )
        )
        XCTAssertTrue(
            HostAppSwitcher.supportsAutomaticReturn(
                to: "ch.protonmail.protonmail"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.supportsAutomaticReturn(
                to: "com.example.unsupported"
            )
        )
        XCTAssertEqual(
            HostAppSwitcher.anticipatedRoute(
                for: "com.apple.mobilenotes"
            ),
            "host-url"
        )
        XCTAssertEqual(
            HostAppSwitcher.anticipatedAttempts(
                for: "net.whatsapp.WhatsApp",
                processIdentifier: 474
            ),
            [
                "return-target-shared-bundle:net.whatsapp.WhatsApp",
                "host-catalog:net.whatsapp.WhatsApp",
                "host-url:pending",
            ]
        )
        XCTAssertEqual(
            HostAppSwitcher.anticipatedRoute(
                for: "com.example.unsupported"
            ),
            "manual-switchback"
        )
    }

    func testInsertionFingerprintTreatsNilAndEmptyProxyContextAsEquivalent() {
        let documentID = UUID()
        let nilContext = InsertionContextFingerprint.make(
            documentIdentifier: documentID,
            textBeforeInput: nil,
            textAfterInput: nil,
            selectedText: nil,
            keyboardType: nil
        )
        let emptyContext = InsertionContextFingerprint.make(
            documentIdentifier: documentID,
            textBeforeInput: "",
            textAfterInput: "",
            selectedText: "",
            keyboardType: 0
        )

        XCTAssertEqual(nilContext, emptyContext)
    }

    func testInsertionFingerprintStillDetectsRealCursorAndFieldChanges() {
        let documentID = UUID()
        let original = InsertionContextFingerprint.make(
            documentIdentifier: documentID,
            textBeforeInput: "hello",
            textAfterInput: " world",
            selectedText: nil,
            keyboardType: 0
        )
        let movedCursor = InsertionContextFingerprint.make(
            documentIdentifier: documentID,
            textBeforeInput: "hello ",
            textAfterInput: "world",
            selectedText: nil,
            keyboardType: 0
        )
        let differentField = InsertionContextFingerprint.make(
            documentIdentifier: UUID(),
            textBeforeInput: "hello",
            textAfterInput: " world",
            selectedText: nil,
            keyboardType: 0
        )

        XCTAssertNotEqual(original, movedCursor)
        XCTAssertNotEqual(original, differentField)
    }

    @MainActor
    func testReturnTargetsRejectSystemBrokersWithoutRestrictingRealApps() {
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
                "com.apple.SafariViewService"
            )
        )
        XCTAssertTrue(
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

        let session = try XCTUnwrap(store.begin(
            returnBundleIdentifier: "com.openai.chat",
            returnProcessIdentifier: 4_281
        ))
        XCTAssertEqual(store.load().phase, .launching)
        XCTAssertEqual(store.load().returnBundleIdentifier, "com.openai.chat")
        XCTAssertEqual(store.load().returnProcessIdentifier, 4_281)

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
        XCTAssertEqual(
            store.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.stop]
            ),
            .stop
        )

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

        let stale = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))
        store.setPhase(.cancelled, sessionID: stale.sessionID)
        let current = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "com.apple.MobileSMS")
        )
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
        XCTAssertEqual(store.load().sessionKind, .segmentedIntent)

        store.setPhase(.recording, sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .recording)
        XCTAssertGreaterThanOrEqual(store.load().startedAt, session.startedAt)
    }

    func testKeyboardAndIntentSessionsCarryDistinctOwners() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let keyboardSession = try XCTUnwrap(
                keyboard.begin(returnBundleIdentifier: "com.apple.mobilenotes")
            )
            XCTAssertEqual(
                containingApp.load().sessionKind,
                .keyboardRoundTrip
            )

            containingApp.setPhase(
                .cancelled,
                sessionID: keyboardSession.sessionID
            )
            let intentSession = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            XCTAssertEqual(intentSession.sessionKind, .segmentedIntent)
        }
    }

    func testPausedSessionRemainsDurableWithoutAHeartbeat() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .paused,
                sessionID: session.sessionID
            )

            let paused = keyboard.load()
            XCTAssertEqual(paused.phase, .paused)
            XCTAssertEqual(paused.captureOwnerID, session.sessionID)
            XCTAssertFalse(paused.phase.isContainingAppOwned)
            XCTAssertEqual(
                paused.phase.containingAppAbandonmentTimeout,
                0
            )
            XCTAssertTrue(keyboard.isCaptureLeaseActive)
            XCTAssertNil(keyboard.beginBackgroundSession())

            let beforeRevision = paused.revision ?? 0
            containingApp.touch(sessionID: session.sessionID)
            XCTAssertGreaterThan(
                keyboard.load().revision ?? 0,
                beforeRevision
            )
        }
    }

    func testPauseAndResumeCommandsCrossProcessesExactlyOnce() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID
            )

            keyboard.send(.pause, sessionID: session.sessionID)
            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.pause]
                ),
                .pause
            )
            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.pause]
                ),
                .none
            )

            containingApp.setPhase(
                .paused,
                sessionID: session.sessionID
            )
            keyboard.send(.resume, sessionID: session.sessionID)
            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.resume]
                ),
                .resume
            )
            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.resume]
                ),
                .none
            )

            let consumed = keyboard.load()
            XCTAssertEqual(consumed.command, .none)
            XCTAssertEqual(
                consumed.acknowledgedCommandSequence,
                consumed.commandSequence
            )
        }
    }

    func testOnlyOneProcessCanClaimAStaleRecordingForRecovery() throws {
        try withIsolatedSharedStores { foregroundApp, backgroundIntent in
            let session = try XCTUnwrap(
                foregroundApp.beginBackgroundSession()
            )
            foregroundApp.setPhase(
                .recording,
                sessionID: session.sessionID,
                hasRecoverableAudio: true
            )

            XCTAssertTrue(
                backgroundIntent.transitionPhase(
                    from: [.recording],
                    to: .paused,
                    sessionID: session.sessionID,
                    hasRecoverableAudio: true
                )
            )
            XCTAssertFalse(
                foregroundApp.transitionPhase(
                    from: [.recording],
                    to: .failed,
                    sessionID: session.sessionID,
                    errorMessage: "Recovered in the app",
                    hasRecoverableAudio: true,
                    recoveryAction: .retryTranscription
                )
            )
            XCTAssertEqual(foregroundApp.load().phase, .paused)
        }
    }

    func testAbandonmentFailureCannotOverwriteAFreshHeartbeat() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID,
                hasRecoverableAudio: true
            )
            let beforeHeartbeat = keyboard.load()
            containingApp.touch(sessionID: session.sessionID)

            XCTAssertFalse(
                keyboard.failAbandonedSession(
                    sessionID: session.sessionID,
                    phases: [.recording],
                    updatedAtOrBefore: beforeHeartbeat.updatedAt,
                    errorMessage: "Interrupted",
                    hasRecoverableAudio: true,
                    recoveryAction: .openContainingApp
                )
            )
            XCTAssertEqual(keyboard.load().phase, .recording)

            XCTAssertTrue(
                keyboard.failAbandonedSession(
                    sessionID: session.sessionID,
                    phases: [.recording],
                    updatedAtOrBefore: .distantFuture,
                    errorMessage: "Interrupted",
                    hasRecoverableAudio: true,
                    recoveryAction: .openContainingApp
                )
            )
            XCTAssertEqual(keyboard.load().phase, .failed)
            XCTAssertNil(keyboard.load().captureOwnerID)
            XCTAssertFalse(keyboard.isCaptureLeaseActive)
        }
    }

    func testElapsedDurationSurvivesPauseAndResume() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID,
                elapsedDuration: 0,
                startedAt: Date().addingTimeInterval(-5)
            )
            containingApp.setPhase(
                .paused,
                sessionID: session.sessionID,
                elapsedDuration: 5
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID,
                elapsedDuration: 5,
                startedAt: Date()
            )

            XCTAssertEqual(keyboard.load().elapsedDuration, 5)
        }
    }

    func testResidentKeyboardCanAimEveryBackgroundDeliveryPhase() throws {
        let claimablePhases: [SharedDictationPhase] = [
            .starting,
            .recording,
            .paused,
            .transcribing,
            .completed,
        ]

        for phase in claimablePhases {
            try withIsolatedSharedStores { containingApp, keyboard in
                let session = try XCTUnwrap(
                    containingApp.beginBackgroundSession()
                )
                if phase != .starting {
                    containingApp.setPhase(
                        phase,
                        sessionID: session.sessionID,
                        transcript: phase == .completed ? "Ready" : nil
                    )
                }

                XCTAssertTrue(
                    keyboard.claimInsertionContext(
                        sessionID: session.sessionID,
                        fingerprint: "cursor-\(phase.rawValue)"
                    ),
                    "The keyboard should be able to aim a \(phase.rawValue) session"
                )
                XCTAssertEqual(
                    containingApp.load().insertionContextFingerprint,
                    "cursor-\(phase.rawValue)"
                )
            }
        }
    }

    func testStopAndInsertReclaimsCurrentCursorBeforeStop() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            XCTAssertTrue(
                keyboard.claimInsertionContext(
                    sessionID: session.sessionID,
                    fingerprint: "resident-cursor"
                )
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID
            )

            XCTAssertTrue(
                keyboard.claimInsertionContext(
                    sessionID: session.sessionID,
                    fingerprint: "stop-tap-cursor",
                    replacingExistingClaim: true
                )
            )
            keyboard.send(.stop, sessionID: session.sessionID)

            let stop = containingApp.load()
            XCTAssertEqual(
                stop.insertionContextFingerprint,
                "stop-tap-cursor"
            )
            XCTAssertEqual(stop.command, .stop)
        }
    }

    func testCompletedBackgroundTranscriptKeepsExactOnceBoundary() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .completed,
                sessionID: session.sessionID,
                transcript: "Insert exactly once"
            )

            XCTAssertTrue(
                keyboard.claimInsertionContext(
                    sessionID: session.sessionID,
                    fingerprint: "late-visible-cursor"
                )
            )
            XCTAssertTrue(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
            XCTAssertFalse(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
            XCTAssertEqual(
                containingApp.load().transcript,
                "Insert exactly once"
            )

            keyboard.markInserted(sessionID: session.sessionID)
            XCTAssertEqual(containingApp.load().phase, .inserted)
            XCTAssertNil(containingApp.load().transcript)
            XCTAssertFalse(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
        }
    }

    func testBackgroundSessionCannotReplaceKeyboardOwnedSession() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let keyboardSession = try XCTUnwrap(store.begin(
            returnBundleIdentifier: "com.apple.mobilenotes"
        ))
        XCTAssertNil(store.beginBackgroundSession())
        XCTAssertEqual(store.load().sessionID, keyboardSession.sessionID)

        store.setPhase(.recording, sessionID: keyboardSession.sessionID)
        XCTAssertNil(store.beginBackgroundSession())
        XCTAssertEqual(store.load().phase, .recording)
    }

    func testKeyboardSessionCannotReplaceIntentOwnedSession() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let intentSession = try XCTUnwrap(store.beginBackgroundSession())
        XCTAssertNil(
            store.begin(returnBundleIdentifier: "com.apple.mobilenotes")
        )
        XCTAssertEqual(store.load().sessionID, intentSession.sessionID)
        XCTAssertEqual(store.load().phase, .starting)
    }

    func testForegroundCaptureLeaseExcludesKeyboardAndIntentRecorders() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let foregroundOwner = UUID()

        XCTAssertTrue(store.acquireCaptureLease(ownerID: foregroundOwner))
        XCTAssertTrue(store.isCaptureLeaseActive)
        XCTAssertNil(store.begin(returnBundleIdentifier: "com.openai.chat"))
        XCTAssertNil(store.beginBackgroundSession())
        XCTAssertFalse(store.releaseCaptureLease(ownerID: UUID()))

        XCTAssertTrue(store.releaseCaptureLease(ownerID: foregroundOwner))
        let keyboard = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "com.openai.chat")
        )
        XCTAssertEqual(store.load().captureOwnerID, keyboard.sessionID)
        XCTAssertTrue(store.isCaptureLeaseActive)
    }

    func testKeyboardLaunchCanBeClaimedOnlyOnce() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )

        let claimed = try XCTUnwrap(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )

        XCTAssertEqual(claimed.phase, .starting)
        XCTAssertEqual(claimed.captureOwnerID, session.sessionID)
        XCTAssertNil(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load().phase, .starting)
    }

    func testReleasedFailureCannotBeReclaimedOrHaveItsErrorReplaced() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        let originalError = "The recording journal is unavailable."
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: originalError,
            hasRecoverableAudio: false,
            recoveryAction: .openContainingApp
        )
        XCTAssertTrue(
            store.releaseCaptureLease(ownerID: session.sessionID)
        )
        let failed = store.load()

        XCTAssertNil(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load(), failed)
        XCTAssertEqual(store.load().errorMessage, originalError)
    }

    func testReleasedSetupFailureCanBeResetForAFreshAttempt() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Setup failed.",
            hasRecoverableAudio: false,
            recoveryAction: .openContainingApp
        )
        XCTAssertTrue(
            store.releaseCaptureLease(ownerID: session.sessionID)
        )

        XCTAssertTrue(
            store.resetNonrecoverableFailure(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load().phase, .idle)
        XCTAssertNotEqual(store.load().sessionID, session.sessionID)
        XCTAssertNotNil(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
    }

    func testLiveOrRecoverableFailureCannotBeResetAutomatically() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Late launch.",
            hasRecoverableAudio: false,
            recoveryAction: .openContainingApp
        )

        XCTAssertFalse(
            store.resetNonrecoverableFailure(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load().phase, .failed)

        XCTAssertTrue(
            store.releaseCaptureLease(ownerID: session.sessionID)
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Audio saved.",
            hasRecoverableAudio: true,
            recoveryAction: .retryTranscription
        )
        XCTAssertFalse(
            store.resetNonrecoverableFailure(sessionID: session.sessionID)
        )
        XCTAssertTrue(store.load().hasRecoverableAudio == true)
    }

    func testLateLaunchCanClaimWatchdogFailureWhileLeaseIsStillLive() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "SpeakPaste did not open.",
            hasRecoverableAudio: false,
            recoveryAction: .openContainingApp
        )

        let claimed = try XCTUnwrap(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )

        XCTAssertEqual(claimed.phase, .starting)
        XCTAssertNil(claimed.errorMessage)
        XCTAssertEqual(claimed.captureOwnerID, session.sessionID)
    }

    func testLiveRecoverableFailureCannotBeClaimedAsANewLaunch() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Audio saved.",
            hasRecoverableAudio: true,
            recoveryAction: .retryTranscription
        )
        let recoverable = store.load()

        XCTAssertNil(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load(), recoverable)
        XCTAssertTrue(store.load().hasRecoverableAudio == true)
    }

    func testLegacyLaunchWithoutCaptureOwnerCanBeClaimed() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "com.apple.mobilenotes")
        )
        XCTAssertTrue(
            store.releaseCaptureLease(ownerID: session.sessionID)
        )

        let claimed = try XCTUnwrap(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )

        XCTAssertEqual(claimed.phase, .starting)
        XCTAssertEqual(claimed.captureOwnerID, session.sessionID)
        XCTAssertNotNil(claimed.captureLeaseUpdatedAt)
    }

    func testExpiredCaptureLeaseCannotBlockANewRecorder() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stale = SharedDictationSnapshot.idle
        stale.captureOwnerID = UUID()
        stale.captureLeaseUpdatedAt = Date().addingTimeInterval(-60)
        defaults.set(
            try JSONEncoder().encode(stale),
            forKey: SharedDictationConstants.storageKey
        )

        let session = try XCTUnwrap(
            SharedDictationStore(suiteName: suiteName)
                .beginBackgroundSession()
        )
        XCTAssertEqual(session.phase, .starting)
        XCTAssertEqual(session.captureOwnerID, session.sessionID)
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

    func testTwoProcessesPreserveCommandAcrossHeartbeatAndConsumeItOnce() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let keyboard = SharedDictationStore(
            suiteName: suiteName,
            storageDirectory: directory
        )
        let containingApp = SharedDictationStore(
            suiteName: suiteName,
            storageDirectory: directory
        )
        let session = try XCTUnwrap(
            keyboard.begin(returnBundleIdentifier: "com.apple.mobilenotes")
        )

        keyboard.send(.stop, sessionID: session.sessionID)
        containingApp.touch(sessionID: session.sessionID)

        XCTAssertEqual(containingApp.load().command, .stop)
        XCTAssertEqual(
            containingApp.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.stop]
            ),
            .stop
        )
        XCTAssertEqual(
            containingApp.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.stop]
            ),
            .none
        )
        let consumed = keyboard.load()
        XCTAssertEqual(consumed.command, .none)
        XCTAssertEqual(
            consumed.acknowledgedCommandSequence,
            consumed.commandSequence
        )
    }

    func testPendingCommandWaitsUntilOwnerCanActOnIt() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))

        store.send(.retry, sessionID: session.sessionID)
        XCTAssertEqual(
            store.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.stop, .cancel]
            ),
            .none
        )
        XCTAssertEqual(store.load().command, .retry)
        XCTAssertEqual(
            store.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.retry]
            ),
            .retry
        )
    }

    func testPhasePublicationPreservesUnconsumedColdLaunchRetry() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))

        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Saved for recovery",
            recoveryAction: .retryTranscription
        )
        store.send(.retry, sessionID: session.sessionID)

        // App startup restores the audio and republishes its recovery status
        // before the command monitor begins. That metadata write must not eat
        // the keyboard's already-persisted Retry tap.
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Recovered recording",
            recoveryAction: .retryTranscription
        )

        XCTAssertEqual(store.load().command, .retry)
        XCTAssertEqual(
            store.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.retry]
            ),
            .retry
        )
    }

    func testScopedResetCannotEraseANewerSession() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let first = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))
        store.setPhase(.cancelled, sessionID: first.sessionID)
        let second = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))

        XCTAssertFalse(store.reset(sessionID: first.sessionID))
        XCTAssertEqual(store.load().sessionID, second.sessionID)
        XCTAssertEqual(store.load().phase, .launching)
    }

    func testCompletedPublicationFailsClosedWhenSharedStorageIsUnavailable() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = SharedDictationSnapshot(
            sessionID: UUID(),
            phase: .transcribing,
            command: .none,
            transcript: nil,
            errorMessage: nil,
            returnBundleIdentifier: nil,
            returnProcessIdentifier: nil,
            hostResolutionAttempts: nil,
            launchAttempts: nil,
            successfulLaunchRoute: nil,
            returnAttempts: nil,
            incomingURLDeliveryRoute: nil,
            incomingURLSourceApplication: nil,
            startedAt: Date(),
            updatedAt: Date()
        )
        defaults.set(
            try JSONEncoder().encode(session),
            forKey: SharedDictationConstants.storageKey
        )

        let invalidDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: invalidDirectory)
        defer { try? FileManager.default.removeItem(at: invalidDirectory) }
        let store = SharedDictationStore(
            suiteName: suiteName,
            storageDirectory: invalidDirectory
        )

        XCTAssertFalse(
            store.setPhase(
                .completed,
                sessionID: session.sessionID,
                transcript: "Must stay recoverable",
                historyPersisted: false
            )
        )
        XCTAssertEqual(store.load().phase, .transcribing)
        XCTAssertNil(store.load().transcript)
    }

    func testInsertionBoundaryKeepsTranscriptUntilDeliveryIsAcknowledged() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(
            returnBundleIdentifier: "com.openai.chat",
            insertionContextFingerprint: "field-before-recording"
        ))
        store.setPhase(
            .completed,
            sessionID: session.sessionID,
            transcript: "Crash-safe text"
        )

        XCTAssertTrue(store.markInsertionStarted(sessionID: session.sessionID))
        XCTAssertEqual(store.load().phase, .inserting)
        XCTAssertEqual(store.load().transcript, "Crash-safe text")
        XCTAssertEqual(store.load().recoveryAction, .reviewPossibleInsertion)
        XCTAssertNil(store.beginBackgroundSession())

        store.markInserted(sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .inserted)
        XCTAssertNil(store.load().transcript)
    }

    func testChangedFieldBlocksAutomaticDeliveryButAllowsExplicitRecovery() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))
        store.setPhase(
            .completed,
            sessionID: session.sessionID,
            transcript: "Keep this"
        )

        store.blockDelivery(
            sessionID: session.sessionID,
            message: "The text field changed."
        )
        XCTAssertEqual(store.load().phase, .deliveryBlocked)
        XCTAssertEqual(store.load().transcript, "Keep this")
        XCTAssertEqual(store.load().recoveryAction, .insertHere)

        store.allowExplicitInsertion(sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .completed)
        XCTAssertEqual(store.load().transcript, "Keep this")
    }

    func testAutomaticInsertionRequiresExactStopCursorFingerprint() {
        XCTAssertTrue(
            InsertionContextDeliveryPolicy.allowsAutomaticInsertion(
                claimedFingerprint: "stop-cursor",
                currentFingerprint: "stop-cursor"
            )
        )
        XCTAssertFalse(
            InsertionContextDeliveryPolicy.allowsAutomaticInsertion(
                claimedFingerprint: "stop-cursor",
                currentFingerprint: "different-cursor"
            )
        )
        XCTAssertFalse(
            InsertionContextDeliveryPolicy.allowsAutomaticInsertion(
                claimedFingerprint: nil,
                currentFingerprint: "current-cursor"
            )
        )
    }

    func testInsertionContextCanOnlyBeClaimedDuringAnActiveSessionOnce() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.beginBackgroundSession())

        XCTAssertTrue(
            store.claimInsertionContext(
                sessionID: session.sessionID,
                fingerprint: "original-field"
            )
        )
        XCTAssertFalse(
            store.claimInsertionContext(
                sessionID: session.sessionID,
                fingerprint: "different-field"
            )
        )
        XCTAssertEqual(
            store.load().insertionContextFingerprint,
            "original-field"
        )
    }

    func testSnapshotWithoutNewCoordinationFieldsStillDecodes() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sessionID = UUID()
        let oldSnapshot: [String: Any] = [
            "sessionID": sessionID.uuidString,
            "phase": "completed",
            "command": "none",
            "transcript": "From an older build",
            "startedAt": 0.0,
            "updatedAt": 1.0,
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: oldSnapshot),
            forKey: SharedDictationConstants.storageKey
        )

        let decoded = SharedDictationStore(suiteName: suiteName).load()
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.transcript, "From an older build")
        XCTAssertNil(decoded.revision)
        XCTAssertNil(decoded.recoveryAction)
    }

    func testSourceApplicationCanRepairMissingReturnTarget() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))
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
