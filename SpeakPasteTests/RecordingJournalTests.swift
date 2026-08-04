import Darwin
import XCTest
@testable import SpeakPaste

final class RecordingJournalTests: XCTestCase {
    func testCaptureDestinationIsDurableBeforeRecordingStarts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = try fixture.journal.beginCapture(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 321)
        )

        let recordingURL = try fixture.journal.audioURL(for: capture)

        XCTAssertTrue(
            recordingURL.path.hasPrefix(
                fixture.journal.activeDirectory.path + "/"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
        let relaunched = RecordingJournal(rootDirectory: fixture.journalRoot)
        XCTAssertEqual(try relaunched.audioURL(for: capture), recordingURL)
        XCTAssertEqual(try relaunched.recoverableEntries(), [])
    }

    func testStoppedActiveCaptureFinalizesWithoutTemporaryCopy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let audio = Data("durable active speech".utf8)
        let capture = try fixture.journal.beginCapture(
            ownerProcessIdentifier: .max
        )
        let recordingURL = try fixture.journal.audioURL(for: capture)
        try audio.write(to: recordingURL, options: .withoutOverwriting)

        let entry = try fixture.journal.finalizeCapture(capture, duration: 4.25)

        XCTAssertEqual(entry.id, capture.id)
        XCTAssertEqual(entry.duration, 4.25)
        XCTAssertEqual(entry.byteCount, Int64(audio.count))
        XCTAssertEqual(try fixture.journal.recoverableEntries(), [entry])
        XCTAssertEqual(
            try Data(contentsOf: fixture.journal.audioURL(for: entry)),
            audio
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.journal.activeDirectory
                    .appendingPathComponent(
                        "\(capture.id.uuidString.lowercased()).recording"
                    )
                    .path
            )
        )
    }

    func testForceQuitActiveAudioIsAdoptedOnRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let audio = Data("speech that survived force quit".utf8)
        let capture = try fixture.journal.beginCapture(
            createdAt: Date(timeIntervalSince1970: 456),
            ownerProcessIdentifier: .max
        )
        try audio.write(
            to: fixture.journal.audioURL(for: capture),
            options: .withoutOverwriting
        )

        let relaunched = RecordingJournal(rootDirectory: fixture.journalRoot)
        XCTAssertEqual(try relaunched.recoverableEntries(), [])

        let adopted = try relaunched.adoptCrashLeftCaptures()

        let entry = try XCTUnwrap(adopted.first)
        XCTAssertEqual(adopted.count, 1)
        XCTAssertEqual(entry.id, capture.id)
        XCTAssertEqual(entry.createdAt, capture.createdAt)
        XCTAssertEqual(entry.duration, 0)
        XCTAssertEqual(try relaunched.recoverableEntries(), [entry])
        XCTAssertEqual(try Data(contentsOf: relaunched.audioURL(for: entry)), audio)
    }

    func testLiveWriterCannotBeAdoptedOrFinalizedBeforeRecorderRelease() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let audio = Data("still recording".utf8)
        let capture = try fixture.journal.beginCapture()
        let recordingURL = try fixture.journal.audioURL(for: capture)
        try audio.write(to: recordingURL, options: .withoutOverwriting)

        let secondJournalInstance = RecordingJournal(
            rootDirectory: fixture.journalRoot
        )

        XCTAssertEqual(try secondJournalInstance.adoptCrashLeftCaptures(), [])
        XCTAssertEqual(try Data(contentsOf: recordingURL), audio)
        XCTAssertThrowsError(
            try fixture.journal.finalizeCapture(capture, duration: 1)
        ) { error in
            XCTAssertEqual(
                error as? RecordingJournalError,
                .captureWriterActive
            )
        }
        XCTAssertEqual(try fixture.journal.recoverableEntries(), [])
    }

    func testFinalizationStorageFailureLeavesActiveAudioRecoverable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let audio = Data("do not lose me".utf8)
        let capture = try fixture.journal.beginCapture(
            ownerProcessIdentifier: .max
        )
        let recordingURL = try fixture.journal.audioURL(for: capture)
        try audio.write(to: recordingURL, options: .withoutOverwriting)

        let realEntriesURL = fixture.journalRoot.appendingPathComponent(
            "Entries-backup",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.journal.entriesDirectory,
            to: realEntriesURL
        )
        let outsideDirectory = fixture.baseDirectory.appendingPathComponent(
            "outside-entries",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(
            symlink(outsideDirectory.path, fixture.journal.entriesDirectory.path),
            0
        )
        defer {
            _ = unlink(fixture.journal.entriesDirectory.path)
            try? FileManager.default.moveItem(
                at: realEntriesURL,
                to: fixture.journal.entriesDirectory
            )
        }

        XCTAssertThrowsError(
            try fixture.journal.finalizeCapture(capture, duration: 2)
        ) { error in
            XCTAssertEqual(error as? RecordingJournalError, .unsafeStorage)
        }
        XCTAssertEqual(try Data(contentsOf: recordingURL), audio)

        XCTAssertEqual(unlink(fixture.journal.entriesDirectory.path), 0)
        try FileManager.default.moveItem(
            at: realEntriesURL,
            to: fixture.journal.entriesDirectory
        )
        let relaunched = RecordingJournal(rootDirectory: fixture.journalRoot)
        let adopted = try relaunched.adoptCrashLeftCaptures()
        let entry = try XCTUnwrap(adopted.first)
        XCTAssertEqual(try Data(contentsOf: relaunched.audioURL(for: entry)), audio)
    }

    func testEmptyCaptureRequiresExplicitAbandonment() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = try fixture.journal.beginCapture()

        XCTAssertEqual(try fixture.journal.adoptCrashLeftCaptures(), [])
        _ = try fixture.journal.audioURL(for: capture)

        try fixture.journal.abandonCapture(capture)

        XCTAssertThrowsError(try fixture.journal.audioURL(for: capture)) { error in
            XCTAssertEqual(error as? RecordingJournalError, .captureMissing)
        }
        XCTAssertEqual(try fixture.journal.adoptCrashLeftCaptures(), [])
    }

    func testAbandonmentRefusesToDeleteCapturedAudio() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let audio = Data("partial startup speech".utf8)
        let capture = try fixture.journal.beginCapture(
            ownerProcessIdentifier: .max
        )
        let recordingURL = try fixture.journal.audioURL(for: capture)
        try audio.write(to: recordingURL, options: .withoutOverwriting)

        XCTAssertThrowsError(
            try fixture.journal.abandonCapture(capture)
        ) { error in
            XCTAssertEqual(
                error as? RecordingJournalError,
                .captureContainsAudio
            )
        }

        let adopted = try fixture.journal.adoptCrashLeftCaptures()
        let entry = try XCTUnwrap(adopted.first)
        XCTAssertEqual(try Data(contentsOf: fixture.journal.audioURL(for: entry)), audio)
    }

    func testCompleteActiveBundleLeftInStagingIsAdoptedAfterCrash() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let audio = Data("staged active speech".utf8)
        let capture = try fixture.journal.beginCapture(
            ownerProcessIdentifier: .max
        )
        let recordingURL = try fixture.journal.audioURL(for: capture)
        try audio.write(to: recordingURL, options: .withoutOverwriting)
        let activeBundleURL = recordingURL.deletingLastPathComponent()
        let crashLeftURL = fixture.journal.stagingDirectory.appendingPathComponent(
            "\(capture.id.uuidString.lowercased()).active-staging-crash",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: activeBundleURL, to: crashLeftURL)

        let relaunched = RecordingJournal(rootDirectory: fixture.journalRoot)
        let adopted = try relaunched.adoptCrashLeftCaptures()

        let entry = try XCTUnwrap(adopted.first)
        XCTAssertEqual(entry.id, capture.id)
        XCTAssertEqual(try Data(contentsOf: relaunched.audioURL(for: entry)), audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashLeftURL.path))
    }

    func testFinishedRecordingSurvivesReconstructionUntilConsumed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let audio = Data((0..<8_192).map { UInt8($0 % 251) })
        let sourceURL = try fixture.makeSource(named: "capture.m4a", data: audio)
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_234)

        let entry = try fixture.journal.stageRecording(
            at: sourceURL,
            id: id,
            duration: 12.5,
            createdAt: createdAt
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.byteCount, Int64(audio.count))
        XCTAssertEqual(entry.duration, 12.5)

        let relaunched = RecordingJournal(rootDirectory: fixture.journalRoot)
        XCTAssertEqual(try relaunched.recoverableEntries(), [entry])
        XCTAssertEqual(try Data(contentsOf: relaunched.audioURL(for: entry)), audio)

        try relaunched.consume(entry)

        XCTAssertEqual(try relaunched.recoverableEntries(), [])
        XCTAssertThrowsError(try relaunched.audioURL(for: entry)) { error in
            XCTAssertEqual(error as? RecordingJournalError, .recordMissing)
        }
    }

    func testDiscardRetiresOnlyTheChosenRecording() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = try fixture.journal.stageRecording(
            at: fixture.makeSource(named: "first.m4a", data: Data("first".utf8)),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = try fixture.journal.stageRecording(
            at: fixture.makeSource(named: "second.m4a", data: Data("second".utf8)),
            createdAt: Date(timeIntervalSince1970: 2)
        )

        try fixture.journal.discard(first)

        XCTAssertEqual(try fixture.journal.recoverableEntries(), [second])
        XCTAssertEqual(
            try Data(contentsOf: fixture.journal.audioURL(for: second)),
            Data("second".utf8)
        )
    }

    func testCompleteBundleLeftInStagingByCrashIsRecovered() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.journal.stageRecording(
            at: fixture.makeSource(named: "capture.m4a", data: Data("speech".utf8))
        )
        let committedURL = fixture.journal.entriesDirectory.appendingPathComponent(
            "\(entry.id.uuidString.lowercased()).recording",
            isDirectory: true
        )
        let crashLeftURL = fixture.journal.stagingDirectory.appendingPathComponent(
            "\(entry.id.uuidString.lowercased()).staging-crash",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: committedURL, to: crashLeftURL)

        let relaunched = RecordingJournal(rootDirectory: fixture.journalRoot)

        XCTAssertEqual(try relaunched.recoverableEntries(), [entry])
        let recoveredAudioURL = try relaunched.audioURL(for: entry)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveredAudioURL.path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashLeftURL.path))
    }

    func testDuplicateIdentifierNeverOverwritesRecoverableAudio() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let originalAudio = Data("original speech".utf8)
        let original = try fixture.journal.stageRecording(
            at: fixture.makeSource(named: "original.m4a", data: originalAudio),
            id: id
        )

        XCTAssertThrowsError(
            try fixture.journal.stageRecording(
                at: fixture.makeSource(named: "replacement.m4a", data: Data("replacement".utf8)),
                id: id
            )
        ) { error in
            XCTAssertEqual(error as? RecordingJournalError, .duplicateIdentifier)
        }

        XCTAssertEqual(try fixture.journal.recoverableEntries(), [original])
        XCTAssertEqual(
            try Data(contentsOf: fixture.journal.audioURL(for: original)),
            originalAudio
        )
    }

    func testForgedEntryCannotRetireARealRecording() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let real = try fixture.journal.stageRecording(
            at: fixture.makeSource(named: "capture.m4a", data: Data("speech".utf8))
        )
        let forged = RecordingJournalEntry(
            id: real.id,
            createdAt: real.createdAt,
            duration: real.duration,
            byteCount: real.byteCount + 1,
            audioFileExtension: real.audioFileExtension
        )

        XCTAssertThrowsError(try fixture.journal.discard(forged)) { error in
            XCTAssertEqual(error as? RecordingJournalError, .corruptRecord)
        }
        XCTAssertEqual(try fixture.journal.recoverableEntries(), [real])
    }

    func testSymbolicLinkSourceIsRejectedWithoutReadingOrRemovingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let targetData = Data("private target".utf8)
        let targetURL = try fixture.makeSource(named: "target.m4a", data: targetData)
        let linkURL = fixture.baseDirectory.appendingPathComponent("linked.m4a")
        XCTAssertEqual(symlink(targetURL.path, linkURL.path), 0)

        XCTAssertThrowsError(try fixture.journal.stageRecording(at: linkURL)) { error in
            XCTAssertEqual(error as? RecordingJournalError, .sourceMissing)
        }

        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
        XCTAssertEqual(try fixture.journal.recoverableEntries(), [])
    }

    func testSymbolicLinkEntryIsIgnoredAndNeverFollowed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let real = try fixture.journal.stageRecording(
            at: fixture.makeSource(named: "capture.m4a", data: Data("speech".utf8))
        )
        let outsideDirectory = fixture.baseDirectory.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: false
        )
        let sentinelURL = outsideDirectory.appendingPathComponent("sentinel")
        try Data("keep me".utf8).write(to: sentinelURL)
        let fakeID = UUID()
        let linkURL = fixture.journal.entriesDirectory.appendingPathComponent(
            "\(fakeID.uuidString.lowercased()).recording",
            isDirectory: true
        )
        XCTAssertEqual(symlink(outsideDirectory.path, linkURL.path), 0)

        XCTAssertEqual(try fixture.journal.recoverableEntries(), [real])
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("keep me".utf8))
    }

    func testSymbolicLinkAtJournalBoundaryFailsClosed() throws {
        let fixture = try Fixture(createJournal: false)
        defer { fixture.cleanUp() }
        let outsideDirectory = fixture.baseDirectory.appendingPathComponent(
            "outside-journal",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: false
        )
        let linkedRoot = fixture.baseDirectory.appendingPathComponent("linked-journal")
        XCTAssertEqual(symlink(outsideDirectory.path, linkedRoot.path), 0)
        let journal = RecordingJournal(rootDirectory: linkedRoot)

        XCTAssertThrowsError(try journal.recoverableEntries()) { error in
            XCTAssertEqual(error as? RecordingJournalError, .unsafeStorage)
        }
    }
}

