import Foundation
import XCTest
@testable import SpeakPaste

final class MacHistoryCompletionPinningTests: XCTestCase {
    func testMarkerWriteFailurePinsRecordAgainstDeleteRetentionAndRelaunchRetry() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
            var writeCount = 0
            let pending = MacPendingAudioStore(
                directoryURL: audioDirectory,
                beforeIndexWrite: {
                    writeCount += 1
                    if writeCount == 2 { throw HistoryPinningTestError.injectedMarkerWrite }
                }
            )
            let staged = try stageHistoryPinningAudio(in: scratch, store: pending)
            let (suiteName, defaults) = makeHistoryPinningDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let historyDirectory = scratch.appendingPathComponent("History", isDirectory: true)
            let history = MacHistoryStore(defaults: defaults, directory: historyDirectory)
            let linked = historyPinningRecord(
                pendingAudioID: staged.id,
                createdAt: Date().addingTimeInterval(-120 * 24 * 60 * 60)
            )
            XCTAssertTrue(history.append(linked))

            XCTAssertThrowsError(
                try pending.reconcileCompletedHistory([staged.id: linked.id])
            )
            XCTAssertFalse(history.delete(linked.id))
            history.retentionDays = 7
            XCTAssertEqual(history.records.map(\.id), [linked.id])

            let relaunchedHistory = MacHistoryStore(
                defaults: defaults,
                directory: historyDirectory
            )
            XCTAssertEqual(relaunchedHistory.records.map(\.id), [linked.id])
            let relaunchedPending = MacPendingAudioStore(directoryURL: audioDirectory)
            XCTAssertNotNil(relaunchedPending.record(withID: staged.id))

