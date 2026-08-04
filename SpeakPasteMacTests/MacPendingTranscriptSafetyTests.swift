import Foundation
import XCTest
@testable import SpeakPaste

final class MacPendingTranscriptSafetyTests: XCTestCase {
    func testHeldClipboardClaimResolvesOnlyItsExactDurableOwnerAndPayload() {
        let owner = MacHeldClipboardIdentity(
            transcriptID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_234),
            sourceText: "Same words"
        )
        let duplicateText = MacHeldClipboardIdentity(
            transcriptID: UUID(),
            createdAt: owner.createdAt.addingTimeInterval(1),
            sourceText: owner.sourceText
        )
        let claim = MacHeldClipboardClaim(
            owner: owner,
            clipboardPayload: " Same words"
        )

        XCTAssertEqual(
            MacHeldClipboardClaimResolver.ownerID(
                for: claim,
                clipboardText: claim.clipboardPayload,
                heldIdentities: [duplicateText, owner]
            ),
            owner.transcriptID
        )
        XCTAssertNil(
            MacHeldClipboardClaimResolver.ownerID(
                for: claim,
                clipboardText: "Same words",
                heldIdentities: [duplicateText, owner]
            )
        )
        XCTAssertNil(
            MacHeldClipboardClaimResolver.ownerID(
                for: claim,
                clipboardText: claim.clipboardPayload,
                heldIdentities: [duplicateText]
            )
        )
    }

    func testHeldClipboardClaimRoundTripsWithoutPendingStoreSchemaChanges() throws {
        let claim = MacHeldClipboardClaim(
            owner: MacHeldClipboardIdentity(
                transcriptID: UUID(),
                createdAt: Date(timeIntervalSince1970: 9_876),
                sourceText: "A held fragment"
            ),
            clipboardPayload: " A held fragment"
        )

        let encoded = try JSONEncoder().encode(claim)
        XCTAssertEqual(try JSONDecoder().decode(MacHeldClipboardClaim.self, from: encoded), claim)
    }

    func testBulkRemovalDeletesOnlyReviewedIDsAndPreservesHiddenEscrows() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            let store = MacPendingTranscriptStore(directory: directory)
            let first = try store.append(
                text: "Visible first",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: "com.example.editor"
            )
            let hidden = try store.append(
                text: "Hidden later delivery",
                destinationApplicationName: "Chat",
                destinationBundleIdentifier: "com.example.chat"
            )
            let third = try store.append(
                text: "Visible third",
                destinationApplicationName: "Notes",
                destinationBundleIdentifier: "com.example.notes"
            )

            let removed = try store.remove(Set([first.id, third.id, UUID()]))
            XCTAssertEqual(removed, Set([first.id, third.id]))
            XCTAssertEqual(store.transcripts, [hidden])
            XCTAssertEqual(
                MacPendingTranscriptStore(directory: directory).transcripts,
                [hidden]
            )
        }
    }

    func testDamagedDocumentShowsValidSubsetAndBlocksUpsertRemoveAndClear() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            let valid = MacPendingTranscript(
                text: "Keep this recoverable speech",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: "com.example.editor"
            )
            let validObject = try pendingRecordObject(valid)
            let fixture = try pendingDocumentData(
                schemaVersion: 1,
                records: [validObject, ["id": false, "text": 7]]
            )
            try fixture.write(to: fileURL)

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertEqual(store.transcripts, [valid])
            XCTAssertTrue(store.lastPersistenceError?.contains("1 damaged entry") == true)

            let replacement = MacPendingTranscript(
                text: "Must not flatten the damaged source",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )
            XCTAssertThrowsError(try store.upsert(replacement))
            XCTAssertThrowsError(try store.remove(valid.id))
            XCTAssertThrowsError(try store.removeAll())
            XCTAssertEqual(store.transcripts, [valid])
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testFutureSchemaShowsKnownRecordsButPreservesOriginalDocument() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            let valid = MacPendingTranscript(
                text: "Known fields from a future queue",
                destinationApplicationName: "Chat",
                destinationBundleIdentifier: "com.example.chat"
            )
            let fixture = try pendingDocumentData(
                schemaVersion: 99,
                records: [try pendingRecordObject(valid)]
            )
            try fixture.write(to: fileURL)

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertEqual(store.transcripts, [valid])
            XCTAssertTrue(store.lastPersistenceError?.contains("schema 99") == true)
            XCTAssertThrowsError(try store.upsert(valid))
            XCTAssertThrowsError(try store.remove(valid.id))
            XCTAssertThrowsError(try store.removeAll())
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testFutureDocumentAndRecordFieldsRemainReadableWithoutBeingStripped() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            let valid = MacPendingTranscript(
                text: "Do not strip future metadata",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )
            var recordObject = try pendingRecordObject(valid)
            recordObject["futureSpeakerMetadata"] = ["count": 2]
            let fixture = try pendingDocumentData(
                schemaVersion: 1,
                records: [recordObject],
                additionalFields: ["futureQueueMetadata": ["encrypted": true]]
            )
            try fixture.write(to: fileURL)

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertEqual(store.transcripts, [valid])
            XCTAssertTrue(store.lastPersistenceError?.contains("unsupported fields") == true)
            XCTAssertThrowsError(try store.upsert(valid))
            XCTAssertThrowsError(try store.remove(valid.id))
            XCTAssertThrowsError(try store.removeAll())
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testMalformedStorageRemainsByteForByteUntouched() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            let fixture = Data(#"{"schemaVersion":1,"transcripts":["#.utf8)
            try fixture.write(to: fileURL)

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertTrue(store.transcripts.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("unreadable") == true)
            let newTranscript = MacPendingTranscript(
                text: "Do not replace corrupt bytes",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )
            XCTAssertThrowsError(try store.upsert(newTranscript))
            XCTAssertThrowsError(try store.removeAll())
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testIncompleteCurrentDocumentIsNotTreatedAsAnEmptyWritableQueue() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            let fixture = Data(#"{"schemaVersion":1}"#.utf8)
            try fixture.write(to: fileURL)

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertTrue(store.transcripts.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("unsupported fields") == true)
            let transcript = MacPendingTranscript(
                text: "A missing queue key is not an empty queue",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )
            XCTAssertThrowsError(try store.upsert(transcript))
            XCTAssertThrowsError(try store.removeAll())
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testUnreadableStorageIsNotChmoddedOrOverwritten() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            let fixture = Data(#"{"private":"unknown"}"#.utf8)
            try fixture.write(to: fileURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: fileURL.path
            )

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertTrue(store.transcripts.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("could not be read") == true)
            XCTAssertEqual(try pendingSafetyPermissions(of: fileURL), 0o000)
            let transcript = MacPendingTranscript(
                text: "No ownership",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )
            XCTAssertThrowsError(try store.upsert(transcript))
            XCTAssertThrowsError(try store.removeAll())
            XCTAssertEqual(try pendingSafetyPermissions(of: fileURL), 0o000)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testDirectoryAtStoragePathIsNotReplaced() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            let storagePath = directory.appendingPathComponent(
                "pending-transcripts.json",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: storagePath,
                withIntermediateDirectories: true
            )
            let markerURL = storagePath.appendingPathComponent("marker")
            let marker = Data("leave this directory alone".utf8)
            try marker.write(to: markerURL)

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertTrue(store.transcripts.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("not a regular file") == true)
            let transcript = MacPendingTranscript(
                text: "Do not replace a directory",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )
            XCTAssertThrowsError(try store.upsert(transcript))
            XCTAssertThrowsError(try store.removeAll())
            XCTAssertEqual(try Data(contentsOf: markerURL), marker)
        }
    }

    func testSymbolicLinkStorageIsNeverFollowedOrReplaced() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let targetURL = scratch.appendingPathComponent("outside-target.json")
            let target = Data(#"{"outside":"ownership"}"#.utf8)
            try target.write(to: targetURL)
            let linkURL = directory.appendingPathComponent("pending-transcripts.json")
            try FileManager.default.createSymbolicLink(
                at: linkURL,
                withDestinationURL: targetURL
            )

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertTrue(store.transcripts.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("not a regular file") == true)
            let transcript = MacPendingTranscript(
                text: "Do not follow this link",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )
            XCTAssertThrowsError(try store.upsert(transcript))
            XCTAssertThrowsError(try store.removeAll())
            XCTAssertEqual(try Data(contentsOf: targetURL), target)
            XCTAssertEqual(
                try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink,
                true
            )
        }
    }

    func testMissingStorageRemainsWritable() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

            let store = MacPendingTranscriptStore(directory: directory)
            let transcript = try store.append(
                text: "A clean first held transcript",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )
            XCTAssertEqual(store.transcripts, [transcript])
            XCTAssertNil(store.lastPersistenceError)
            try store.removeAll()
            XCTAssertTrue(store.transcripts.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testDeliveryUncertaintyIsDurableAndLegacyEntriesDefaultToPending() async throws {
        try await MainActor.run {
            let scratch = try makePendingSafetyScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            let store = MacPendingTranscriptStore(directory: directory)
            let transcript = try store.append(
                text: "May already have been pasted",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: "com.example.editor"
            )

            try store.setDeliveryState(.deliveryUncertain, for: [transcript.id])
            XCTAssertEqual(store.transcript(withID: transcript.id)?.deliveryState, .deliveryUncertain)
            XCTAssertEqual(
                MacPendingTranscriptStore(directory: directory)
                    .transcript(withID: transcript.id)?.deliveryState,
                .deliveryUncertain
            )

            let legacyDirectory = scratch.appendingPathComponent("Legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            var legacyObject = try pendingRecordObject(transcript)
            legacyObject.removeValue(forKey: "deliveryState")
            try pendingDocumentData(schemaVersion: 1, records: [legacyObject])
                .write(to: legacyDirectory.appendingPathComponent("pending-transcripts.json"))
            let legacy = MacPendingTranscriptStore(directory: legacyDirectory)
            XCTAssertEqual(legacy.transcript(withID: transcript.id)?.deliveryState, .pending)
        }
    }
}

private func makePendingSafetyScratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SpeakPaste-pending-safety-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func pendingRecordObject(_ transcript: MacPendingTranscript) throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript))
            as? [String: Any]
    )
}

private func pendingDocumentData(
    schemaVersion: Int,
    records: [Any],
    additionalFields: [String: Any] = [:]
) throws -> Data {
    var document: [String: Any] = [
        "schemaVersion": schemaVersion,
        "transcripts": records,
    ]
    for (key, value) in additionalFields {
        document[key] = value
    }
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func pendingSafetyPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}