final class AudioRecordingSafetyTrackerTests: XCTestCase {
    func testNoAudioAndDurationWarningsFireOnceBeforeHardStop() {
        var tracker = AudioRecordingSafetyTracker(
            policy: AudioRecordingSafetyPolicy(
                maximumDuration: 300,
                maximumDurationWarningLeadTime: 30,
                noAudioWarningDelay: 8,
                audiblePeakThresholdDecibels: -60
            )
        )

        XCTAssertEqual(tracker.observe(elapsed: 7.9, peakPowerDecibels: -160), [])
        XCTAssertEqual(
            tracker.observe(elapsed: 8, peakPowerDecibels: -160),
            [.noAudio(elapsed: 8)]
        )
        XCTAssertEqual(tracker.observe(elapsed: 20, peakPowerDecibels: -160), [])
        XCTAssertEqual(
            tracker.observe(elapsed: 270, peakPowerDecibels: -160),
            [.maximumDurationWarning(remaining: 30)]
        )
        XCTAssertEqual(tracker.observe(elapsed: 299, peakPowerDecibels: -160), [])
        XCTAssertEqual(
            tracker.observe(elapsed: 300, peakPowerDecibels: -160),
            [.maximumDurationReached]
        )
        XCTAssertEqual(tracker.observe(elapsed: 400, peakPowerDecibels: -160), [])
    }

