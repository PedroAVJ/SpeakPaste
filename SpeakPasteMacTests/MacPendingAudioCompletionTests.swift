import Foundation
import XCTest
@testable import SpeakPaste

final class MacPendingAudioCompletionTests: XCTestCase {
    func testFailedCompletionMarkerCommitStaysHiddenAndHistoryRepairsRelaunch() async throws {
        try await MainActor.run {
            let scratch = try makeCompletionScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
            let source = scratch.appendingPathComponent("recording.wav")
            let payload = Data("deliver this only once".utf8)
            try payload.write(to: source)

            var writeCount = 0
            let store = MacPendingAudioStore(
                directoryURL: audioDirectory,
                beforeIndexWrite: {
                    writeCount += 1
                    if writeCount == 2 { throw CompletionTestError.injectedIndexWrite }
                }
            )
            let staged = try store.stage(
                sourceURL: source,
                deviceName: "Continuity microphone",
                recordingDuration: 2
            )
            let durableURL = try store.audioURL(for: staged)

            let (suiteName, defaults) = makeCompletionDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let history = MacHistoryStore(
                defaults: defaults,
                directory: scratch.appendingPathComponent("History", isDirectory: true)
            )
            let historyRecord = MacTranscriptRecord(
                text: "Already transcribed",
                destination: "Editor",
                deviceName: staged.deviceName,
                recordingDuration: staged.recordingDuration,
                sourcePendingAudioID: staged.id
            )
            XCTAssertTrue(history.append(historyRecord))

            XCTAssertThrowsError(
                try store.markCompleted(staged.id, historyRecordID: historyRecord.id)
            )
            // The failed journal write leaves the old active record on disk,
            // but History confirmation makes every retry-facing API fail shut.
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertNil(store.record(withID: staged.id))
            XCTAssertThrowsError(try store.markWaiting(staged.id, reason: "Never retry"))
            XCTAssertEqual(try Data(contentsOf: durableURL), payload)

            let reloaded = MacPendingAudioStore(directoryURL: audioDirectory)
            XCTAssertNotNil(reloaded.record(withID: staged.id))
            let links = Dictionary(
                uniqueKeysWithValues: history.records.compactMap { record in
                    record.sourcePendingAudioID.map { ($0, record.id) }
                }
            )
            try reloaded.reconcileCompletedHistory(links)
            try reloaded.finishCompletedCleanup(authorizedPendingAudioIDs: [staged.id])

            XCTAssertTrue(reloaded.records.isEmpty)
            XCTAssertNil(reloaded.record(withID: staged.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
            XCTAssertTrue(MacPendingAudioStore(directoryURL: audioDirectory).records.isEmpty)
        }
    }

    func testRelaunchReconcilesHistoryCommittedBeforeMarkerWasAttempted() async throws {
        try await MainActor.run {
            let scratch = try makeCompletionScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
            let source = scratch.appendingPathComponent("recording.caf")
            try Data("crash before marker".utf8).write(to: source)

            let firstProcess = MacPendingAudioStore(directoryURL: audioDirectory)
            let staged = try firstProcess.stage(
                sourceURL: source,
                deviceName: "Continuity microphone",
                recordingDuration: 3
            )
            let durableURL = try firstProcess.audioURL(for: staged)
            let historyID = UUID()
            // Simulate process death immediately after History committed: no
            // completion API is called in the first process.

            let relaunched = MacPendingAudioStore(directoryURL: audioDirectory)
            XCTAssertEqual(relaunched.record(withID: staged.id)?.status, .waiting)
            try relaunched.reconcileCompletedHistory([staged.id: historyID])
            try relaunched.finishCompletedCleanup(authorizedPendingAudioIDs: [staged.id])

            XCTAssertTrue(relaunched.records.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
            XCTAssertTrue(MacPendingAudioStore(directoryURL: audioDirectory).records.isEmpty)
        }
    }

    func testReconcileCommitsMarkerForExactUUIDOrphanBeforeHistoryCanUnpin() throws {
        let scratch = try makeCompletionScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let pendingAudioID = UUID()
        let audioURL = audioDirectory.appendingPathComponent(
            "\(pendingAudioID.uuidString).wav"
        )
        let payload = Data("orphan left before index commit".utf8)
        try payload.write(to: audioURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: audioURL.path
        )

        var writeCount = 0
        let store = MacPendingAudioStore(
            directoryURL: audioDirectory,
            beforeIndexWrite: {
                writeCount += 1
                if writeCount == 1 { throw CompletionTestError.injectedIndexWrite }
            }
        )
        XCTAssertNil(store.record(withID: pendingAudioID))

        try store.reconcileCompletedHistory([pendingAudioID: UUID()])

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try completionCount(in: audioDirectory), 1)
        XCTAssertEqual(try Data(contentsOf: audioURL), payload)
        try store.finishCompletedCleanup(authorizedPendingAudioIDs: [pendingAudioID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(try completionCount(in: audioDirectory), 0)
    }

    func testReconcileRefusesToUnpinHistoryWithoutAudioOrDurableMarker() throws {
        let scratch = try makeCompletionScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let store = MacPendingAudioStore(directoryURL: audioDirectory)

        XCTAssertThrowsError(
            try store.reconcileCompletedHistory([UUID(): UUID()])
        ) { error in
            guard let storeError = error as? MacPendingAudioStoreError else {
                return XCTFail("Expected a pending-audio store error, got \(error)")
            }
            guard case .recordMissing = storeError else {
                return XCTFail("Expected recordMissing, got \(storeError)")
            }
        }
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try completionCount(in: audioDirectory), 0)
    }

    func testRelaunchRetainsCompletionUntilHistoryTransactionFinishesCleanup() throws {
        let scratch = try makeCompletionScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        let payload = Data("marker owns this cleanup".utf8)
        try payload.write(to: source)

        let store = MacPendingAudioStore(directoryURL: audioDirectory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Microphone",
            recordingDuration: 1
        )
        let durableURL = try store.audioURL(for: staged)
        let historyRecordID = UUID()
        let completion = try store.markCompleted(
            staged.id,
            historyRecordID: historyRecordID
        )

        XCTAssertEqual(completion.pendingAudioID, staged.id)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.record(withID: staged.id))
        XCTAssertEqual(try Data(contentsOf: durableURL), payload)
        XCTAssertEqual(try completionCount(in: audioDirectory), 1)

        let relaunched = MacPendingAudioStore(directoryURL: audioDirectory)
        XCTAssertTrue(relaunched.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: durableURL), payload)
        XCTAssertEqual(try completionCount(in: audioDirectory), 1)

        // Simulate the launch coordinator: durable marker confirmation, then
        // a successful History source-link clear, then audio cleanup.
        try relaunched.reconcileCompletedHistory([staged.id: historyRecordID])
        try relaunched.finishCompletedCleanup(authorizedPendingAudioIDs: [staged.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertEqual(try completionCount(in: audioDirectory), 0)
    }

    func testCleanupCommitFailureRetainsDurableMarkerUntilNextLaunch() throws {
        let scratch = try makeCompletionScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        try Data("unlink then fail commit".utf8).write(to: source)

        var writeCount = 0
        let store = MacPendingAudioStore(
            directoryURL: audioDirectory,
            beforeIndexWrite: {
                writeCount += 1
                if writeCount == 3 { throw CompletionTestError.injectedIndexWrite }
            }
        )
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Microphone",
            recordingDuration: 1
        )
        let durableURL = try store.audioURL(for: staged)
        _ = try store.markCompleted(staged.id, historyRecordID: UUID())

        XCTAssertThrowsError(
            try store.finishCompletedCleanup(authorizedPendingAudioIDs: [staged.id])
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.record(withID: staged.id))
        // The failed third write did not replace the second write's marker.
        XCTAssertEqual(try completionCount(in: audioDirectory), 1)

        let relaunched = MacPendingAudioStore(directoryURL: audioDirectory)
        XCTAssertTrue(relaunched.records.isEmpty)
        XCTAssertEqual(try completionCount(in: audioDirectory), 1)
        try relaunched.finishCompletedCleanup(authorizedPendingAudioIDs: [staged.id])
        XCTAssertEqual(try completionCount(in: audioDirectory), 0)
        XCTAssertTrue(MacPendingAudioStore(directoryURL: audioDirectory).records.isEmpty)
    }

    func testBlockedHistoryAuthorityPreservesRelaunchedCompletionAudioAndMarker() async throws {
        try await MainActor.run {
            let scratch = try makeCompletionScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
            let source = scratch.appendingPathComponent("recording.wav")
            let payload = Data("only remaining recovery source".utf8)
            try payload.write(to: source)

            let firstProcess = MacPendingAudioStore(directoryURL: audioDirectory)
            let staged = try firstProcess.stage(
                sourceURL: source,
                deviceName: "Microphone",
                recordingDuration: 1
            )
            let durableURL = try firstProcess.audioURL(for: staged)
            _ = try firstProcess.markCompleted(staged.id, historyRecordID: UUID())

            let historyDirectory = scratch.appendingPathComponent("History", isDirectory: true)
            try FileManager.default.createDirectory(
                at: historyDirectory,
                withIntermediateDirectories: true
            )
            let corruptHistory = Data(#"[{"unfinished":true}"#.utf8)
            try corruptHistory.write(
                to: historyDirectory.appendingPathComponent("history.json")
            )
            let (suiteName, defaults) = makeCompletionDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let history = MacHistoryStore(defaults: defaults, directory: historyDirectory)
            XCTAssertFalse(history.isPendingAudioRecoveryAuthorityTrusted)

            // AppModel gates its reconcile/clear/finish transaction on the
            // property above. Merely constructing one or more new audio stores
            // must therefore leave both recovery proofs untouched.
            let relaunched = MacPendingAudioStore(directoryURL: audioDirectory)
            XCTAssertTrue(relaunched.records.isEmpty)
            XCTAssertEqual(try Data(contentsOf: durableURL), payload)
            XCTAssertEqual(try completionCount(in: audioDirectory), 1)

            let relaunchedAgain = MacPendingAudioStore(directoryURL: audioDirectory)
            XCTAssertTrue(relaunchedAgain.records.isEmpty)
            XCTAssertEqual(try Data(contentsOf: durableURL), payload)
            XCTAssertEqual(try completionCount(in: audioDirectory), 1)
            XCTAssertEqual(
                try Data(contentsOf: historyDirectory.appendingPathComponent("history.json")),
                corruptHistory
            )
        }
    }

    func testExternallyMissingHistoryPreservesCompletionAudioAndMarker() async throws {
        try await MainActor.run {
            let scratch = try makeCompletionScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
            let source = scratch.appendingPathComponent("recording.wav")
            let payload = Data("recover after history was moved".utf8)
            try payload.write(to: source)

            let pending = MacPendingAudioStore(directoryURL: audioDirectory)
            XCTAssertFalse(pending.hasPendingCompletionCleanup)
            let staged = try pending.stage(
                sourceURL: source,
                deviceName: "Microphone",
                recordingDuration: 1
            )
            let durableURL = try pending.audioURL(for: staged)

            let historyDirectory = scratch.appendingPathComponent("History", isDirectory: true)
            let (suiteName, defaults) = makeCompletionDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let history = MacHistoryStore(defaults: defaults, directory: historyDirectory)
            let historyRecord = MacTranscriptRecord(
                text: "Text that was present",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 1,
                sourcePendingAudioID: staged.id
            )
            XCTAssertFalse(history.isPendingAudioRecoveryAuthorityTrusted)
            XCTAssertTrue(history.append(historyRecord))
            XCTAssertTrue(history.isPendingAudioRecoveryAuthorityTrusted)
            _ = try pending.markCompleted(
                staged.id,
                historyRecordID: historyRecord.id
            )
            XCTAssertTrue(pending.hasPendingCompletionCleanup)

            // Simulate the user or a recovery tool moving History away before
            // the next launch finishes the cross-store cleanup transaction.
            let historyURL = historyDirectory.appendingPathComponent("history.json")
            try FileManager.default.removeItem(at: historyURL)
            let missingHistory = MacHistoryStore(
                defaults: defaults,
                directory: historyDirectory
            )
            XCTAssertTrue(missingHistory.records.isEmpty)
            XCTAssertFalse(missingHistory.isPendingAudioRecoveryAuthorityTrusted)

            let relaunchedPending = MacPendingAudioStore(directoryURL: audioDirectory)
            XCTAssertTrue(relaunchedPending.hasPendingCompletionCleanup)
            XCTAssertEqual(try Data(contentsOf: durableURL), payload)
            XCTAssertEqual(try completionCount(in: audioDirectory), 1)
        }
    }

    func testAuthorizedCleanupNeverSweepsAnUnrelatedPreservedCompletion() throws {
        let scratch = try makeCompletionScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let store = MacPendingAudioStore(directoryURL: audioDirectory)

        let sourceA = scratch.appendingPathComponent("recording-a.wav")
        let sourceB = scratch.appendingPathComponent("recording-b.wav")
        let payloadA = Data("preserve completion A".utf8)
        let payloadB = Data("clean completion B".utf8)
        try payloadA.write(to: sourceA)
        try payloadB.write(to: sourceB)
        let recordA = try store.stage(
            sourceURL: sourceA,
            deviceName: "Microphone",
            recordingDuration: 1
        )
        let recordB = try store.stage(
            sourceURL: sourceB,
            deviceName: "Microphone",
            recordingDuration: 1
        )
        let durableA = try store.audioURL(for: recordA)
        let durableB = try store.audioURL(for: recordB)
        let historyA = UUID()
        let historyB = UUID()
        _ = try store.markCompleted(recordA.id, historyRecordID: historyA)
        _ = try store.markCompleted(recordB.id, historyRecordID: historyB)
        XCTAssertEqual(try completionCount(in: audioDirectory), 2)
        XCTAssertEqual(
            store.completedPendingAudioIDs(linkedToHistoryRecordIDs: [historyB]),
            [recordB.id]
        )

        try store.finishCompletedCleanup(authorizedPendingAudioIDs: [recordB.id])

        XCTAssertEqual(try Data(contentsOf: durableA), payloadA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableB.path))
        XCTAssertEqual(try completionCount(in: audioDirectory), 1)
        let relaunched = MacPendingAudioStore(directoryURL: audioDirectory)
        XCTAssertTrue(relaunched.hasPendingCompletionCleanup)
        XCTAssertEqual(try Data(contentsOf: durableA), payloadA)
    }

    func testUnsafeCompletedAudioStaysHiddenWhileMarkerRemainsDurable() throws {
        let scratch = try makeCompletionScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        try Data("replace after marker".utf8).write(to: source)

        let store = MacPendingAudioStore(directoryURL: audioDirectory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Microphone",
            recordingDuration: 1
        )
        let durableURL = try store.audioURL(for: staged)
        _ = try store.markCompleted(staged.id, historyRecordID: UUID())
        try FileManager.default.removeItem(at: durableURL)
        try FileManager.default.createDirectory(at: durableURL, withIntermediateDirectories: false)
        let sentinel = durableURL.appendingPathComponent("keep")
        try Data("not audio".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try store.finishCompletedCleanup(authorizedPendingAudioIDs: [staged.id])
        )
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.record(withID: staged.id))
        XCTAssertThrowsError(try store.markTranscribing(staged.id))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("not audio".utf8))
        XCTAssertEqual(try completionCount(in: audioDirectory), 1)

        let relaunched = MacPendingAudioStore(directoryURL: audioDirectory)
        XCTAssertTrue(relaunched.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("not audio".utf8))
        XCTAssertEqual(try completionCount(in: audioDirectory), 1)
    }

