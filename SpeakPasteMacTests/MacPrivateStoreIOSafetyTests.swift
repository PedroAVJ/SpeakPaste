import Darwin
import Foundation
import XCTest
@testable import SpeakPaste

final class MacPrivateStoreIOSafetyTests: XCTestCase {
    func testPrimitiveRejectsSymlinkedParentWithoutTouchingTarget() throws {
        let scratch = try makePrivateStoreScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let externalDirectory = scratch.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let externalFile = externalDirectory.appendingPathComponent("history.json")
        let original = Data("external private data".utf8)
        try original.write(to: externalFile)
        try setPrivateStorePermissions(0o755, on: externalDirectory)
        try setPrivateStorePermissions(0o644, on: externalFile)

        let linkedDirectory = scratch.appendingPathComponent("SpeakPaste", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: externalDirectory
        )
        let linkedFile = linkedDirectory.appendingPathComponent("history.json")

        XCTAssertThrowsError(try MacPrivateStoreIO.validateExistingStorage(at: linkedFile))
        XCTAssertThrowsError(try MacPrivateStoreIO.secureExistingStorage(at: linkedFile))
        XCTAssertThrowsError(try MacPrivateStoreIO.readExistingData(at: linkedFile))
        XCTAssertThrowsError(try MacPrivateStoreIO.writeAtomically(Data("replacement".utf8), to: linkedFile))

        XCTAssertEqual(try Data(contentsOf: externalFile), original)
        XCTAssertEqual(try privateStorePermissions(of: externalDirectory), 0o755)
        XCTAssertEqual(try privateStorePermissions(of: externalFile), 0o644)
        XCTAssertTrue(isPrivateStoreSymbolicLink(linkedDirectory))
    }

