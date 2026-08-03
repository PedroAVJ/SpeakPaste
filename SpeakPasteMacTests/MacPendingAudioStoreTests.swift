import Foundation
import XCTest
@testable import SpeakPaste

final class MacPendingAudioStoreTests: XCTestCase {
    func testStageMovesAudioIntoPrivateJournalAndReloadMakesItRetryable() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.caf")
        let payload = Data("captured speech".utf8)
        try payload.write(to: source)

        let id = UUID()
        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            id: id,
            deviceName: "Continuity microphone",
            recordingDuration: 3.25
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(staged.fileName, "\(id.uuidString).caf")
        XCTAssertEqual(staged.status, .transcribing)
        let durableURL = try store.audioURL(for: staged)
        XCTAssertEqual(try Data(contentsOf: durableURL), payload)
        XCTAssertEqual(try pendingAudioPermissions(of: directory), 0o700)
        XCTAssertEqual(try pendingAudioPermissions(of: durableURL), 0o600)
        XCTAssertEqual(
            try pendingAudioPermissions(
                of: directory.appendingPathComponent("pending-audio-index.json")
            ),
            0o600
        )

        let reloaded = MacPendingAudioStore(directoryURL: directory)
        let recovered = try XCTUnwrap(reloaded.record(withID: id))
        XCTAssertEqual(recovered.status, .waiting)
        XCTAssertEqual(recovered.reason, "Recovered after an interrupted transcription.")
        XCTAssertEqual(try Data(contentsOf: reloaded.audioURL(for: recovered)), payload)
        XCTAssertNil(reloaded.lastPersistenceError)
    }

    func testSuccessfulRemovalCannotReappearAsAnOrphan() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        try Data("discard me".utf8).write(to: source)

        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Built-in microphone",
            recordingDuration: 1
        )
        let durableURL = try store.audioURL(for: staged)
        try store.remove(staged.id)

        XCTAssertNil(store.record(withID: staged.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertThrowsError(try store.audioURL(for: staged))

        let reloaded = MacPendingAudioStore(directoryURL: directory)
        XCTAssertTrue(reloaded.records.isEmpty)
        XCTAssertNil(reloaded.lastPersistenceError)
    }

    func testInterruptedTombstoneFinishesDeletionBeforeOrphanRecovery() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(UUID().uuidString).wav"
        let audioURL = directory.appendingPathComponent(fileName)
        try Data("already discarded".utf8).write(to: audioURL)
        try writePendingAudioFixture(
            records: [],
            tombstones: [fileName],
            to: directory
        )

        let store = MacPendingAudioStore(directoryURL: directory)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertNil(store.lastPersistenceError)
        XCTAssertTrue(MacPendingAudioStore(directoryURL: directory).records.isEmpty)
    }

    func testCorruptIndexRecoversAudioAndKeepsTheRecoveryWarningVisible() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let audioURL = directory.appendingPathComponent("\(id.uuidString).aiff")
        let indexURL = directory.appendingPathComponent("pending-audio-index.json")
        try Data("recoverable audio".utf8).write(to: audioURL)
        try Data("not json".utf8).write(to: indexURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: directory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: audioURL.path
        )

        let store = MacPendingAudioStore(directoryURL: directory)

        let recovered = try XCTUnwrap(store.record(withID: id))
        XCTAssertEqual(recovered.status, .waiting)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: recovered)), Data("recoverable audio".utf8))
        XCTAssertNotNil(store.lastPersistenceError)
        XCTAssertEqual(try pendingAudioPermissions(of: directory), 0o700)
        XCTAssertEqual(try pendingAudioPermissions(of: audioURL), 0o600)
        XCTAssertEqual(try pendingAudioPermissions(of: indexURL), 0o600)
    }

    func testConflictingRecordsFailClosedAndRecoverEveryAudioFile() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstID = UUID()
        let secondID = UUID()
        let firstName = "\(firstID.uuidString).wav"
        let secondName = "\(secondID.uuidString).wav"
        try Data("first".utf8).write(to: directory.appendingPathComponent(firstName))
        try Data("second".utf8).write(to: directory.appendingPathComponent(secondName))
        let duplicateIDRecords = [
            pendingAudioFixtureRecord(id: firstID, fileName: firstName),
            pendingAudioFixtureRecord(id: firstID, fileName: secondName),
        ]
        try writePendingAudioFixture(
            records: duplicateIDRecords,
            tombstones: [],
            to: directory
        )

        let store = MacPendingAudioStore(directoryURL: directory)

        XCTAssertEqual(Set(store.records.map(\.id)), Set([firstID, secondID]))
        XCTAssertEqual(Set(store.records.map(\.fileName)), Set([firstName, secondName]))
        XCTAssertTrue(store.records.allSatisfy { $0.status == .waiting })
        XCTAssertTrue(store.lastPersistenceError?.contains("conflicting") == true)
    }

    func testRecordTombstoneConflictWithDifferentCasingPreservesAudio() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        let audioURL = directory.appendingPathComponent(fileName)
        try Data("must survive ambiguity".utf8).write(to: audioURL)
        try writePendingAudioFixture(
            records: [pendingAudioFixtureRecord(id: id, fileName: fileName)],
            tombstones: [fileName.lowercased()],
            to: directory
        )

        let store = MacPendingAudioStore(directoryURL: directory)

        XCTAssertNotNil(store.record(withID: id))
        XCTAssertEqual(try Data(contentsOf: audioURL), Data("must survive ambiguity".utf8))
        XCTAssertTrue(store.lastPersistenceError?.contains("conflicting") == true)
    }

    func testUnsafeTombstonedDirectoryIsNeverRecursivelyDeleted() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unsafeName = "unexpected.wav"
        let unsafeDirectory = directory.appendingPathComponent(unsafeName, isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true)
        let sentinel = unsafeDirectory.appendingPathComponent("keep.txt")
        try Data("do not delete recursively".utf8).write(to: sentinel)
        try writePendingAudioFixture(
            records: [],
            tombstones: [unsafeName],
            to: directory
        )

        let store = MacPendingAudioStore(directoryURL: directory)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertNotNil(store.lastPersistenceError)
    }

    func testFutureIndexStaysByteForByteUntouchedWhileAudioIsExposedReadOnly() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let audioURL = directory.appendingPathComponent("\(id.uuidString).wav")
        let indexURL = directory.appendingPathComponent("pending-audio-index.json")
        let futureIndex = Data(
            #"{"version":99,"records":[],"tombstones":[],"futureMetadata":{"keep":true}}"#.utf8
        )
        try Data("future recovery audio".utf8).write(to: audioURL)
        try futureIndex.write(to: indexURL)

        let store = MacPendingAudioStore(directoryURL: directory)

        let recovered = try XCTUnwrap(store.record(withID: id))
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: recovered)), Data("future recovery audio".utf8))
        XCTAssertEqual(try Data(contentsOf: indexURL), futureIndex)
        XCTAssertTrue(store.lastPersistenceError?.contains("newer version") == true)
        XCTAssertThrowsError(try store.markWaiting(recovered.id, reason: "Do not overwrite"))
        XCTAssertEqual(try Data(contentsOf: indexURL), futureIndex)

        let newSource = scratch.appendingPathComponent("new.wav")
        try Data("new speech".utf8).write(to: newSource)
        XCTAssertThrowsError(
            try store.stage(
                sourceURL: newSource,
                deviceName: "Microphone",
                recordingDuration: 1
            )
        )
        XCTAssertEqual(try Data(contentsOf: newSource), Data("new speech".utf8))
        XCTAssertEqual(try Data(contentsOf: indexURL), futureIndex)
    }

    func testSymbolicSourceAndPreexistingDestinationAreNeverFollowedOrOverwritten() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let realSource = scratch.appendingPathComponent("real.wav")
        let symbolicSource = scratch.appendingPathComponent("symbolic.wav")
        try Data("original".utf8).write(to: realSource)
        try FileManager.default.createSymbolicLink(at: symbolicSource, withDestinationURL: realSource)
        let store = MacPendingAudioStore(directoryURL: directory)

        XCTAssertThrowsError(
            try store.stage(
                sourceURL: symbolicSource,
                deviceName: "Microphone",
                recordingDuration: 1
            )
        )
        XCTAssertEqual(try Data(contentsOf: realSource), Data("original".utf8))

        let id = UUID()
        let outsideSentinel = scratch.appendingPathComponent("outside.wav")
        let secondSource = scratch.appendingPathComponent("second.wav")
        try Data("outside".utf8).write(to: outsideSentinel)
        try Data("second".utf8).write(to: secondSource)
        let occupiedDestination = directory.appendingPathComponent("\(id.uuidString).wav")
        try FileManager.default.createSymbolicLink(
            at: occupiedDestination,
            withDestinationURL: outsideSentinel
        )

        XCTAssertThrowsError(
            try store.stage(
                sourceURL: secondSource,
                id: id,
                deviceName: "Microphone",
                recordingDuration: 1
            )
        )
        XCTAssertEqual(try Data(contentsOf: secondSource), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: outsideSentinel), Data("outside".utf8))
    }

    func testFailedIndexCommitLeavesMovedAudioRecoverableOnNextCleanLaunch() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        try Data("survive failed commit".utf8).write(to: source)
        let store = MacPendingAudioStore(directoryURL: directory)
        let blockingIndexDirectory = directory.appendingPathComponent(
            "pending-audio-index.json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: blockingIndexDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try store.stage(
                sourceURL: source,
                deviceName: "Microphone",
                recordingDuration: 1
            )
        )
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let strandedAudio = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "wav" }
        )
        XCTAssertEqual(try Data(contentsOf: strandedAudio), Data("survive failed commit".utf8))

        try FileManager.default.removeItem(at: blockingIndexDirectory)
        let recoveredStore = MacPendingAudioStore(directoryURL: directory)
        let recovered = try XCTUnwrap(recoveredStore.records.first)
        XCTAssertEqual(try Data(contentsOf: recoveredStore.audioURL(for: recovered)), Data("survive failed commit".utf8))
        XCTAssertEqual(recovered.status, .waiting)
    }

    func testMarkTranscribingClaimsAWaitingRecording() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        let payload = Data("claim exactly once".utf8)
        try payload.write(to: source)

        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Continuity microphone",
            recordingDuration: 2
        )
        _ = try store.markWaiting(staged.id, reason: "Ready to retry.")

        let claimed = try store.markTranscribing(staged.id)

        XCTAssertEqual(claimed.status, .transcribing)
        XCTAssertEqual(claimed.reason, "Transcription in progress.")
        XCTAssertEqual(store.record(withID: staged.id), claimed)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: claimed)), payload)
    }

    func testReconnectEligibilityAndPartialCaptureWarningSurviveReload() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("partial.wav")
        try Data("salvaged partial speech".utf8).write(to: source)

        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Continuity microphone",
            recordingDuration: 12,
            interruptionReason: "The microphone disconnected after partial capture."
        )
        _ = try store.markWaiting(
            staged.id,
            reason: "Waiting for a connection.",
            retryOnReconnect: true
        )

        let reloaded = MacPendingAudioStore(directoryURL: directory)
        let recovered = try XCTUnwrap(reloaded.record(withID: staged.id))

        XCTAssertEqual(recovered.status, .waiting)
        XCTAssertEqual(recovered.retryOnReconnect, true)
        XCTAssertEqual(
            recovered.interruptionReason,
            "The microphone disconnected after partial capture."
        )
    }

    func testLegacyOfflineReasonMigratesOnceToTypedReconnectEligibility() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        try Data("legacy offline speech".utf8).write(
            to: directory.appendingPathComponent(fileName)
        )
        var record = pendingAudioFixtureRecord(id: id, fileName: fileName)
        record.status = .waiting
        record.reason = "Waiting for an internet connection before sending this recording to ElevenLabs. Old detail."
        try writePendingAudioFixture(records: [record], tombstones: [], to: directory)

        let migrated = MacPendingAudioStore(directoryURL: directory)
        XCTAssertEqual(migrated.record(withID: id)?.retryOnReconnect, true)

        let indexURL = directory.appendingPathComponent("pending-audio-index.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 3)
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(records.first?["retryOnReconnect"] as? Bool, true)
        XCTAssertEqual(
            MacPendingAudioStore(directoryURL: directory)
                .record(withID: id)?
                .retryOnReconnect,
            true
        )
    }

    func testMarkTranscribingRejectsADuplicateClaimWithoutChangingAudioOrIndex() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        let payload = Data("do not upload twice".utf8)
        try payload.write(to: source)

        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Continuity microphone",
            recordingDuration: 2
        )
        _ = try store.markWaiting(staged.id, reason: "Ready to retry.")
        let claimed = try store.markTranscribing(staged.id)
        let indexURL = directory.appendingPathComponent("pending-audio-index.json")
        let indexBeforeDuplicate = try Data(contentsOf: indexURL)

        XCTAssertThrowsError(try store.markTranscribing(staged.id)) { error in
            guard
                let storeError = error as? MacPendingAudioStoreError,
                case .recordNotWaiting = storeError
            else {
                return XCTFail("Expected recordNotWaiting, got \(error)")
            }
        }

        XCTAssertEqual(store.record(withID: staged.id), claimed)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: claimed)), payload)
        XCTAssertEqual(try Data(contentsOf: indexURL), indexBeforeDuplicate)
    }

    func testReloadReturnsAnInterruptedClaimToWaiting() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        let payload = Data("retry after relaunch".utf8)
        try payload.write(to: source)

        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Continuity microphone",
            recordingDuration: 2
        )
        _ = try store.markWaiting(staged.id, reason: "Ready to retry.")
        _ = try store.markTranscribing(staged.id)

        let reloaded = MacPendingAudioStore(directoryURL: directory)
        let recovered = try XCTUnwrap(reloaded.record(withID: staged.id))

        XCTAssertEqual(recovered.status, .waiting)
        XCTAssertEqual(recovered.reason, "Recovered after an interrupted transcription.")
        XCTAssertEqual(try Data(contentsOf: reloaded.audioURL(for: recovered)), payload)
    }

    func testFailedClaimCommitKeepsWaitingStateAndAudio() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        let payload = Data("survive claim failure".utf8)
        try payload.write(to: source)

        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Continuity microphone",
            recordingDuration: 2
        )
        let waiting = try store.markWaiting(staged.id, reason: "Ready to retry.")
        let durableURL = try store.audioURL(for: waiting)
        let indexURL = directory.appendingPathComponent("pending-audio-index.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.markTranscribing(staged.id))

        XCTAssertEqual(store.record(withID: staged.id), waiting)
        XCTAssertEqual(try Data(contentsOf: durableURL), payload)
    }

    func testStaleWaitingDiscardCannotDeleteAnInFlightRecording() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        let payload = Data("keep in-flight audio".utf8)
        try payload.write(to: source)

        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Continuity microphone",
            recordingDuration: 2
        )
        let durableURL = try store.audioURL(for: staged)
        let indexURL = directory.appendingPathComponent("pending-audio-index.json")
        let indexBeforeDiscard = try Data(contentsOf: indexURL)

        XCTAssertThrowsError(try store.discardWaiting(staged.id)) { error in
            guard
                let storeError = error as? MacPendingAudioStoreError,
                case .recordNotWaiting = storeError
            else {
                return XCTFail("Expected recordNotWaiting, got \(error)")
            }
        }

        XCTAssertEqual(store.record(withID: staged.id), staged)
        XCTAssertEqual(try Data(contentsOf: durableURL), payload)
        XCTAssertEqual(try Data(contentsOf: indexURL), indexBeforeDiscard)
    }

    func testDiscardWaitingRemovesAStillWaitingRecording() throws {
        let scratch = try makePendingAudioScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("recording.wav")
        try Data("discard only while waiting".utf8).write(to: source)

        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Continuity microphone",
            recordingDuration: 2
        )
        let waiting = try store.markWaiting(staged.id, reason: "Ready to retry.")
        let durableURL = try store.audioURL(for: waiting)

        try store.discardWaiting(staged.id)

        XCTAssertNil(store.record(withID: staged.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }
}

private struct PendingAudioIndexFixture: Encodable {
    let version: Int
    let records: [MacPendingAudioRecord]
    let tombstones: [String]
}

private func pendingAudioFixtureRecord(
    id: UUID,
    fileName: String
) -> MacPendingAudioRecord {
    MacPendingAudioRecord(
        id: id,
        fileName: fileName,
        deviceName: "Fixture microphone",
        recordingDuration: 2,
        reason: "Transcription in progress.",
        createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
        status: .transcribing
    )
}

private func writePendingAudioFixture(
    records: [MacPendingAudioRecord],
    tombstones: [String],
    to directory: URL
) throws {
    let fixture = PendingAudioIndexFixture(
        version: 1,
        records: records,
        tombstones: tombstones
    )
    try JSONEncoder().encode(fixture).write(
        to: directory.appendingPathComponent("pending-audio-index.json")
    )
}

private func makePendingAudioScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakPaste-pending-audio-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func pendingAudioPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}
