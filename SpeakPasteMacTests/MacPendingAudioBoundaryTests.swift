import Darwin
import Foundation
import XCTest
@testable import SpeakPaste

final class MacPendingAudioBoundaryTests: XCTestCase {
    func testSymlinkedSpeakPasteParentDoesNotExposeOrMutateExternalJournal() throws {
        let scratch = try makePendingBoundaryScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let externalSpeakPaste = scratch.appendingPathComponent("ExternalSpeakPaste", isDirectory: true)
        let externalPendingAudio = externalSpeakPaste.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: externalPendingAudio, withIntermediateDirectories: true)
        let fixtures = try makePendingBoundaryFixtures(in: externalPendingAudio)
        try setPendingBoundaryPermissions(0o755, on: externalSpeakPaste)
        try setPendingBoundaryPermissions(0o755, on: externalPendingAudio)
        for fixture in fixtures { try setPendingBoundaryPermissions(0o644, on: fixture.url) }

        let linkedSpeakPaste = scratch.appendingPathComponent("SpeakPaste", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedSpeakPaste,
            withDestinationURL: externalSpeakPaste
        )
        let store = MacPendingAudioStore(
            directoryURL: linkedSpeakPaste.appendingPathComponent("PendingAudio", isDirectory: true)
        )

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastPersistenceError)
        let source = scratch.appendingPathComponent("new.wav")
        let sourceData = Data("new recording".utf8)
        try sourceData.write(to: source)
        XCTAssertThrowsError(
            try store.stage(
                sourceURL: source,
                deviceName: "Microphone",
                recordingDuration: 1
            )
        )
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        try assertPendingBoundaryFixturesUnchanged(fixtures)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalSpeakPaste), 0o755)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalPendingAudio), 0o755)
        XCTAssertTrue(isPendingBoundarySymbolicLink(linkedSpeakPaste))
    }

    func testSymlinkedPendingAudioDirectoryDoesNotExposeOrMutateExternalJournal() throws {
        let scratch = try makePendingBoundaryScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let speakPaste = scratch.appendingPathComponent("SpeakPaste", isDirectory: true)
        let externalPendingAudio = scratch.appendingPathComponent("ExternalPendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: speakPaste, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalPendingAudio, withIntermediateDirectories: true)
        let fixtures = try makePendingBoundaryFixtures(in: externalPendingAudio)
        try setPendingBoundaryPermissions(0o755, on: externalPendingAudio)
        for fixture in fixtures { try setPendingBoundaryPermissions(0o644, on: fixture.url) }

        let linkedPendingAudio = speakPaste.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedPendingAudio,
            withDestinationURL: externalPendingAudio
        )
        let store = MacPendingAudioStore(directoryURL: linkedPendingAudio)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastPersistenceError)
        try assertPendingBoundaryFixturesUnchanged(fixtures)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalPendingAudio), 0o755)
        XCTAssertTrue(isPendingBoundarySymbolicLink(linkedPendingAudio))
    }

    func testSymlinkedIndexAndAudioEntriesAreNeverReadReplacedOrUnlinked() throws {
        let scratch = try makePendingBoundaryScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch
            .appendingPathComponent("SpeakPaste", isDirectory: true)
            .appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID()
        let audioName = "\(id.uuidString).wav"
        let externalIndex = scratch.appendingPathComponent("external-index.json")
        let externalAudio = scratch.appendingPathComponent("external-audio.wav")
        let indexData = Data(
            #"{"version":2,"records":[],"tombstones":[],"completions":[]}"#.utf8
        )
        let audioData = Data("outside audio".utf8)
        try indexData.write(to: externalIndex)
        try audioData.write(to: externalAudio)
        try setPendingBoundaryPermissions(0o644, on: externalIndex)
        try setPendingBoundaryPermissions(0o644, on: externalAudio)
        let indexLink = directory.appendingPathComponent("pending-audio-index.json")
        let audioLink = directory.appendingPathComponent(audioName)
        try FileManager.default.createSymbolicLink(at: indexLink, withDestinationURL: externalIndex)
        try FileManager.default.createSymbolicLink(at: audioLink, withDestinationURL: externalAudio)

        let store = MacPendingAudioStore(directoryURL: directory)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastPersistenceError)

        let source = scratch.appendingPathComponent("source.wav")
        let sourceData = Data("do not move".utf8)
        try sourceData.write(to: source)
        XCTAssertThrowsError(
            try store.stage(
                sourceURL: source,
                id: id,
                deviceName: "Microphone",
                recordingDuration: 1
            )
        )

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertEqual(try Data(contentsOf: externalIndex), indexData)
        XCTAssertEqual(try Data(contentsOf: externalAudio), audioData)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalIndex), 0o644)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalAudio), 0o644)
        XCTAssertTrue(isPendingBoundarySymbolicLink(indexLink))
        XCTAssertTrue(isPendingBoundarySymbolicLink(audioLink))
    }

    func testTombstoneCleanupNeverUnlinksASymlinkedAudioTarget() throws {
        let scratch = try makePendingBoundaryScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch
            .appendingPathComponent("SpeakPaste", isDirectory: true)
            .appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioName = "\(UUID().uuidString).wav"
        let externalAudio = scratch.appendingPathComponent("external-tombstoned.wav")
        let audioData = Data("must survive cleanup".utf8)
        try audioData.write(to: externalAudio)
        try setPendingBoundaryPermissions(0o644, on: externalAudio)
        let audioLink = directory.appendingPathComponent(audioName)
        try FileManager.default.createSymbolicLink(at: audioLink, withDestinationURL: externalAudio)
        let indexData = Data(
            "{\"version\":2,\"records\":[],\"tombstones\":[\"\(audioName)\"],\"completions\":[]}".utf8
        )
        try indexData.write(to: directory.appendingPathComponent("pending-audio-index.json"))

        let store = MacPendingAudioStore(directoryURL: directory)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: externalAudio), audioData)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalAudio), 0o644)
        XCTAssertTrue(isPendingBoundarySymbolicLink(audioLink))
    }

    func testParentReplacedBySymlinkAfterLaunchBlocksAudioLookupAndRemoval() throws {
        let scratch = try makePendingBoundaryScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let speakPaste = scratch.appendingPathComponent("SpeakPaste", isDirectory: true)
        let directory = speakPaste.appendingPathComponent("PendingAudio", isDirectory: true)
        let source = scratch.appendingPathComponent("captured.wav")
        try Data("captured locally".utf8).write(to: source)
        let store = MacPendingAudioStore(directoryURL: directory)
        let staged = try store.stage(
            sourceURL: source,
            deviceName: "Microphone",
            recordingDuration: 1
        )

        let formerOwnedDirectory = scratch.appendingPathComponent("FormerSpeakPaste", isDirectory: true)
        try FileManager.default.moveItem(at: speakPaste, to: formerOwnedDirectory)
        let externalSpeakPaste = scratch.appendingPathComponent("ExternalAfterLaunch", isDirectory: true)
        let externalPendingAudio = externalSpeakPaste.appendingPathComponent("PendingAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: externalPendingAudio, withIntermediateDirectories: true)
        let externalAudio = externalPendingAudio.appendingPathComponent(staged.fileName)
        let externalIndex = externalPendingAudio.appendingPathComponent("pending-audio-index.json")
        let audioData = Data("external replacement audio".utf8)
        let indexData = Data(
            #"{"version":2,"records":[],"tombstones":[],"completions":[]}"#.utf8
        )
        try audioData.write(to: externalAudio)
        try indexData.write(to: externalIndex)
        try setPendingBoundaryPermissions(0o755, on: externalSpeakPaste)
        try setPendingBoundaryPermissions(0o755, on: externalPendingAudio)
        try setPendingBoundaryPermissions(0o644, on: externalAudio)
        try setPendingBoundaryPermissions(0o644, on: externalIndex)
        try FileManager.default.createSymbolicLink(at: speakPaste, withDestinationURL: externalSpeakPaste)

        XCTAssertThrowsError(try store.audioURL(for: staged))
        XCTAssertThrowsError(try store.remove(staged.id))
        XCTAssertNotNil(store.record(withID: staged.id))
        XCTAssertEqual(try Data(contentsOf: externalAudio), audioData)
        XCTAssertEqual(try Data(contentsOf: externalIndex), indexData)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalSpeakPaste), 0o755)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalPendingAudio), 0o755)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalAudio), 0o644)
        XCTAssertEqual(try pendingBoundaryPermissions(of: externalIndex), 0o644)
    }
}

private struct PendingBoundaryFixture {
    let url: URL
    let data: Data
}

private func makePendingBoundaryFixtures(in directory: URL) throws -> [PendingBoundaryFixture] {
    let values: [(String, Data)] = [
        (
            "pending-audio-index.json",
            Data(#"{"version":99,"records":[],"tombstones":[],"futureRules":true}"#.utf8)
        ),
        ("4B7C6885-F44C-4BEA-9E1A-C6BD0CC61B80.wav", Data("external audio".utf8)),
    ]
    return try values.map { name, data in
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return PendingBoundaryFixture(url: url, data: data)
    }
}

private func assertPendingBoundaryFixturesUnchanged(
    _ fixtures: [PendingBoundaryFixture],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    for fixture in fixtures {
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.data, file: file, line: line)
        XCTAssertEqual(try pendingBoundaryPermissions(of: fixture.url), 0o644, file: file, line: line)
    }
}

private func makePendingBoundaryScratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpeakPaste-pending-boundary-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func setPendingBoundaryPermissions(_ permissions: Int, on url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

private func pendingBoundaryPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private func isPendingBoundarySymbolicLink(_ url: URL) -> Bool {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFLNK
}
