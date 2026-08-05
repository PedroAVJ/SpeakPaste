import AVFoundation
import Foundation
import XCTest
@testable import SpeakPaste

final class MacPersistenceStoreTests: XCTestCase {
    func testDeliveryPolicyMutationPublishesOnlyAfterPrivateAtomicWrite() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PolicyStore", isDirectory: true)
            let store = MacDeliveryPolicyStore(directory: directory)
            let policy = MacDeliveryPolicy(
                bundleIdentifier: "com.example.editor",
                applicationName: "Editor",
                deliveryMethod: .menuPaste,
                typeOutFallback: true,
                autoSend: false,
                contextKeyterms: true
            )

            XCTAssertTrue(store.upsert(policy))
            XCTAssertEqual(store.configuredPolicy(for: "COM.EXAMPLE.EDITOR"), policy)
            XCTAssertNil(store.lastPersistenceError)

            let fileURL = directory.appendingPathComponent("delivery-policies.json")
            XCTAssertEqual(try posixPermissions(of: directory), 0o700)
            XCTAssertEqual(try posixPermissions(of: fileURL), 0o600)

            let reloaded = MacDeliveryPolicyStore(directory: directory)
            XCTAssertEqual(reloaded.configuredPolicy(for: "com.example.editor"), policy)
        }
    }

    func testFailedDeliveryPolicyRemovalLeavesPublishedSafetyRuleUntouched() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PolicyStore", isDirectory: true)
            let store = MacDeliveryPolicyStore(directory: directory)
            let policy = MacDeliveryPolicy(
                bundleIdentifier: "com.example.chat",
                deliveryMethod: .automatic,
                autoSend: true,
                contextKeyterms: true
            )
            XCTAssertTrue(store.upsert(policy))

            // Replace the injected scratch directory with a regular file so the
            // prospective document cannot be written. The live table must stay
            // exactly as it was instead of claiming the removal succeeded.
            try FileManager.default.removeItem(at: directory)
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))

            XCTAssertFalse(store.removePolicy(for: policy.bundleIdentifier))
            XCTAssertEqual(store.configuredPolicy(for: policy.bundleIdentifier), policy)
            XCTAssertNotNil(store.lastPersistenceError)
        }
    }

    func testUnknownDeliveryMethodBlocksTheWholeDocumentAndPreservesItsBytes() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PolicyStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixture = Data(
                #"{"schemaVersion":1,"policiesByBundleIdentifier":{"com.example.safe":{"bundleIdentifier":"com.example.safe","deliveryMethod":"automatic","autoSend":false,"contextKeyterms":false},"com.example.future":{"bundleIdentifier":"com.example.future","deliveryMethod":"teleport","autoSend":true,"contextKeyterms":true}}}"#.utf8
            )
            try fixture.write(to: directory.appendingPathComponent("delivery-policies.json"))

            let store = MacDeliveryPolicyStore(directory: directory)
            XCTAssertNil(store.configuredPolicy(for: "com.example.safe"))
            XCTAssertNil(store.configuredPolicy(for: "com.example.future"))
            XCTAssertTrue(store.policies.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("blocked") == true)
            XCTAssertFalse(store.removeAll())
            XCTAssertEqual(
                try Data(contentsOf: directory.appendingPathComponent("delivery-policies.json")),
                fixture
            )
        }
    }

    func testFutureDeliveryPolicySchemaLoadsNoRiskyRules() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PolicyStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixture = Data(
                #"{"schemaVersion":99,"policiesByBundleIdentifier":{"com.example.chat":{"bundleIdentifier":"com.example.chat","deliveryMethod":"automatic","autoSend":true,"contextKeyterms":true}}}"#.utf8
            )
            try fixture.write(to: directory.appendingPathComponent("delivery-policies.json"))

            let store = MacDeliveryPolicyStore(directory: directory)
            XCTAssertTrue(store.policies.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("newer schema") == true)
            XCTAssertFalse(store.removeAll())
            XCTAssertEqual(
                try Data(contentsOf: directory.appendingPathComponent("delivery-policies.json")),
                fixture
            )
        }
    }

    func testLegacyDeliveryPolicyMapStillDecodesWithSafeMissingFieldDefaults() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PolicyStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixture = Data(
                #"{"com.example.legacy":{"bundleIdentifier":"com.example.legacy","applicationName":"Legacy"}}"#.utf8
            )
            try fixture.write(to: directory.appendingPathComponent("delivery-policies.json"))

            let store = MacDeliveryPolicyStore(directory: directory)
            let policy = try XCTUnwrap(store.configuredPolicy(for: "com.example.legacy"))
            XCTAssertEqual(policy.deliveryMethod, .automatic)
            XCTAssertFalse(policy.typeOutFallback)
            XCTAssertFalse(policy.autoSend)
            XCTAssertFalse(policy.contextKeyterms)
        }
    }

    func testPendingAppendPublishesOnlyAfterPrivateAtomicWrite() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            let store = MacPendingTranscriptStore(directory: directory)

            let transcript = try store.append(
                text: "Recovered speech",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: "com.example.editor"
            )
            XCTAssertEqual(store.transcripts, [transcript])
            XCTAssertNil(store.lastPersistenceError)

            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            XCTAssertEqual(try posixPermissions(of: directory), 0o700)
            XCTAssertEqual(try posixPermissions(of: fileURL), 0o600)

            let reloaded = MacPendingTranscriptStore(directory: directory)
            XCTAssertEqual(reloaded.transcripts, [transcript])
        }
    }

    func testFailedPendingRemovalLeavesPublishedTranscriptUntouched() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            let store = MacPendingTranscriptStore(directory: directory)
            let transcript = try store.append(
                text: "Do not lose this",
                destinationApplicationName: "Editor",
                destinationBundleIdentifier: nil
            )

            try FileManager.default.removeItem(at: directory)
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))

            XCTAssertThrowsError(try store.remove(transcript.id))
            XCTAssertEqual(store.transcripts, [transcript])
            XCTAssertNotNil(store.lastPersistenceError)
        }
    }

    func testLegacyPendingTranscriptAliasesStillDecode() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID()
            let fixture = Data(
                "[{\"id\":\"\(id.uuidString)\",\"text\":\"Legacy speech\",\"destinationAppName\":\"Legacy Editor\",\"destinationBundleID\":\"com.example.legacy\",\"createdAt\":0}]".utf8
            )
            try fixture.write(to: directory.appendingPathComponent("pending-transcripts.json"))

            let store = MacPendingTranscriptStore(directory: directory)
            let transcript = try XCTUnwrap(store.transcript(withID: id))
            XCTAssertEqual(transcript.text, "Legacy speech")
            XCTAssertEqual(transcript.destinationApplicationName, "Legacy Editor")
            XCTAssertEqual(transcript.destinationBundleIdentifier, "com.example.legacy")
        }
    }

    func testFuturePendingTranscriptSchemaStaysUntouchedAndLoadsEmpty() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let directory = scratch.appendingPathComponent("PendingStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixture = Data(#"{"schemaVersion":99,"transcripts":[]}"#.utf8)
            let fileURL = directory.appendingPathComponent("pending-transcripts.json")
            try fixture.write(to: fileURL)

            let store = MacPendingTranscriptStore(directory: directory)
            XCTAssertTrue(store.transcripts.isEmpty)
            XCTAssertNotNil(store.lastPersistenceError)
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testHistoryMutationsPublishOnlyAfterPrivateAtomicWriteAndReload() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            let store = MacHistoryStore(defaults: defaults, directory: directory)
            let older = MacTranscriptRecord(
                createdAt: Date().addingTimeInterval(-60),
                text: "Older transcript",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 2.5
            )
            let newer = MacTranscriptRecord(
                text: "Newer transcript",
                destination: nil,
                deviceName: "Microphone",
                recordingDuration: 1.25
            )

            XCTAssertTrue(store.append(older))
            XCTAssertTrue(store.append(newer))
            XCTAssertEqual(store.records.map(\.id), [newer.id, older.id])
            XCTAssertTrue(store.updateText(older.id, to: "Corrected older transcript"))
            XCTAssertEqual(store.records.last?.text, "Corrected older transcript")
            XCTAssertNil(store.lastPersistenceError)

            let fileURL = directory.appendingPathComponent("history.json")
            XCTAssertEqual(try posixPermissions(of: directory), 0o700)
            XCTAssertEqual(try posixPermissions(of: fileURL), 0o600)

            var reloaded = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertEqual(reloaded.records, store.records)
            XCTAssertTrue(reloaded.delete(newer.id))
            XCTAssertEqual(reloaded.records.map(\.id), [older.id])

            reloaded = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertEqual(reloaded.records.map(\.id), [older.id])
            XCTAssertEqual(reloaded.records.first?.text, "Corrected older transcript")
        }
    }

    func testHistoryAudioReferenceMigrationIsExactAndPreservesTheTranscript() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            let store = MacHistoryStore(defaults: defaults, directory: directory)
            let id = UUID()
            let sourcePendingAudioID = UUID()
            let oldFileName = "\(id.uuidString.lowercased()).wav"
            let replacementFileName = "\(id.uuidString.lowercased()).m4a"
            let record = MacTranscriptRecord(
                id: id,
                createdAt: Date(timeIntervalSinceReferenceDate: 123),
                text: "Preserve this exact transcript",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 42,
                retainedAudioFileName: oldFileName,
                sourcePendingAudioID: sourcePendingAudioID
            )

            XCTAssertTrue(store.append(record))
            XCTAssertTrue(
                store.replaceRetainedAudioReference(
                    for: id,
                    expectedFileName: oldFileName,
                    with: replacementFileName
                )
            )
            let migrated = try XCTUnwrap(store.records.first)
            XCTAssertEqual(migrated.id, record.id)
            XCTAssertEqual(migrated.createdAt, record.createdAt)
            XCTAssertEqual(migrated.text, record.text)
            XCTAssertEqual(migrated.destination, record.destination)
            XCTAssertEqual(migrated.deviceName, record.deviceName)
            XCTAssertEqual(migrated.recordingDuration, record.recordingDuration)
            XCTAssertEqual(migrated.sourcePendingAudioID, sourcePendingAudioID)
            XCTAssertEqual(migrated.retainedAudioFileName, replacementFileName)

            XCTAssertFalse(
                store.replaceRetainedAudioReference(
                    for: id,
                    expectedFileName: oldFileName,
                    with: replacementFileName
                )
            )
            XCTAssertEqual(store.records.first, migrated)
            let reloaded = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertEqual(reloaded.records.first, migrated)
        }
    }

    func testHistoryPurgePersistsAnEmptyPrivateDocument() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            let store = MacHistoryStore(defaults: defaults, directory: directory)
            let record = MacTranscriptRecord(
                text: "Private transcript",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 3
            )

            XCTAssertTrue(store.append(record))
            XCTAssertTrue(store.deleteAll())
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertNil(store.lastPersistenceError)

            let fileURL = directory.appendingPathComponent("history.json")
            XCTAssertEqual(try posixPermissions(of: directory), 0o700)
            XCTAssertEqual(try posixPermissions(of: fileURL), 0o600)
            XCTAssertEqual(try JSONDecoder().decode([MacTranscriptRecord].self, from: Data(contentsOf: fileURL)), [])
            XCTAssertTrue(MacHistoryStore(defaults: defaults, directory: directory).records.isEmpty)
        }
    }

    func testFailedHistoryWritesPreserveEveryPublishedRecord() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            let store = MacHistoryStore(defaults: defaults, directory: directory)
            let durable = MacTranscriptRecord(
                text: "Do not hide this transcript",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 4
            )
            XCTAssertTrue(store.append(durable))
            let published = store.records

            // Occupying the storage-directory path with a regular file makes
            // every prospective write fail without relying on chmod behavior.
            try FileManager.default.removeItem(at: directory)
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))

            let newRecord = MacTranscriptRecord(
                text: "Never claim this was saved",
                destination: nil,
                deviceName: "Microphone",
                recordingDuration: 1
            )
            XCTAssertFalse(store.append(newRecord))
            XCTAssertEqual(store.records, published)
            XCTAssertFalse(store.updateText(durable.id, to: "Never claim this edit was saved"))
            XCTAssertEqual(store.records, published)
            XCTAssertFalse(store.delete(durable.id))
            XCTAssertEqual(store.records, published)
            XCTAssertFalse(store.deleteAll())
            XCTAssertEqual(store.records, published)
            XCTAssertNotNil(store.lastPersistenceError)
        }
    }

    func testMalformedHistoryRemainsByteForByteUntouchedAndBlocksOverwrite() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            let fixture = Data(#"[{"unfinished":true}"#.utf8)
            try fixture.write(to: fileURL)

            let store = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("unreadable") == true)
            XCTAssertFalse(store.isPendingAudioRecoveryAuthorityTrusted)
            XCTAssertFalse(store.establishDurableDocumentForExplicitPrivacyAction())

            let newRecord = MacTranscriptRecord(
                text: "Must not replace corrupt history",
                destination: nil,
                deviceName: "Microphone",
                recordingDuration: 1
            )
            XCTAssertFalse(store.append(newRecord))
            XCTAssertFalse(store.delete(UUID()))
            XCTAssertFalse(store.deleteAll())
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testUnreadableHistoryIsNotChmoddedOrOverwrittenDuringLaunch() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            let fixture = Data(#"[{"private":"unknown-format"}]"#.utf8)
            try fixture.write(to: fileURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: fileURL.path
            )

            let store = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("could not be read") == true)
            XCTAssertEqual(try posixPermissions(of: fileURL), 0o000)

            let record = MacTranscriptRecord(
                text: "Must not take ownership of unreadable bytes",
                destination: nil,
                deviceName: "Microphone",
                recordingDuration: 1
            )
            XCTAssertFalse(store.append(record))
            XCTAssertFalse(store.deleteAll())
            XCTAssertEqual(try posixPermissions(of: fileURL), 0o000)

            // Restore read permission only for the test assertion. SpeakPaste
            // itself deliberately left both contents and metadata untouched.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testFutureHistoryDocumentRemainsByteForByteUntouchedAndBlocksOverwrite() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            let fixture = Data(
                #"{"schemaVersion":99,"records":[{"future":"meaning"}]}"#.utf8
            )
            try fixture.write(to: fileURL)

            let store = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertTrue(store.lastPersistenceError?.contains("schema 99") == true)
            XCTAssertFalse(store.isPendingAudioRecoveryAuthorityTrusted)

            let newRecord = MacTranscriptRecord(
                text: "An older build cannot own this document",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 2
            )
            XCTAssertFalse(store.append(newRecord))
            XCTAssertFalse(store.delete(UUID()))
            XCTAssertFalse(store.deleteAll())
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testFutureFieldsInLegacyArrayRemainReadableWithoutBeingStripped() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            let record = MacTranscriptRecord(
                text: "Known fields remain readable",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 2
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                    as? [String: Any]
            )
            object["futureMetadata"] = ["speakerCount": 2]
            let fixture = try JSONSerialization.data(withJSONObject: [object], options: [.sortedKeys])
            try fixture.write(to: fileURL)

            let store = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertEqual(store.records, [record])
            XCTAssertTrue(store.lastPersistenceError?.contains("unsupported record fields") == true)
            XCTAssertFalse(store.append(record))
            XCTAssertFalse(store.delete(record.id))
            XCTAssertFalse(store.deleteAll())
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testDamagedHistoryArrayRecoversValidRecordsWithoutGrantingWriteAccess() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("history.json")
            let validRecord = MacTranscriptRecord(
                text: "This readable record must remain recoverable",
                destination: "Editor",
                deviceName: "Microphone",
                recordingDuration: 3
            )
            let encodedRecord = try JSONEncoder().encode(validRecord)
            var fixture = Data("[".utf8)
            fixture.append(encodedRecord)
            fixture.append(Data(#",{"id":"not-a-uuid","text":false}]"#.utf8))
            try fixture.write(to: fileURL)

            let store = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertEqual(store.records, [validRecord])
            XCTAssertTrue(store.lastPersistenceError?.contains("Recovered") == true)
            XCTAssertTrue(store.lastPersistenceError?.contains("1 damaged entry") == true)

            let newRecord = MacTranscriptRecord(
                text: "Do not flatten the damaged source",
                destination: nil,
                deviceName: "Microphone",
                recordingDuration: 1
            )
            XCTAssertFalse(store.append(newRecord))
            XCTAssertEqual(store.records, [validRecord])
            XCTAssertFalse(store.updateText(validRecord.id, to: "Do not rewrite"))
            XCTAssertFalse(store.delete(validRecord.id))
            XCTAssertFalse(store.deleteAll())
            XCTAssertEqual(store.records, [validRecord])
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testMissingHistoryFileStillInitializesAndPersistsNormally() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            let fileURL = directory.appendingPathComponent("history.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

            let store = MacHistoryStore(defaults: defaults, directory: directory)
            let record = MacTranscriptRecord(
                text: "First history record",
                destination: nil,
                deviceName: "Microphone",
                recordingDuration: 1
            )
            XCTAssertNil(store.lastPersistenceError)
            XCTAssertFalse(store.isPendingAudioRecoveryAuthorityTrusted)
            XCTAssertTrue(store.append(record))
            XCTAssertTrue(store.isPendingAudioRecoveryAuthorityTrusted)
            XCTAssertEqual(store.records, [record])
            XCTAssertEqual(
                try JSONDecoder().decode(
                    [MacTranscriptRecord].self,
                    from: Data(contentsOf: fileURL)
                ),
                [record]
            )
        }
    }

    func testExplicitPrivacyActionEstablishesTrustedEmptyHistoryOnFreshInstall() async throws {
        try await MainActor.run {
            let scratch = try makePersistenceScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (suiteName, defaults) = makePersistenceDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = scratch.appendingPathComponent("HistoryStore", isDirectory: true)
            let fileURL = directory.appendingPathComponent("history.json")

            let store = MacHistoryStore(defaults: defaults, directory: directory)
            XCTAssertFalse(store.isPendingAudioRecoveryAuthorityTrusted)
            XCTAssertTrue(store.establishDurableDocumentForExplicitPrivacyAction())
            XCTAssertTrue(store.isPendingAudioRecoveryAuthorityTrusted)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    [MacTranscriptRecord].self,
                    from: Data(contentsOf: fileURL)
                ),
                []
            )
            XCTAssertNil(store.lastPersistenceError)
        }
    }

    func testHistoryAudioStoreCopiesPrivatelyAndReconcilesOnlyManagedOrphans() throws {
        let scratch = try makePersistenceScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("HistoryAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("source.wav")
        let payload = Data("private successful recording".utf8)
        try payload.write(to: source)
        let store = MacHistoryAudioStore(
            directoryURL: directory,
            availableCapacityProvider: { _ in Int64.max },
            audioEncoder: historyAudioPassthroughEncoder
        )
        let keptID = UUID()
        let removedID = UUID()

        let keptName = try store.retain(sourceURL: source, historyRecordID: keptID)
        XCTAssertEqual(try Data(contentsOf: source), payload, "retention must copy, not consume recovery audio")
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: keptName)), payload)
        XCTAssertEqual(try posixPermissions(of: directory), 0o700)
        XCTAssertEqual(try posixPermissions(of: store.audioURL(for: keptName)), 0o600)

        let removedName = try store.retain(sourceURL: source, historyRecordID: removedID)
        let unknown = directory.appendingPathComponent("user-note.wav")
        try Data("not owned by this schema".utf8).write(to: unknown)
        // A copy awaiting its History commit is protected from an unrelated
        // History reconciliation. Once published, normal orphan cleanup owns it.
        XCTAssertTrue(store.reconcile(referencedFileNames: []))
        XCTAssertNoThrow(try store.audioURL(for: keptName))
        XCTAssertNoThrow(try store.audioURL(for: removedName))
        XCTAssertTrue(store.publish(keptName))
        XCTAssertTrue(store.publish(removedName))
        XCTAssertTrue(store.reconcile(referencedFileNames: [keptName]))
        XCTAssertNoThrow(try store.audioURL(for: keptName))
        XCTAssertThrowsError(try store.audioURL(for: removedName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }

    func testHistoryAudioStoreEncodesNewRetainedCopyAsCompactPlayableM4A() throws {
        let scratch = try makePersistenceScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("HistoryAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("source.wav")
        try makePCM16MonoWAV(seconds: 2).write(to: source)
        let sourceBytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        ).int64Value
        let store = MacHistoryAudioStore(
            directoryURL: directory,
            availableCapacityProvider: { _ in Int64.max }
        )

        let fileName = try store.retain(sourceURL: source, historyRecordID: UUID())
        let retainedURL = try store.audioURL(for: fileName)
        let retainedBytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: retainedURL.path)[.size] as? NSNumber
        ).int64Value
        let playableFile = try AVAudioFile(forReading: retainedURL)

        XCTAssertEqual(retainedURL.pathExtension, "m4a")
        XCTAssertGreaterThan(playableFile.length, 0)
        XCTAssertLessThan(retainedBytes * 10, sourceBytes)
        XCTAssertEqual(
            Double(playableFile.length) / playableFile.processingFormat.sampleRate,
            2,
            accuracy: 0.05
        )
        XCTAssertTrue(store.publish(fileName))
    }

    func testHistoryAudioReplacementSubtractsOnlyTheSameHistoryRecordAndKeepsOldFile() throws {
        let scratch = try makePersistenceScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("HistoryAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("source.wav")
        let payload = Data(repeating: 0x48, count: 32)
        try payload.write(to: source)
        let recordID = UUID()
        let oldName = "\(recordID.uuidString.lowercased()).wav"
        let oldURL = directory.appendingPathComponent(oldName)
        let store = MacHistoryAudioStore(
            directoryURL: directory,
            maximumRetainedHistoryAudioBytes: Int64(payload.count),
            minimumFreeSpaceAfterRetentionBytes: 0,
            availableCapacityProvider: { _ in Int64.max },
            audioEncoder: historyAudioPassthroughEncoder
        )
        try MacPrivateStoreIO.copyRegularFile(from: source, to: oldURL)

        let newName = try store.retain(
            sourceURL: oldURL,
            historyRecordID: recordID,
            replacingRetainedFileName: oldName
        )

        XCTAssertEqual(newName, "\(recordID.uuidString.lowercased()).m4a")
        XCTAssertEqual(try Data(contentsOf: oldURL), payload)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: newName)), payload)

        XCTAssertThrowsError(
            try store.retain(
                sourceURL: oldURL,
                historyRecordID: UUID(),
                replacingRetainedFileName: oldName
            )
        ) { error in
            guard
                let audioError = error as? MacHistoryAudioStoreError,
                case .unsafeFileName = audioError
            else {
                return XCTFail("Expected a mismatched replacement-name error, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: oldURL), payload)
    }

    func testHistoryAudioStoreRefusesCopyBeforeExceedingManagedByteQuota() throws {
        let scratch = try makePersistenceScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("HistoryAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("source.wav")
        let payload = Data(repeating: 0x41, count: 32)
        try payload.write(to: source)
        let store = MacHistoryAudioStore(
            directoryURL: directory,
            maximumRetainedHistoryAudioBytes: Int64(payload.count),
            minimumFreeSpaceAfterRetentionBytes: 0,
            availableCapacityProvider: { _ in Int64.max },
            audioEncoder: historyAudioPassthroughEncoder
        )

        let firstName = try store.retain(sourceURL: source, historyRecordID: UUID())
        let rejectedID = UUID()
        XCTAssertThrowsError(
            try store.retain(sourceURL: source, historyRecordID: rejectedID)
        ) { error in
            guard
                let audioError = error as? MacHistoryAudioStoreError,
                case .retainedAudioQuotaExceeded = audioError
            else {
                return XCTFail("Expected the retained-audio quota error, got \(error)")
            }
        }

        let rejectedURL = directory.appendingPathComponent(
            "\(rejectedID.uuidString.lowercased()).m4a"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedURL.path))
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertTrue(store.lastPersistenceError?.contains("retained History-audio limit") == true)

        XCTAssertTrue(store.remove(firstName))
        _ = try store.retain(sourceURL: source, historyRecordID: rejectedID)
        XCTAssertNil(store.lastPersistenceError)
    }

    func testHistoryAudioQuotaIgnoresUnknownFilesAndManagedLookingSymlinks() throws {
        let scratch = try makePersistenceScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("HistoryAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("source.wav")
        let payload = Data(repeating: 0x42, count: 24)
        try payload.write(to: source)
        let store = MacHistoryAudioStore(
            directoryURL: directory,
            maximumRetainedHistoryAudioBytes: Int64(payload.count),
            minimumFreeSpaceAfterRetentionBytes: 0,
            availableCapacityProvider: { _ in Int64.max },
            audioEncoder: historyAudioPassthroughEncoder
        )

        let unknown = directory.appendingPathComponent("user-owned.wav")
        try Data(repeating: 0x43, count: payload.count * 20).write(to: unknown)
        let externalTarget = scratch.appendingPathComponent("external.wav")
        try Data(repeating: 0x44, count: payload.count * 20).write(to: externalTarget)
        let managedLookingSymlink = directory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).wav"
        )
        try FileManager.default.createSymbolicLink(
            at: managedLookingSymlink,
            withDestinationURL: externalTarget
        )

        let retainedName = try store.retain(sourceURL: source, historyRecordID: UUID())
        XCTAssertTrue(store.reconcile(referencedFileNames: [retainedName]))
        XCTAssertEqual(try Data(contentsOf: unknown).count, payload.count * 20)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: managedLookingSymlink.path),
            externalTarget.path
        )
    }

    func testHistoryAudioStoreRefusesCopyThatWouldSpendFreeSpaceReserve() throws {
        let scratch = try makePersistenceScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("HistoryAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("source.wav")
        let payload = Data(repeating: 0x45, count: 32)
        try payload.write(to: source)
        let requiredReserve: Int64 = 16
        let reportedCapacity: Int64 = 40
        let store = MacHistoryAudioStore(
            directoryURL: directory,
            maximumRetainedHistoryAudioBytes: 1_024,
            minimumFreeSpaceAfterRetentionBytes: requiredReserve,
            availableCapacityProvider: { _ in reportedCapacity },
            audioEncoder: historyAudioPassthroughEncoder
        )
        let rejectedID = UUID()

        XCTAssertThrowsError(
            try store.retain(sourceURL: source, historyRecordID: rejectedID)
        ) { error in
            guard
                let audioError = error as? MacHistoryAudioStoreError,
                case .insufficientFreeSpace = audioError
            else {
                return XCTFail("Expected the free-space reserve error, got \(error)")
            }
        }

        let rejectedURL = directory.appendingPathComponent(
            "\(rejectedID.uuidString.lowercased()).m4a"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedURL.path))
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertTrue(store.lastPersistenceError?.contains("free disk space") == true)
    }

    func testHistoryAudioStoreDoesNotFollowSymlinkRecordingSource() throws {
        let scratch = try makePersistenceScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("HistoryAudio", isDirectory: true)
        let target = scratch.appendingPathComponent("real-recording.wav")
        try Data(repeating: 0x46, count: 16).write(to: target)
        let sourceSymlink = scratch.appendingPathComponent("source.wav")
        try FileManager.default.createSymbolicLink(at: sourceSymlink, withDestinationURL: target)
        let store = MacHistoryAudioStore(
            directoryURL: directory,
            maximumRetainedHistoryAudioBytes: 1_024,
            minimumFreeSpaceAfterRetentionBytes: 0,
            availableCapacityProvider: { _ in Int64.max },
            audioEncoder: historyAudioPassthroughEncoder
        )
        let rejectedID = UUID()

        XCTAssertThrowsError(
            try store.retain(sourceURL: sourceSymlink, historyRecordID: rejectedID)
        ) { error in
            guard
                let audioError = error as? MacHistoryAudioStoreError,
                case .unsafeAudioSource = audioError
            else {
                return XCTFail("Expected the unsafe-source error, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    "\(rejectedID.uuidString.lowercased()).m4a"
                ).path
            )
        )
        XCTAssertTrue(store.lastPersistenceError?.contains("measured safely") == true)
    }

    func testConcurrentHistoryAudioRetentionCannotRacePastQuota() async throws {
        let scratch = try makePersistenceScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("HistoryAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("source.wav")
        let payload = Data(repeating: 0x47, count: 64)
        try payload.write(to: source)
        let store = MacHistoryAudioStore(
            directoryURL: directory,
            maximumRetainedHistoryAudioBytes: Int64(payload.count),
            minimumFreeSpaceAfterRetentionBytes: 0,
            availableCapacityProvider: { _ in Int64.max },
            audioEncoder: historyAudioPassthroughEncoder
        )
        let recordIDs = [UUID(), UUID()]

        let successfulRetentions = await withTaskGroup(of: Bool.self) { group in
            for recordID in recordIDs {
                group.addTask {
                    do {
                        _ = try store.retain(
                            sourceURL: source,
                            historyRecordID: recordID
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var successes = 0
            for await succeeded in group where succeeded {
                successes += 1
            }
            return successes
        }

        XCTAssertEqual(successfulRetentions, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).count,
            1
        )
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertTrue(store.lastPersistenceError?.contains("retained History-audio limit") == true)
    }
}

private func makePersistenceScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakPaste-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let historyAudioPassthroughEncoder: MacHistoryAudioStore.AudioEncoder = {
    sourceURL,
    destinationURL in
    try MacPrivateStoreIO.copyRegularFile(from: sourceURL, to: destinationURL)
}

private func makePCM16MonoWAV(seconds: Int, sampleRate: Int = 48_000) -> Data {
    let sampleCount = seconds * sampleRate
    let dataByteCount = sampleCount * MemoryLayout<Int16>.size
    var data = Data()

    func appendASCII(_ value: String) {
        data.append(contentsOf: value.utf8)
    }
    func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    appendASCII("RIFF")
    appendLE(UInt32(36 + dataByteCount))
    appendASCII("WAVEfmt ")
    appendLE(UInt32(16))
    appendLE(UInt16(1))
    appendLE(UInt16(1))
    appendLE(UInt32(sampleRate))
    appendLE(UInt32(sampleRate * MemoryLayout<Int16>.size))
    appendLE(UInt16(MemoryLayout<Int16>.size))
    appendLE(UInt16(16))
    appendASCII("data")
    appendLE(UInt32(dataByteCount))
    data.append(Data(count: dataByteCount))
    return data
}

private func posixPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private func makePersistenceDefaults() -> (name: String, defaults: UserDefaults) {
    let name = "SpeakPaste-store-tests-\(UUID().uuidString)"
    return (name, UserDefaults(suiteName: name)!)
}