    func testHistorySourceLinkSurvivesPersistenceAndTextEdits() async throws {
        try await MainActor.run {
            let scratch = try makeCompletionScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makeCompletionDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("History", isDirectory: true)
            let sourceID = UUID()
            let record = MacTranscriptRecord(
                text: "Original",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 1,
                sourcePendingAudioID: sourceID
            )
            let history = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertTrue(history.append(record))

            var reloaded = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertEqual(reloaded.records.first?.sourcePendingAudioID, sourceID)
            XCTAssertTrue(reloaded.updateText(record.id, to: "Corrected"))
            reloaded = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertEqual(reloaded.records.first?.sourcePendingAudioID, sourceID)
            XCTAssertEqual(reloaded.records.first?.text, "Corrected")
        }
    }

    func testVersionTwoFutureFieldsKeepIndexByteForByteReadOnly() throws {
        let scratch = try makeCompletionScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let audioURL = directory.appendingPathComponent("\(id.uuidString).wav")
        try Data("future semantics".utf8).write(to: audioURL)
        let indexURL = directory.appendingPathComponent("pending-audio-index.json")
        let fixture = Data(
            #"{"version":2,"records":[],"tombstones":[],"completions":[],"futureConsumptionRules":{"keep":true}}"#.utf8
        )
        try fixture.write(to: indexURL)

        let store = MacPendingAudioStore(directoryURL: directory)
        let recovered = try XCTUnwrap(store.record(withID: id))
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: recovered)), Data("future semantics".utf8))
        XCTAssertThrowsError(try store.markWaiting(id, reason: "Do not rewrite"))
        XCTAssertEqual(try Data(contentsOf: indexURL), fixture)
        XCTAssertTrue(store.lastPersistenceError?.contains("newer version") == true)
    }
}

private enum CompletionTestError: Error {
    case injectedIndexWrite
}

private func makeCompletionScratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SpeakPaste-completion-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func completionCount(in directory: URL) throws -> Int {
    let indexURL = directory.appendingPathComponent("pending-audio-index.json")
    guard FileManager.default.fileExists(atPath: indexURL.path) else { return 0 }
    let data = try Data(contentsOf: indexURL)
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    return (object["completions"] as? [Any])?.count ?? 0
}

private func makeCompletionDefaults() -> (name: String, defaults: UserDefaults) {
    let name = "SpeakPaste-completion-tests-\(UUID().uuidString)"
    return (name, UserDefaults(suiteName: name)!)
}
