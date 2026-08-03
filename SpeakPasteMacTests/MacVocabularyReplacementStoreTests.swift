import Darwin
import Foundation
import XCTest
@testable import SpeakPaste

final class MacVocabularyReplacementStoreTests: XCTestCase {
    func testVocabularyPublishesOnlyDurableCRUDAndReloadsPrivateDocument() async throws {
        try await MainActor.run {
            let scratch = try makeDictionaryStoreScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }

            let store = MacVocabularyStore(directory: scratch)
            XCTAssertTrue(store.add("OpenAI"))
            XCTAssertEqual(store.importDelimited("ElevenLabs, Scribe\nOpenAI"), 2)
            XCTAssertEqual(store.terms, ["ElevenLabs", "OpenAI", "Scribe"])
            XCTAssertTrue(store.remove("scribe"))
            XCTAssertFalse(store.remove("missing"))
            XCTAssertNil(store.lastPersistenceError)

            let reloaded = MacVocabularyStore(directory: scratch)
            XCTAssertEqual(reloaded.terms, ["ElevenLabs", "OpenAI"])
            XCTAssertNil(reloaded.lastPersistenceError)
            XCTAssertEqual(try dictionaryStorePermissions(of: scratch), 0o700)
            XCTAssertEqual(
                try dictionaryStorePermissions(of: scratch.appendingPathComponent("vocabulary.json")),
                0o600
            )
        }
    }

    func testVocabularyRejectsEveryCharacterScribeForbidsBeforePersistence() async throws {
        try await MainActor.run {
            let scratch = try makeDictionaryStoreScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let store = MacVocabularyStore(directory: scratch)

            for term in ["angle<bracket", "brace{term", "array[term", "path\\term", "line\u{0007}bell"] {
                XCTAssertNotNil(MacVocabularyStore.validationFailure(for: term), term)
                XCTAssertFalse(store.add(term), term)
            }
            XCTAssertEqual(store.importDelimited("ValidTerm, invalid<term, AlsoValid"), 2)
            XCTAssertEqual(store.terms, ["AlsoValid", "ValidTerm"])
            XCTAssertEqual(store.keytermsForRequest, store.terms)
        }
    }

    func testVocabularyEnforcesScribesStrictlyFewerThanFiftyCharacterLimit() async throws {
        try await MainActor.run {
            let scratch = try makeDictionaryStoreScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let store = MacVocabularyStore(directory: scratch)
            let fortyNineCharacters = String(repeating: "a", count: 49)
            let fiftyCharacters = String(repeating: "b", count: 50)

            XCTAssertNil(MacVocabularyStore.validationFailure(for: fortyNineCharacters))
            XCTAssertTrue(store.add(fortyNineCharacters))
            XCTAssertNotNil(MacVocabularyStore.validationFailure(for: fiftyCharacters))
            XCTAssertFalse(store.add(fiftyCharacters))
            XCTAssertEqual(store.terms, [fortyNineCharacters])
        }
    }

    func testReplacementPublishesOnlyDurableCRUDAndReloadsPrivateDocument() async throws {
        try await MainActor.run {
            let scratch = try makeDictionaryStoreScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }

            let store = MacReplacementStore(directory: scratch)
            XCTAssertTrue(store.add(spoken: "open ai", written: "OpenAI"))
            var replacement = try XCTUnwrap(store.replacements.first)
            replacement.isEnabled = false
            replacement.matchesWholeWordsOnly = false
            XCTAssertTrue(store.update(replacement))
            XCTAssertEqual(store.replacements.first, replacement)

            let reloaded = MacReplacementStore(directory: scratch)
            XCTAssertEqual(reloaded.replacements, [replacement])
            XCTAssertNil(reloaded.lastPersistenceError)
            XCTAssertTrue(reloaded.remove(replacement.id))
            XCTAssertTrue(reloaded.replacements.isEmpty)
            XCTAssertFalse(reloaded.remove(replacement.id))
            XCTAssertTrue(MacReplacementStore(directory: scratch).replacements.isEmpty)
            XCTAssertEqual(try dictionaryStorePermissions(of: scratch), 0o700)
            XCTAssertEqual(
                try dictionaryStorePermissions(of: scratch.appendingPathComponent("replacements.json")),
                0o600
            )
        }
    }

    func testRealWriteFailureLeavesPublishedVocabularyAndReplacementsUnchanged() async throws {
        try await MainActor.run {
            let vocabularyDirectory = try makeDictionaryStoreScratch()
            let replacementDirectory = try makeDictionaryStoreScratch()
            defer {
                try? FileManager.default.removeItem(at: vocabularyDirectory)
                try? FileManager.default.removeItem(at: replacementDirectory)
            }

            let vocabulary = MacVocabularyStore(directory: vocabularyDirectory)
            let vocabularyPath = vocabularyDirectory.appendingPathComponent(
                "vocabulary.json",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: vocabularyPath, withIntermediateDirectories: false)
            XCTAssertFalse(vocabulary.add("Must not appear"))
            XCTAssertTrue(vocabulary.terms.isEmpty)
            XCTAssertNotNil(vocabulary.lastPersistenceError)
            XCTAssertTrue(dictionaryStoreIsDirectory(vocabularyPath))

            let replacements = MacReplacementStore(directory: replacementDirectory)
            let replacementPath = replacementDirectory.appendingPathComponent(
                "replacements.json",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: replacementPath, withIntermediateDirectories: false)
            XCTAssertFalse(replacements.add(spoken: "wrong", written: "right"))
            XCTAssertTrue(replacements.replacements.isEmpty)
            XCTAssertNotNil(replacements.lastPersistenceError)
            XCTAssertTrue(dictionaryStoreIsDirectory(replacementPath))
        }
    }

    func testMalformedFutureAndUnknownVocabularyDocumentsArePreservedAndBlockWrites() async throws {
        try await MainActor.run {
            let fixtures: [Data] = [
                Data("{not-json".utf8),
                Data(#"{"schemaVersion":99,"terms":["Future"]}"#.utf8),
                Data(#"{"schemaVersion":1,"terms":["Known"],"futureField":true}"#.utf8),
            ]

            for fixture in fixtures {
                let scratch = try makeDictionaryStoreScratch()
                defer { try? FileManager.default.removeItem(at: scratch) }
                let fileURL = scratch.appendingPathComponent("vocabulary.json")
                try fixture.write(to: fileURL)

                let store = MacVocabularyStore(directory: scratch)
                XCTAssertTrue(store.terms.isEmpty)
                XCTAssertNotNil(store.lastPersistenceError)
                XCTAssertFalse(store.add("Do not overwrite"))
                XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
            }
        }
    }

    func testMalformedFutureAndUnknownReplacementDocumentsArePreservedAndBlockWrites() async throws {
        try await MainActor.run {
            let replacement = #"{"id":"4B29D9E8-C934-45E8-B202-490627B9C38B","spoken":"heard","written":"written","isEnabled":true,"matchesWholeWordsOnly":true}"#
            let fixtures: [Data] = [
                Data("{not-json".utf8),
                Data("{\"schemaVersion\":99,\"replacements\":[\(replacement)]}".utf8),
                Data("{\"schemaVersion\":1,\"replacements\":[\(replacement.dropLast()),\"futureField\":true}]}".utf8),
            ]

            for fixture in fixtures {
                let scratch = try makeDictionaryStoreScratch()
                defer { try? FileManager.default.removeItem(at: scratch) }
                let fileURL = scratch.appendingPathComponent("replacements.json")
                try fixture.write(to: fileURL)

                let store = MacReplacementStore(directory: scratch)
                XCTAssertTrue(store.replacements.isEmpty)
                XCTAssertNotNil(store.lastPersistenceError)
                XCTAssertFalse(store.add(spoken: "do not", written: "overwrite"))
                XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
            }
        }
    }

    func testSymlinkedVocabularyAndReplacementFilesNeverLoadOrMutateTargets() async throws {
        try await MainActor.run {
            let scratch = try makeDictionaryStoreScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let external = scratch.appendingPathComponent("External", isDirectory: true)
            let owned = scratch.appendingPathComponent("Owned", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)

            let vocabularyTarget = external.appendingPathComponent("vocabulary.json")
            let replacementTarget = external.appendingPathComponent("replacements.json")
            let vocabularyBytes = Data(#"{"schemaVersion":1,"terms":["Private"]}"#.utf8)
            let replacementBytes = Data(#"{"schemaVersion":1,"replacements":[]}"#.utf8)
            try vocabularyBytes.write(to: vocabularyTarget)
            try replacementBytes.write(to: replacementTarget)
            try FileManager.default.createSymbolicLink(
                at: owned.appendingPathComponent("vocabulary.json"),
                withDestinationURL: vocabularyTarget
            )
            try FileManager.default.createSymbolicLink(
                at: owned.appendingPathComponent("replacements.json"),
                withDestinationURL: replacementTarget
            )

            let vocabulary = MacVocabularyStore(directory: owned)
            let replacements = MacReplacementStore(directory: owned)
            XCTAssertTrue(vocabulary.terms.isEmpty)
            XCTAssertTrue(replacements.replacements.isEmpty)
            XCTAssertNotNil(vocabulary.lastPersistenceError)
            XCTAssertNotNil(replacements.lastPersistenceError)
            XCTAssertFalse(vocabulary.add("Never follows"))
            XCTAssertFalse(replacements.add(spoken: "never", written: "follows"))
            XCTAssertEqual(try Data(contentsOf: vocabularyTarget), vocabularyBytes)
            XCTAssertEqual(try Data(contentsOf: replacementTarget), replacementBytes)
            XCTAssertTrue(dictionaryStoreIsSymbolicLink(owned.appendingPathComponent("vocabulary.json")))
            XCTAssertTrue(dictionaryStoreIsSymbolicLink(owned.appendingPathComponent("replacements.json")))
        }
    }

    func testLegacyArrayDocumentsLoadAndMigrateOnlyAfterSuccessfulMutation() async throws {
        try await MainActor.run {
            let vocabularyDirectory = try makeDictionaryStoreScratch()
            let replacementDirectory = try makeDictionaryStoreScratch()
            defer {
                try? FileManager.default.removeItem(at: vocabularyDirectory)
                try? FileManager.default.removeItem(at: replacementDirectory)
            }

            let vocabularyURL = vocabularyDirectory.appendingPathComponent("vocabulary.json")
            try Data(#"["Legacy"]"#.utf8).write(to: vocabularyURL)
            let vocabulary = MacVocabularyStore(directory: vocabularyDirectory)
            XCTAssertEqual(vocabulary.terms, ["Legacy"])
            XCTAssertTrue(vocabulary.add("Current"))

            let legacyReplacement = MacTextReplacement(
                spoken: "legacy",
                written: "Legacy",
                isEnabled: true,
                matchesWholeWordsOnly: true
            )
            let replacementURL = replacementDirectory.appendingPathComponent("replacements.json")
            try JSONEncoder().encode([legacyReplacement]).write(to: replacementURL)
            let replacements = MacReplacementStore(directory: replacementDirectory)
            XCTAssertEqual(replacements.replacements, [legacyReplacement])
            XCTAssertTrue(replacements.add(spoken: "current", written: "Current"))

            let vocabularyObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: vocabularyURL)) as? [String: Any]
            )
            let replacementObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: replacementURL)) as? [String: Any]
            )
            XCTAssertEqual(vocabularyObject["schemaVersion"] as? Int, 1)
            XCTAssertEqual(replacementObject["schemaVersion"] as? Int, 1)
        }
    }
}

private func makeDictionaryStoreScratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SpeakPaste-dictionary-store-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func dictionaryStorePermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private func dictionaryStoreIsDirectory(_ url: URL) -> Bool {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFDIR
}

private func dictionaryStoreIsSymbolicLink(_ url: URL) -> Bool {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFLNK
}