    func testPrimitiveRejectsSymlinkedFinalFileWithoutTouchingTarget() throws {
        let scratch = try makePrivateStoreScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ownedDirectory = scratch.appendingPathComponent("SpeakPaste", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: true)
        let externalFile = scratch.appendingPathComponent("external-history.json")
        let original = Data("outside the owned directory".utf8)
        try original.write(to: externalFile)
        try setPrivateStorePermissions(0o644, on: externalFile)

        let linkedFile = ownedDirectory.appendingPathComponent("history.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: externalFile)

        XCTAssertThrowsError(try MacPrivateStoreIO.validateExistingStorage(at: linkedFile))
        XCTAssertThrowsError(try MacPrivateStoreIO.secureExistingStorage(at: linkedFile))
        XCTAssertThrowsError(try MacPrivateStoreIO.readExistingData(at: linkedFile))
        XCTAssertThrowsError(try MacPrivateStoreIO.writeAtomically(Data("replacement".utf8), to: linkedFile))

        XCTAssertEqual(try Data(contentsOf: externalFile), original)
        XCTAssertEqual(try privateStorePermissions(of: externalFile), 0o644)
        XCTAssertTrue(isPrivateStoreSymbolicLink(linkedFile))
    }

    func testAllAutomaticStoresRejectSymlinkedParentWithoutLoadingOrMutatingTargets() async throws {
        try await MainActor.run {
            let scratch = try makePrivateStoreScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let externalDirectory = scratch.appendingPathComponent("External", isDirectory: true)
            try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
            let fixtures = try makeAutomaticStoreFixtures(in: externalDirectory)
            try setPrivateStorePermissions(0o755, on: externalDirectory)
            for fixture in fixtures {
                try setPrivateStorePermissions(0o644, on: fixture.url)
            }

            let linkedDirectory = scratch.appendingPathComponent("SpeakPaste", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedDirectory,
                withDestinationURL: externalDirectory
            )
            let (suiteName, defaults) = makePrivateStoreDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let policyStore = MacDeliveryPolicyStore(directory: linkedDirectory)
            XCTAssertTrue(policyStore.policies.isEmpty)
            XCTAssertTrue(policyStore.lastPersistenceError?.contains("unsafe") == true)
            XCTAssertFalse(policyStore.upsert(riskyPolicy()))

            let historyStore = MacHistoryStore(defaults: defaults, directory: linkedDirectory)
            XCTAssertTrue(historyStore.records.isEmpty)
            XCTAssertTrue(historyStore.lastPersistenceError?.contains("unsafe") == true)
            XCTAssertFalse(historyStore.append(historyFixtureRecord()))

            let pendingStore = MacPendingTranscriptStore(directory: linkedDirectory)
            XCTAssertTrue(pendingStore.transcripts.isEmpty)
            XCTAssertTrue(pendingStore.lastPersistenceError?.contains("unsafe") == true)
            XCTAssertThrowsError(try pendingStore.upsert(pendingFixtureTranscript()))

            let healthMarker = MacSessionHealthMarker(applicationSupportDirectory: linkedDirectory)
            XCTAssertThrowsError(try healthMarker.beginSession())

            try assertAutomaticStoreFixturesUnchanged(fixtures)
            XCTAssertEqual(try privateStorePermissions(of: externalDirectory), 0o755)
            XCTAssertTrue(isPrivateStoreSymbolicLink(linkedDirectory))
        }
    }

    func testAllAutomaticStoresRejectSymlinkedFinalFilesWithoutLoadingOrMutatingTargets() async throws {
        try await MainActor.run {
            let scratch = try makePrivateStoreScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let ownedDirectory = scratch.appendingPathComponent("SpeakPaste", isDirectory: true)
            let externalDirectory = scratch.appendingPathComponent("External", isDirectory: true)
            try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
            let fixtures = try makeAutomaticStoreFixtures(in: externalDirectory)
            for fixture in fixtures {
                try setPrivateStorePermissions(0o644, on: fixture.url)
                try FileManager.default.createSymbolicLink(
                    at: ownedDirectory.appendingPathComponent(fixture.url.lastPathComponent),
                    withDestinationURL: fixture.url
                )
            }
            let (suiteName, defaults) = makePrivateStoreDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let policyStore = MacDeliveryPolicyStore(directory: ownedDirectory)
            XCTAssertTrue(policyStore.policies.isEmpty)
            XCTAssertTrue(policyStore.lastPersistenceError?.contains("unsafe") == true)
            XCTAssertFalse(policyStore.upsert(riskyPolicy()))

            let historyStore = MacHistoryStore(defaults: defaults, directory: ownedDirectory)
            XCTAssertTrue(historyStore.records.isEmpty)
            XCTAssertTrue(historyStore.lastPersistenceError?.contains("unsafe") == true)
            XCTAssertFalse(historyStore.append(historyFixtureRecord()))

            let pendingStore = MacPendingTranscriptStore(directory: ownedDirectory)
            XCTAssertTrue(pendingStore.transcripts.isEmpty)
            XCTAssertTrue(pendingStore.lastPersistenceError?.contains("unsafe") == true)
            XCTAssertThrowsError(try pendingStore.upsert(pendingFixtureTranscript()))

            let healthMarker = MacSessionHealthMarker(applicationSupportDirectory: ownedDirectory)
            XCTAssertThrowsError(try healthMarker.beginSession())

            try assertAutomaticStoreFixturesUnchanged(fixtures)
            for fixture in fixtures {
                XCTAssertTrue(
                    isPrivateStoreSymbolicLink(
                        ownedDirectory.appendingPathComponent(fixture.url.lastPathComponent)
                    )
                )
            }
        }
    }
}

private struct AutomaticStoreFixture {
    let url: URL
    let data: Data
}

private func makeAutomaticStoreFixtures(in directory: URL) throws -> [AutomaticStoreFixture] {
    let historyData = try JSONEncoder().encode([historyFixtureRecord()])
    let pendingData = try JSONEncoder().encode([pendingFixtureTranscript()])
    let policyData = Data(
        #"{"schemaVersion":1,"policiesByBundleIdentifier":{"com.example.chat":{"bundleIdentifier":"com.example.chat","deliveryMethod":"automatic","autoSend":true,"contextKeyterms":true}}}"#.utf8
    )
    let healthData = Data(
        #"{"schemaVersion":1,"startedAt":"2026-08-03T12:00:00Z","lastHeartbeatAt":"2026-08-03T12:00:00Z"}"#.utf8
    )
    let values: [(String, Data)] = [
        ("delivery-policies.json", policyData),
        ("history.json", historyData),
        ("pending-transcripts.json", pendingData),
        ("session-health.json", healthData),
    ]
    return try values.map { name, data in
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return AutomaticStoreFixture(url: url, data: data)
    }
}

private func assertAutomaticStoreFixturesUnchanged(
    _ fixtures: [AutomaticStoreFixture],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    for fixture in fixtures {
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.data, file: file, line: line)
        XCTAssertEqual(try privateStorePermissions(of: fixture.url), 0o644, file: file, line: line)
    }
}

private func riskyPolicy() -> MacDeliveryPolicy {
    MacDeliveryPolicy(
        bundleIdentifier: "com.example.chat",
        applicationName: "Chat",
        deliveryMethod: .automatic,
        autoSend: true,
        contextKeyterms: true
    )
}

private func historyFixtureRecord() -> MacTranscriptRecord {
    MacTranscriptRecord(
        id: UUID(uuidString: "6A466933-2131-46FA-B63F-05C5944EFCC4")!,
        createdAt: Date(timeIntervalSinceReferenceDate: 100),
        text: "External history must not load",
        destination: "Chat",
        deviceName: "Microphone",
        recordingDuration: 1
    )
}

private func pendingFixtureTranscript() -> MacPendingTranscript {
    MacPendingTranscript(
        id: UUID(uuidString: "A378F70C-C7E1-4D97-AC84-8A8A46C57175")!,
        text: "External queue must not load",
        destinationApplicationName: "Chat",
        destinationBundleIdentifier: "com.example.chat",
        createdAt: Date(timeIntervalSinceReferenceDate: 100)
    )
}

private func makePrivateStoreScratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakPaste-private-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makePrivateStoreDefaults() -> (String, UserDefaults) {
    let name = "SpeakPaste-private-store-tests-\(UUID().uuidString)"
    return (name, UserDefaults(suiteName: name)!)
}

private func setPrivateStorePermissions(_ permissions: Int, on url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: url.path
    )
}

private func privateStorePermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private func isPrivateStoreSymbolicLink(_ url: URL) -> Bool {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFLNK
}
