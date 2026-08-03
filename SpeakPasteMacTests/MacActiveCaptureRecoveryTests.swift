import Foundation
import XCTest
@testable import SpeakPaste

final class MacActiveCaptureRecoveryTests: XCTestCase {
    func testDiscoveryAcceptsOnlyExactGeneratedBasenames() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let acceptedID = UUID()
        let accepted = scratch.appendingPathComponent("SpeakPaste-\(acceptedID.uuidString).wav")
        try writeTestWAV(to: accepted)

        let otherID = UUID()
        let rejectedNames = [
            "SpeakPaste-not-a-uuid.wav",
            "SpeakPaste-\(otherID.uuidString.lowercased()).wav",
            "SpeakPaste-\(UUID().uuidString).WAV",
            "SpeakPaste-\(UUID().uuidString).wav.backup",
            "SpeakPaste-import-\(UUID().uuidString).wav",
            "Other-\(UUID().uuidString).wav",
        ]
        for name in rejectedNames {
            try writeTestWAV(to: scratch.appendingPathComponent(name))
        }

        let discovered = try MacActiveCaptureRecovery.discover(in: scratch)

        XCTAssertEqual(discovered.map(\.id), [acceptedID])
        XCTAssertEqual(discovered.map { $0.url.lastPathComponent }, [accepted.lastPathComponent])
        for name in rejectedNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(name).path))
        }
    }

    func testDiscoveryRequiresRIFFWAVEHeaderAndPayload() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let acceptedID = UUID()
        try writeTestWAV(
            to: scratch.appendingPathComponent("SpeakPaste-\(acceptedID.uuidString).wav")
        )

        let wrongRIFF = scratch.appendingPathComponent("SpeakPaste-\(UUID().uuidString).wav")
        try writePrivateData(Data(repeating: 0x41, count: 64), to: wrongRIFF)

        let wrongWAVE = scratch.appendingPathComponent("SpeakPaste-\(UUID().uuidString).wav")
        var wrongWAVEData = testWAVData()
        wrongWAVEData.replaceSubrange(8..<12, with: Data("NOPE".utf8))
        try writePrivateData(wrongWAVEData, to: wrongWAVE)

        let headerOnly = scratch.appendingPathComponent("SpeakPaste-\(UUID().uuidString).wav")
        try writePrivateData(testWAVData(payload: Data()), to: headerOnly)

        let discovered = try MacActiveCaptureRecovery.discover(in: scratch)

        XCTAssertEqual(discovered.map(\.id), [acceptedID])
    }

    func testDiscoveryRejectsSymlinksSharedFilesAndUnrelatedTempFiles() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let acceptedID = UUID()
        let accepted = scratch.appendingPathComponent("SpeakPaste-\(acceptedID.uuidString).wav")
        try writeTestWAV(to: accepted)

        let symlinkTarget = scratch.appendingPathComponent("symlink-target.wav")
        try writeTestWAV(to: symlinkTarget)
        let symlink = scratch.appendingPathComponent("SpeakPaste-\(UUID().uuidString).wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)

        let shared = scratch.appendingPathComponent("SpeakPaste-\(UUID().uuidString).wav")
        try writeTestWAV(to: shared, permissions: 0o644)

        let hardLinkSource = scratch.appendingPathComponent("hard-link-source.wav")
        try writeTestWAV(to: hardLinkSource)
        let hardLink = scratch.appendingPathComponent("SpeakPaste-\(UUID().uuidString).wav")
        try FileManager.default.linkItem(at: hardLinkSource, to: hardLink)

        let unrelated = scratch.appendingPathComponent("unrelated.wav")
        try writeTestWAV(to: unrelated)

        let discovered = try MacActiveCaptureRecovery.discover(in: scratch)

        XCTAssertEqual(discovered.map(\.id), [acceptedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hardLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testRecordingPermissionHardeningUsesExactNameAndDoesNotFollowSymlinks() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let recording = scratch.appendingPathComponent("SpeakPaste-\(UUID().uuidString).wav")
        try writeTestWAV(to: recording, permissions: 0o644)

        XCTAssertTrue(MacActiveCaptureRecovery.makeRecordingPrivate(at: recording))
        XCTAssertEqual(try activeCapturePermissions(of: recording), 0o600)

        let target = scratch.appendingPathComponent("target.wav")
        try writeTestWAV(to: target, permissions: 0o644)
        let symlink = scratch.appendingPathComponent("SpeakPaste-\(UUID().uuidString).wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        XCTAssertFalse(MacActiveCaptureRecovery.makeRecordingPrivate(at: symlink))
        XCTAssertEqual(try activeCapturePermissions(of: target), 0o644)
    }

    func testRecoveryStagesValidCaptureAsWaitingAndLeavesOtherTempFilesUntouched() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporaryDirectory = scratch.appendingPathComponent("Temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: temporaryDirectory.path
        )
        let pendingDirectory = scratch.appendingPathComponent("Pending", isDirectory: true)
        let captureID = UUID()
        let capture = temporaryDirectory.appendingPathComponent("SpeakPaste-\(captureID.uuidString).wav")
        let payload = Data("unfinished speech".utf8)
        let audio = testWAVData(payload: payload)
        try writePrivateData(audio, to: capture)
        let unrelated = temporaryDirectory.appendingPathComponent("someone-elses-audio.wav")
        try writePrivateData(audio, to: unrelated)
        let store = MacPendingAudioStore(directoryURL: pendingDirectory)

        let report = MacActiveCaptureRecovery.recover(
            from: temporaryDirectory,
            into: store
        )

        XCTAssertTrue(report.failureDescriptions.isEmpty)
        let recovered = try XCTUnwrap(report.recoveredRecords.first)
        XCTAssertEqual(report.recoveredRecords.count, 1)
        XCTAssertEqual(recovered.id, captureID)
        XCTAssertEqual(recovered.status, .waiting)
        XCTAssertEqual(recovered.deviceName, "Recovered microphone capture")
        XCTAssertEqual(recovered.reason, "Recovered after SpeakPaste closed during recording.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let durableURL = try store.audioURL(for: recovered)
        XCTAssertEqual(try Data(contentsOf: durableURL), audio)
        XCTAssertEqual(try activeCapturePermissions(of: durableURL), 0o600)

        let reloaded = MacPendingAudioStore(directoryURL: pendingDirectory)
        XCTAssertEqual(reloaded.record(withID: captureID)?.status, .waiting)
    }

    func testRecoveryCollapsesIdenticalSourceLeftAfterCrossVolumeCopy() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporaryDirectory = scratch.appendingPathComponent("Temp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let pendingDirectory = scratch.appendingPathComponent("Pending", isDirectory: true)
        _ = MacPendingAudioStore(directoryURL: pendingDirectory)

        let captureID = UUID()
        let audio = testWAVData(payload: Data("copied before crash".utf8))
        let durableURL = pendingDirectory.appendingPathComponent("\(captureID.uuidString).wav")
        try writePrivateData(audio, to: durableURL)
        // A new process first reconstructs the copied destination as an orphan.
        let store = MacPendingAudioStore(directoryURL: pendingDirectory)
        let existing = try XCTUnwrap(store.record(withID: captureID))

        let sourceURL = temporaryDirectory.appendingPathComponent(
            "SpeakPaste-\(captureID.uuidString).wav"
        )
        try writePrivateData(audio, to: sourceURL)

        let report = MacActiveCaptureRecovery.recover(
            from: temporaryDirectory,
            into: store
        )

        XCTAssertTrue(report.failureDescriptions.isEmpty)
        XCTAssertEqual(report.recoveredRecords, [existing])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(store.records.map(\.id), [captureID])
        XCTAssertEqual(try Data(contentsOf: durableURL), audio)
        XCTAssertEqual(
            MacPendingAudioStore(directoryURL: pendingDirectory).records.map(\.id),
            [captureID]
        )
    }

    func testRecoveryPreservesSameIdentifierWhenAudioBytesDiffer() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporaryDirectory = scratch.appendingPathComponent("Temp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let pendingDirectory = scratch.appendingPathComponent("Pending", isDirectory: true)
        _ = MacPendingAudioStore(directoryURL: pendingDirectory)

        let captureID = UUID()
        let durableAudio = testWAVData(payload: Data("durable version".utf8))
        let sourceAudio = testWAVData(payload: Data("different bytes".utf8))
        XCTAssertEqual(durableAudio.count, sourceAudio.count)
        let durableURL = pendingDirectory.appendingPathComponent("\(captureID.uuidString).wav")
        try writePrivateData(durableAudio, to: durableURL)
        let store = MacPendingAudioStore(directoryURL: pendingDirectory)

        let sourceURL = temporaryDirectory.appendingPathComponent(
            "SpeakPaste-\(captureID.uuidString).wav"
        )
        try writePrivateData(sourceAudio, to: sourceURL)

        let report = MacActiveCaptureRecovery.recover(
            from: temporaryDirectory,
            into: store
        )

        XCTAssertTrue(report.recoveredRecords.isEmpty)
        XCTAssertEqual(report.failureDescriptions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceAudio)
        XCTAssertEqual(try Data(contentsOf: durableURL), durableAudio)
        XCTAssertEqual(store.records.map(\.id), [captureID])
    }

    func testDisposableCleanupRemovesOnlyExactPrivateGeneratedArtifacts() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let upload = scratch.appendingPathComponent(
            "SpeakPaste-upload-\(UUID().uuidString).multipart"
        )
        let imported = scratch.appendingPathComponent(
            "SpeakPaste-import-\(UUID().uuidString).WAV"
        )
        try writePrivateData(Data("multipart speech and context".utf8), to: upload)
        try writePrivateData(Data("imported speech".utf8), to: imported)

        let activeCapture = scratch.appendingPathComponent(
            "SpeakPaste-\(UUID().uuidString).wav"
        )
        try writeTestWAV(to: activeCapture)

        let sharedUpload = scratch.appendingPathComponent(
            "SpeakPaste-upload-\(UUID().uuidString).multipart"
        )
        try writePrivateData(Data("unsafe permissions".utf8), to: sharedUpload, permissions: 0o644)

        let symlinkTarget = scratch.appendingPathComponent("upload-target.multipart")
        try writePrivateData(Data("symlink target".utf8), to: symlinkTarget)
        let uploadSymlink = scratch.appendingPathComponent(
            "SpeakPaste-upload-\(UUID().uuidString).multipart"
        )
        try FileManager.default.createSymbolicLink(
            at: uploadSymlink,
            withDestinationURL: symlinkTarget
        )

        let hardLinkSource = scratch.appendingPathComponent("import-hard-link-source.wav")
        try writePrivateData(Data("hard linked import".utf8), to: hardLinkSource)
        let importHardLink = scratch.appendingPathComponent(
            "SpeakPaste-import-\(UUID().uuidString).wav"
        )
        try FileManager.default.linkItem(at: hardLinkSource, to: importHardLink)

        let lowercasedUpload = scratch.appendingPathComponent(
            "SpeakPaste-upload-\(UUID().uuidString.lowercased()).multipart"
        )
        let unsupportedImport = scratch.appendingPathComponent(
            "SpeakPaste-import-\(UUID().uuidString).txt"
        )
        let suffixedUpload = scratch.appendingPathComponent(
            "SpeakPaste-upload-\(UUID().uuidString).multipart.backup"
        )
        let unrelated = scratch.appendingPathComponent("unrelated.multipart")
        for url in [lowercasedUpload, unsupportedImport, suffixedUpload, unrelated] {
            try writePrivateData(Data("leave untouched".utf8), to: url)
        }

        let report = MacActiveCaptureRecovery.cleanupDisposableSpeechArtifacts(in: scratch)

        XCTAssertEqual(report.removedCount, 2)
        XCTAssertTrue(report.failureDescriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
        for url in [
            activeCapture,
            sharedUpload,
            uploadSymlink,
            importHardLink,
            lowercasedUpload,
            unsupportedImport,
            suffixedUpload,
            unrelated,
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Expected \(url.lastPathComponent) to remain")
        }
        XCTAssertEqual(try Data(contentsOf: symlinkTarget), Data("symlink target".utf8))
    }

    func testImportedTempPermissionHardeningRequiresGeneratedImportGrammar() throws {
        let scratch = try makeActiveCaptureScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let imported = scratch.appendingPathComponent(
            "SpeakPaste-import-\(UUID().uuidString).mp3"
        )
        try writePrivateData(Data("speech".utf8), to: imported, permissions: 0o644)

        XCTAssertTrue(MacActiveCaptureRecovery.makeImportedFilePrivate(at: imported))
        XCTAssertEqual(try activeCapturePermissions(of: imported), 0o600)

        let unrelated = scratch.appendingPathComponent("other-import.mp3")
        try writePrivateData(Data("speech".utf8), to: unrelated, permissions: 0o644)
        XCTAssertFalse(MacActiveCaptureRecovery.makeImportedFilePrivate(at: unrelated))
        XCTAssertEqual(try activeCapturePermissions(of: unrelated), 0o644)
    }
}

private func makeActiveCaptureScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SpeakPaste-active-capture-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    return directory
}

private func testWAVData(payload: Data = Data([0x01])) -> Data {
    var data = Data("RIFF".utf8)
    var chunkSize = UInt32(36 + payload.count).littleEndian
    withUnsafeBytes(of: &chunkSize) { data.append(contentsOf: $0) }
    data.append(Data("WAVE".utf8))
    data.append(Data(repeating: 0, count: 32))
    data.append(payload)
    return data
}

private func writeTestWAV(to url: URL, permissions: Int16 = 0o600) throws {
    try writePrivateData(testWAVData(), to: url, permissions: permissions)
}

private func writePrivateData(
    _ data: Data,
    to url: URL,
    permissions: Int16 = 0o600
) throws {
    try data.write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: permissions)],
        ofItemAtPath: url.path
    )
}

private func activeCapturePermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}