    func testActualAudibleSignalSuppressesNoAudioWarning() {
        var tracker = AudioRecordingSafetyTracker()

        XCTAssertEqual(tracker.observe(elapsed: 2, peakPowerDecibels: -42), [])
        XCTAssertEqual(tracker.observe(elapsed: 10, peakPowerDecibels: -160), [])
        XCTAssertEqual(tracker.loudestPeakDecibels, -42)
    }
}

@MainActor
final class AppModelRecordingRecoveryTests: XCTestCase {
    func testActivationAdoptsStoppedActiveCaptureCreatedAfterModelLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let suiteName = "SpeakPasteAppModelRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sharedDirectory = fixture.baseDirectory.appendingPathComponent(
            "Shared",
            isDirectory: true
        )
        let sharedStore = SharedDictationStore(
            suiteName: suiteName,
            storageDirectory: sharedDirectory
        )
        let model = AppModel(
            history: HistoryStore(defaults: defaults),
            defaults: defaults,
            sharedStore: sharedStore,
            recordingJournal: fixture.journal
        )
        XCTAssertFalse(model.hasRecoverableRecording)

        // Reproduce an already-running scene: the stopped capture appears after
        // AppModel's launch-only adoption pass and remains in Active until the
        // next activation repeats adoption.
        let capture = try fixture.journal.beginCapture(
            ownerProcessIdentifier: .max
        )
        let audio = Data("released speech awaiting adoption".utf8)
        try audio.write(
            to: fixture.journal.audioURL(for: capture),
            options: .withoutOverwriting
        )

        model.handleActivation()

        XCTAssertTrue(model.hasRecoverableRecording)
        XCTAssertEqual(
            try fixture.journal.recoverableEntries().map(\.id),
            [capture.id]
        )
    }
}

private final class Fixture {
    let baseDirectory: URL
    let journalRoot: URL
    let journal: RecordingJournal

    init(createJournal: Bool = true) throws {
        baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpeakPasteRecordingJournalTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: false
        )
        journalRoot = baseDirectory.appendingPathComponent("Journal", isDirectory: true)
        journal = RecordingJournal(rootDirectory: journalRoot)
        if createJournal {
            _ = try journal.recoverableEntries()
        }
    }

    func makeSource(named name: String, data: Data) throws -> URL {
        let url = baseDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }
}