            try relaunchedPending.reconcileCompletedHistory([staged.id: linked.id])
            XCTAssertTrue(relaunchedHistory.clearSourcePendingAudioLinks([staged.id]))
            try relaunchedPending.finishCompletedCleanup(
                authorizedPendingAudioIDs: [staged.id]
            )
            XCTAssertTrue(relaunchedHistory.delete(linked.id))
            XCTAssertTrue(relaunchedHistory.records.isEmpty)
            XCTAssertTrue(MacPendingAudioStore(directoryURL: audioDirectory).records.isEmpty)
        }
    }

    func testMarkerWriteFailurePinsEveryLinkedRecordAgainstPurge() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let audioDirectory = scratch.appendingPathComponent("PendingAudio", isDirectory: true)
            var writeCount = 0
            let pending = MacPendingAudioStore(
                directoryURL: audioDirectory,
                beforeIndexWrite: {
                    writeCount += 1
                    if writeCount == 2 { throw HistoryPinningTestError.injectedMarkerWrite }
                }
            )
            let staged = try stageHistoryPinningAudio(in: scratch, store: pending)
            let (suiteName, defaults) = makeHistoryPinningDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let history = MacHistoryStore(
                defaults: defaults,
                directory: scratch.appendingPathComponent("History", isDirectory: true)
            )
            let linked = historyPinningRecord(pendingAudioID: staged.id)
            let ordinary = historyPinningRecord(pendingAudioID: nil)
            XCTAssertTrue(history.append(linked))
            XCTAssertTrue(history.append(ordinary))

            XCTAssertThrowsError(
                try pending.reconcileCompletedHistory([staged.id: linked.id])
            )
            XCTAssertFalse(history.deleteAll())
            XCTAssertEqual(Set(history.records.map(\.id)), Set([linked.id, ordinary.id]))

            let relaunchedPending = MacPendingAudioStore(directoryURL: audioDirectory)
            try relaunchedPending.reconcileCompletedHistory([staged.id: linked.id])
            XCTAssertTrue(history.clearSourcePendingAudioLinks([staged.id]))
            try relaunchedPending.finishCompletedCleanup(
                authorizedPendingAudioIDs: [staged.id]
            )
            XCTAssertTrue(history.deleteAll())
            XCTAssertTrue(history.records.isEmpty)
        }
    }

    func testCountLimitNeverEvictsLinkedCompletionProof() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makeHistoryPinningDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(0, forKey: "mac-history-retention-days")
            let directory = scratch.appendingPathComponent("History", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date()
            let ordinary = (0 ..< MacHistoryStore.maximumRecords).map { offset in
                MacTranscriptRecord(
                    createdAt: now.addingTimeInterval(TimeInterval(-offset)),
                    text: "Ordinary \(offset)",
                    destination: nil,
                    deviceName: "Microphone",
                    recordingDuration: 1
                )
            }
            let linked = historyPinningRecord(
                pendingAudioID: UUID(),
                createdAt: now.addingTimeInterval(-10_000)
            )
            try JSONEncoder().encode(ordinary + [linked]).write(
                to: directory.appendingPathComponent("history.json")
            )

            let history = MacHistoryStore(defaults: defaults, directory: directory)

            // Launch retention is explicitly coordinated after pending-audio
            // completion recovery, not from the History constructor itself.
            XCTAssertEqual(history.records.count, MacHistoryStore.maximumRecords + 1)
            XCTAssertTrue(history.applyAutomaticLimits())
            XCTAssertEqual(history.records.count, MacHistoryStore.maximumRecords)
            XCTAssertTrue(history.records.contains(where: { $0.id == linked.id }))
            XCTAssertFalse(history.records.contains(where: { $0.id == ordinary.last?.id }))
        }
    }

    func testCommittedMarkerClearsLinkAndImmediatelyResumesRetention() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let pending = MacPendingAudioStore(
                directoryURL: scratch.appendingPathComponent("PendingAudio", isDirectory: true)
            )
            let staged = try stageHistoryPinningAudio(in: scratch, store: pending)
            let (suiteName, defaults) = makeHistoryPinningDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(7, forKey: "mac-history-retention-days")
            let history = MacHistoryStore(
                defaults: defaults,
                directory: scratch.appendingPathComponent("History", isDirectory: true)
            )
            let linked = historyPinningRecord(
                pendingAudioID: staged.id,
                createdAt: Date().addingTimeInterval(-30 * 24 * 60 * 60)
            )
            XCTAssertTrue(history.append(linked))
            XCTAssertEqual(history.records.map(\.id), [linked.id])

            try pending.reconcileCompletedHistory([staged.id: linked.id])
            XCTAssertTrue(history.clearSourcePendingAudioLinks([staged.id]))
            XCTAssertEqual(history.records.map(\.id), [linked.id])
            try pending.finishCompletedCleanup(authorizedPendingAudioIDs: [staged.id])
            XCTAssertTrue(history.applyAutomaticLimits())

            XCTAssertTrue(history.records.isEmpty)
            XCTAssertTrue(pending.records.isEmpty)
        }
    }

    func testNeverStoreKeepsOnlyTheTemporaryCompletionProof() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makeHistoryPinningDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(-1, forKey: "mac-history-retention-days")
            let history = MacHistoryStore(
                defaults: defaults,
                directory: scratch.appendingPathComponent("History", isDirectory: true)
            )
            let pendingID = UUID()
            let linked = historyPinningRecord(pendingAudioID: pendingID)
            let ordinary = historyPinningRecord(pendingAudioID: nil)

            XCTAssertTrue(history.append(linked))
            XCTAssertEqual(history.records.map(\.id), [linked.id])
            XCTAssertTrue(history.append(ordinary))
            XCTAssertEqual(history.records.map(\.id), [linked.id])

            XCTAssertTrue(history.clearSourcePendingAudioLinks([pendingID]))
            XCTAssertEqual(history.records.map(\.id), [linked.id])
            XCTAssertTrue(history.applyAutomaticLimits())
            XCTAssertTrue(history.records.isEmpty)
        }
    }

    func testNeverStoreEscrowsTranscriptBeforeRetiringHistoryAndAudioProof() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makeHistoryPinningDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(-1, forKey: "mac-history-retention-days")

            let pendingAudioDirectory = scratch.appendingPathComponent(
                "PendingAudio",
                isDirectory: true
            )
            let pendingAudio = MacPendingAudioStore(directoryURL: pendingAudioDirectory)
            let capturedAt = Date(timeIntervalSince1970: 1_725_000_123)
            let staged = try stageHistoryPinningAudio(
                in: scratch,
                store: pendingAudio,
                createdAt: capturedAt
            )
            let historyDirectory = scratch.appendingPathComponent("History", isDirectory: true)
            let history = MacHistoryStore(defaults: defaults, directory: historyDirectory)
            let historyRecord = MacTranscriptRecord(
                id: UUID(),
                createdAt: capturedAt,
                text: "The exact finished transcript",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 4,
                sourcePendingAudioID: staged.id
            )
            XCTAssertTrue(history.append(historyRecord))

            let pendingTranscriptDirectory = scratch.appendingPathComponent(
                "PendingTranscripts",
                isDirectory: true
            )
            let pendingTranscripts = MacPendingTranscriptStore(
                directory: pendingTranscriptDirectory
            )

            // This is the crash-safe ordering used by AppModel: a durable text
            // handoff exists before either source-linked proof is retired.
            let escrow = try MacHistoryDeliveryEscrow.commit(
                historyRecord,
                destinationBundleIdentifier: "com.example.Editor",
                to: pendingTranscripts
            )
            XCTAssertEqual(escrow.id, historyRecord.id)

            _ = try pendingAudio.markCompleted(
                staged.id,
                historyRecordID: historyRecord.id
            )
            XCTAssertTrue(history.clearSourcePendingAudioLinks([staged.id]))
            try pendingAudio.finishCompletedCleanup(authorizedPendingAudioIDs: [staged.id])
            XCTAssertTrue(history.applyAutomaticLimits())

            XCTAssertTrue(
                MacHistoryStore(defaults: defaults, directory: historyDirectory).records.isEmpty
            )
            XCTAssertTrue(
                MacPendingAudioStore(directoryURL: pendingAudioDirectory).records.isEmpty
            )
            let relaunchedEscrow = try XCTUnwrap(
                MacPendingTranscriptStore(directory: pendingTranscriptDirectory)
                    .transcript(withID: historyRecord.id)
            )
            XCTAssertEqual(relaunchedEscrow.text, historyRecord.text)
            XCTAssertEqual(relaunchedEscrow.createdAt, capturedAt)
            XCTAssertEqual(relaunchedEscrow.destinationApplicationName, "Editor")
            XCTAssertEqual(
                relaunchedEscrow.destinationBundleIdentifier,
                "com.example.Editor"
            )
        }
    }

    func testNeverStoreEscrowCommitIsIdempotentButRejectsIdentifierCollision() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let store = MacPendingTranscriptStore(directory: scratch)
            let createdAt = Date(timeIntervalSince1970: 1_725_100_000)
            let record = MacTranscriptRecord(
                id: UUID(),
                createdAt: createdAt,
                text: "Durable text",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 1
            )

            let first = try MacHistoryDeliveryEscrow.commit(record, to: store)
            let second = try MacHistoryDeliveryEscrow.commit(record, to: store)
            XCTAssertEqual(first, second)
            XCTAssertEqual(store.transcripts.count, 1)

            var collision = first
            collision.text = "Different text using the same identifier"
            try store.upsert(collision)
            XCTAssertThrowsError(
                try MacHistoryDeliveryEscrow.commit(record, to: store)
            ) { error in
                XCTAssertEqual(
                    error as? MacHistoryDeliveryEscrowError,
                    .identifierCollision(record.id)
                )
            }
            XCTAssertEqual(store.transcripts, [collision])
        }
    }

    func testLaunchEscrowBatchIsAtomicWhenALaterRecordCollides() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let store = MacPendingTranscriptStore(directory: scratch)
            let first = historyPinningRecord(
                pendingAudioID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_725_200_000)
            )
            let second = historyPinningRecord(
                pendingAudioID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_725_200_001)
            )
            let collision = MacPendingTranscript(
                id: second.id,
                text: "Different text",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil,
                createdAt: second.createdAt
            )
            try store.upsert(collision)

            XCTAssertThrowsError(
                try MacHistoryDeliveryEscrow.commit([first, second], to: store)
            ) { error in
                XCTAssertEqual(
                    error as? MacHistoryDeliveryEscrowError,
                    .identifierCollision(second.id)
                )
            }
            XCTAssertNil(store.transcript(withID: first.id))
            XCTAssertEqual(store.transcripts, [collision])

            _ = try store.remove(second.id)
            let committed = try MacHistoryDeliveryEscrow.commit([first, second], to: store)
            XCTAssertEqual(Set(committed.map(\.id)), Set([first.id, second.id]))
            XCTAssertEqual(Set(store.transcripts.map(\.id)), Set([first.id, second.id]))
        }
    }

    func testCanonicalizationTransfersSiblingDeliveryUncertaintyAtomically() async throws {
        try await MainActor.run {
            let scratch = try makeHistoryPinningScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let store = MacPendingTranscriptStore(directory: scratch)
            let sourceID = UUID()
            let canonical = historyPinningRecord(
                pendingAudioID: sourceID,
                createdAt: Date(timeIntervalSince1970: 1_725_300_001)
            )
            let sibling = historyPinningRecord(
                pendingAudioID: sourceID,
                createdAt: Date(timeIntervalSince1970: 1_725_300_000)
            )
            _ = try MacHistoryDeliveryEscrow.commit(canonical, to: store)
            var uncertainSibling = try MacHistoryDeliveryEscrow.commit(sibling, to: store)
            uncertainSibling.deliveryState = .deliveryUncertain
            try store.upsert(uncertainSibling)

            let result = try MacHistoryDeliveryEscrow.canonicalize(
                [canonical],
                removing: [sibling],
                in: store
            )

            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.id, canonical.id)
            XCTAssertEqual(result.first?.deliveryState, .deliveryUncertain)
            XCTAssertNil(store.transcript(withID: sibling.id))
            XCTAssertEqual(store.transcripts.map(\.id), [canonical.id])

            let relaunched = MacPendingTranscriptStore(directory: scratch)
            XCTAssertEqual(
                relaunched.transcript(withID: canonical.id)?.deliveryState,
                .deliveryUncertain
            )
            XCTAssertNil(relaunched.transcript(withID: sibling.id))
        }
    }
}

private enum HistoryPinningTestError: Error {
    case injectedMarkerWrite
}

private func stageHistoryPinningAudio(
    in scratch: URL,
    store: MacPendingAudioStore,
    createdAt: Date = Date()
) throws -> MacPendingAudioRecord {
    let source = scratch.appendingPathComponent("recording-\(UUID().uuidString).wav")
    try Data("completion proof audio".utf8).write(to: source)
    return try store.stage(
        sourceURL: source,
        deviceName: "Microphone",
        recordingDuration: 1,
        createdAt: createdAt
    )
}

private func historyPinningRecord(
    pendingAudioID: UUID?,
    createdAt: Date = Date()
) -> MacTranscriptRecord {
    MacTranscriptRecord(
        createdAt: createdAt,
        text: "Pinned transcript \(UUID().uuidString)",
        destination: "Editor",
        deviceName: "Microphone",
        recordingDuration: 1,
        sourcePendingAudioID: pendingAudioID
    )
}

private func makeHistoryPinningScratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakPaste-history-pinning-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeHistoryPinningDefaults() -> (String, UserDefaults) {
    let name = "SpeakPaste-history-pinning-tests-\(UUID().uuidString)"
    return (name, UserDefaults(suiteName: name)!)
}
