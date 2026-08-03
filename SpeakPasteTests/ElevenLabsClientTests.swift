import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeakPasteClient
#else
@testable import SpeakPaste
#endif

fileprivate struct MockHTTPResult: @unchecked Sendable {
    let response: HTTPURLResponse
    let data: Data
    let delay: TimeInterval
    let onCompletion: (@Sendable () -> Void)?

    init(
        response: HTTPURLResponse,
        data: Data,
        delay: TimeInterval = 0,
        onCompletion: (@Sendable () -> Void)? = nil
    ) {
        self.response = response
        self.data = data
        self.delay = delay
        self.onCompletion = onCompletion
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) fileprivate static var requestHandler: ((URLRequest) throws -> MockHTTPResult)?

    private let stateLock = NSLock()
    private var didComplete = false
    private var pendingWork: DispatchWorkItem?
    private var result: MockHTTPResult?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("No request handler configured")
            return
        }

        do {
            let result = try handler(request)
            let work = DispatchWorkItem { [weak self] in
                self?.finish(with: result)
            }

            stateLock.lock()
            if didComplete {
                stateLock.unlock()
                result.onCompletion?()
                return
            }
            self.result = result
            pendingWork = work
            stateLock.unlock()

            if result.delay > 0 {
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + result.delay,
                    execute: work
                )
            } else {
                work.perform()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        guard !didComplete else {
            stateLock.unlock()
            return
        }
        didComplete = true
        let work = pendingWork
        let completion = result?.onCompletion
        pendingWork = nil
        result = nil
        stateLock.unlock()

        work?.cancel()
        completion?()
    }

    private func finish(with result: MockHTTPResult) {
        stateLock.lock()
        guard !didComplete else {
            stateLock.unlock()
            return
        }
        didComplete = true
        pendingWork = nil
        self.result = nil
        stateLock.unlock()

        client?.urlProtocol(self, didReceive: result.response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
        result.onCompletion?()
    }
}

final class ElevenLabsRedirectSecurityTests: XCTestCase {
    func testRedirectDelegateRejectsCrossOriginRequestBeforeFollow() {
        let delegate = ElevenLabsNoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let original = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        let redirected = URLRequest(url: URL(string: "https://attacker.example/upload")!)
        let response = HTTPURLResponse(
            url: original,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": redirected.url!.absoluteString]
        )!
        let task = session.dataTask(with: original)
        var proposedRequest: URLRequest? = redirected

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirected
        ) { proposedRequest = $0 }

        XCTAssertNil(proposedRequest)
        session.invalidateAndCancel()
    }
}

private final class RequestTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptsStorage = 0
    private var activeStorage = 0
    private var peakStorage = 0

    var attempts: Int {
        lock.withLock { attemptsStorage }
    }

    var peakActive: Int {
        lock.withLock { peakStorage }
    }

    @discardableResult
    func begin() -> Int {
        lock.withLock {
            attemptsStorage += 1
            activeStorage += 1
            peakStorage = max(peakStorage, activeStorage)
            return attemptsStorage
        }
    }

    func finish() {
        lock.withLock {
            activeStorage -= 1
        }
    }
}

private final class MultipartRequestRecorder: @unchecked Sendable {
    struct Snapshot {
        let body: Data
        let hadMaterializedBody: Bool
        let hadBodyStream: Bool
        let contentType: String?
        let contentLength: String?
        let timeoutInterval: TimeInterval
        let cachePolicy: URLRequest.CachePolicy
        let handlesCookies: Bool
    }

    private let lock = NSLock()
    private var snapshotsStorage: [Snapshot] = []

    var snapshots: [Snapshot] {
        lock.withLock { snapshotsStorage }
    }

    @discardableResult
    func capture(_ request: URLRequest) throws -> Int {
        let hadMaterializedBody = request.httpBody != nil
        let hadBodyStream = request.httpBodyStream != nil
        let body = try ElevenLabsClientTests.bodyData(from: request)
        return lock.withLock {
            snapshotsStorage.append(
                Snapshot(
                    body: body,
                    hadMaterializedBody: hadMaterializedBody,
                    hadBodyStream: hadBodyStream,
                    contentType: request.value(forHTTPHeaderField: "Content-Type"),
                    contentLength: request.value(forHTTPHeaderField: "Content-Length"),
                    timeoutInterval: request.timeoutInterval,
                    cachePolicy: request.cachePolicy,
                    handlesCookies: request.httpShouldHandleCookies
                )
            )
            return snapshotsStorage.count
        }
    }
}

private actor DelayRecorder {
    private var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        values.append(value)
    }

    func snapshot() -> [TimeInterval] {
        values
    }
}

final class ElevenLabsClientTests: XCTestCase {
    private let endpoint = URL(string: "https://example.test/speech-to-text")!

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testScribeV2LanguageCatalogHasStableUniqueIdentifiersAndCodes() throws {
        let languages = TranscriptionLanguage.supportedCases
        let pinnedLanguages = languages.filter { $0 != .automatic }
        let codes = try pinnedLanguages.map { try XCTUnwrap($0.apiCode) }

        XCTAssertEqual(languages.count, 100)
        XCTAssertEqual(Array(languages.prefix(3)), [.automatic, .english, .spanish])
        XCTAssertEqual(Set(languages.map(\.rawValue)).count, languages.count)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertTrue(codes.allSatisfy { code in
            (2...3).contains(code.count)
                && code.unicodeScalars.allSatisfy(CharacterSet.lowercaseLetters.contains)
        })

        let french = try XCTUnwrap(TranscriptionLanguage(rawValue: "french"))
        XCTAssertEqual(french.title, "French")
        XCTAssertEqual(french.apiCode, "fra")

        let mandarin = try XCTUnwrap(TranscriptionLanguage(rawValue: "mandarin-chinese"))
        XCTAssertEqual(mandarin.title, "Mandarin Chinese")
        XCTAssertEqual(mandarin.apiCode, "zho")
        XCTAssertEqual(TranscriptionLanguage.title(forAPICode: " ZHO "), "Mandarin Chinese")
        XCTAssertEqual(TranscriptionLanguage.title(forAPICode: "en"), "English")
        XCTAssertNil(TranscriptionLanguage.title(forAPICode: "unknown"))
        XCTAssertNil(TranscriptionLanguage(rawValue: "not-a-scribe-language"))
    }

    func testOriginalLanguageValuesKeepTheirPersistedAndWireRepresentations() throws {
        XCTAssertEqual(TranscriptionLanguage.automatic.rawValue, "automatic")
        XCTAssertNil(TranscriptionLanguage.automatic.apiCode)
        XCTAssertEqual(TranscriptionLanguage.english.rawValue, "english")
        XCTAssertEqual(TranscriptionLanguage.english.apiCode, "en")
        XCTAssertEqual(TranscriptionLanguage.spanish.rawValue, "spanish")
        XCTAssertEqual(TranscriptionLanguage.spanish.apiCode, "es")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try encoder.encode(TranscriptionLanguage.english), Data("\"english\"".utf8))
        XCTAssertEqual(
            try decoder.decode(TranscriptionLanguage.self, from: Data("\"spanish\"".utf8)),
            .spanish
        )
        XCTAssertThrowsError(
            try decoder.decode(
                TranscriptionLanguage.self,
                from: Data("\"not-a-scribe-language\"".utf8)
            )
        )
    }

    func testTranscribeSendsScribeV2CleanEnglishMultipartAndDecodesResponse() async throws {
        let session = makeSession()
        let client = ElevenLabsClient(session: session, endpoint: endpoint)

        MockURLProtocol.requestHandler = { [endpoint] request in
            XCTAssertEqual(request.url, endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
            let body = String(decoding: try Self.bodyData(from: request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
            XCTAssertTrue(body.contains("name=\"no_verbatim\"\r\n\r\ntrue"))
            XCTAssertTrue(body.contains("name=\"language_code\"\r\n\r\nen"))
            XCTAssertTrue(body.contains("name=\"file\"; filename="))

            return MockHTTPResult(
                response: Self.response(url: endpoint, statusCode: 200),
                data: Self.successData(text: "A clean transcript.")
            )
        }

        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let result = try await client.transcribe(
            audioURL: audioURL,
            apiKey: "test-key",
            language: .english,
            cleanSpeech: true
        )

        XCTAssertEqual(result.text, "A clean transcript.")
        XCTAssertEqual(result.languageCode, "en")
        XCTAssertEqual(result.languageProbability, 0.99)
    }

    func testMultipartUploadUsesAStreamExactLengthFiveMinuteTimeoutAndAllScribeFields() async throws {
        let recorder = MultipartRequestRecorder()
        let client = ElevenLabsClient(session: makeSession(), endpoint: endpoint)
        var audio = Data(repeating: 0xA5, count: 2 * 1_024 * 1_024)
        audio.replaceSubrange(100..<108, with: Data([0x00, 0xFF, 0x13, 0x37, 0x0D, 0x0A, 0x42, 0x00]))
        let audioURL = try makeAudioFile(contents: audio, fileExtension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        MockURLProtocol.requestHandler = { request in
            _ = try recorder.capture(request)
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 200),
                data: Self.successData(text: "Streamed transcript.")
            )
        }

        let result = try await client.transcribe(
            audioURL: audioURL,
            apiKey: "test-key",
            language: .english,
            cleanSpeech: true,
            keyterms: ["SpeakPaste", "ElevenLabs"]
        )

        XCTAssertEqual(result.text, "Streamed transcript.")
        let snapshot = try XCTUnwrap(recorder.snapshots.first)
        XCTAssertFalse(snapshot.hadMaterializedBody, "The upload regressed to URLRequest.httpBody")
        XCTAssertTrue(snapshot.hadBodyStream)
        XCTAssertEqual(snapshot.timeoutInterval, 300, accuracy: 0.001)
        XCTAssertEqual(snapshot.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(snapshot.handlesCookies)
        XCTAssertEqual(Int(snapshot.contentLength ?? ""), snapshot.body.count)
        XCTAssertTrue(snapshot.contentType?.hasPrefix("multipart/form-data; boundary=SpeakPaste-") == true)
        XCTAssertNotNil(snapshot.body.range(of: audio), "The streamed multipart lost or rewrote audio bytes")

        let body = String(decoding: snapshot.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        XCTAssertTrue(body.contains("name=\"no_verbatim\"\r\n\r\ntrue\r\n"))
        XCTAssertTrue(body.contains("name=\"tag_audio_events\"\r\n\r\nfalse\r\n"))
        XCTAssertTrue(body.contains("name=\"language_code\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"keyterms\"\r\n\r\nSpeakPaste\r\n"))
        XCTAssertTrue(body.contains("name=\"keyterms\"\r\n\r\nElevenLabs\r\n"))
        XCTAssertFalse(body.contains("name=\"keyterms[]\""))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"recording.wav\""))
        XCTAssertFalse(body.contains(audioURL.lastPathComponent))
        XCTAssertTrue(body.contains("Content-Type: audio/wav\r\n\r\n"))

        let boundary = try XCTUnwrap(snapshot.contentType?.components(separatedBy: "boundary=").last)
        XCTAssertTrue(snapshot.body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count)
            .elementsEqual(Data("\r\n--\(boundary)--\r\n".utf8)))
    }

    func testMultipartDropsInvalidKeytermsAndNeverSendsThePrivateSourceFilename() async throws {
        let recorder = MultipartRequestRecorder()
        let client = ElevenLabsClient(session: makeSession(), endpoint: endpoint)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakpaste-private-name-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("Pedro confidential customer call.wav")
        try Data("private audio".utf8).write(to: audioURL)

        MockURLProtocol.requestHandler = { request in
            _ = try recorder.capture(request)
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 200),
                data: Self.successData(text: "Private transcript.")
            )
        }

        let result = try await client.transcribe(
            audioURL: audioURL,
            apiKey: "header-only-secret",
            language: .automatic,
            cleanSpeech: false,
            keyterms: [
                "SpeakPaste",
                "speakpaste", // case-insensitive duplicate
                "  ElevenLabs  ",
                "line break\r\n--injected",
                "unsupported<bracket",
                "unsupported\\slash",
                String(repeating: "v", count: 49),
                String(repeating: "b", count: 50),
                String(repeating: "a", count: 51),
                "one two three four five six",
                "iPhone",
            ]
        )

        XCTAssertEqual(result.text, "Private transcript.")
        let snapshot = try XCTUnwrap(recorder.snapshots.first)
        let body = String(decoding: snapshot.body, as: UTF8.self)
        XCTAssertEqual(
            body.components(separatedBy: "name=\"keyterms\"").count - 1,
            4
        )
        XCTAssertTrue(body.contains("\r\n\r\nSpeakPaste\r\n"))
        XCTAssertTrue(body.contains("\r\n\r\nElevenLabs\r\n"))
        XCTAssertTrue(body.contains("\r\n\r\niPhone\r\n"))
        XCTAssertTrue(body.contains("\r\n\r\n\(String(repeating: "v", count: 49))\r\n"))
        XCTAssertFalse(body.contains(String(repeating: "b", count: 50)))
        XCTAssertFalse(body.contains("injected"))
        XCTAssertFalse(body.contains("unsupported"))
        XCTAssertFalse(body.contains("header-only-secret"))
        XCTAssertFalse(body.contains(audioURL.lastPathComponent))
        XCTAssertTrue(body.contains("filename=\"recording.wav\""))
    }

    func testRetryReopensAndReplaysTheEntireMultipartStream() async throws {
        let tracker = RequestTracker()
        let recorder = MultipartRequestRecorder()
        let delays = DelayRecorder()
        let client = makeClient(delays: delays, maximumAttempts: 2)
        let audio = Data((0..<65_537).map { UInt8($0 % 251) })
        let audioURL = try makeAudioFile(contents: audio, fileExtension: "flac")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        MockURLProtocol.requestHandler = { request in
            tracker.begin()
            tracker.finish()
            let attempt = try recorder.capture(request)
            if attempt == 1 {
                return MockHTTPResult(
                    response: Self.response(url: request.url!, statusCode: 503),
                    data: Data(#"{"message":"Retry me"}"#.utf8)
                )
            }
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 200),
                data: Self.successData(text: "Replay succeeded.")
            )
        }

        let result = try await client.transcribe(
            audioURL: audioURL,
            apiKey: "test-key",
            language: .automatic,
            cleanSpeech: false,
            keyterms: ["Replay"]
        )

        XCTAssertEqual(result.text, "Replay succeeded.")
        XCTAssertEqual(tracker.attempts, 2)
        let snapshots = recorder.snapshots
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].body, snapshots[1].body)
        XCTAssertEqual(snapshots[0].contentType, snapshots[1].contentType)
        XCTAssertEqual(snapshots[0].contentLength, snapshots[1].contentLength)
        XCTAssertTrue(snapshots.allSatisfy { !$0.hadMaterializedBody && $0.hadBodyStream })
        XCTAssertTrue(snapshots.allSatisfy { $0.body.range(of: audio) != nil })
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [0.25])
    }

    func testMultipartTempFileIsRemovedWhenSourcePreparationFails() async throws {
        let client = ElevenLabsClient(session: makeSession(), endpoint: endpoint)
        let before = try Self.multipartUploadTempFiles()
        let missingAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-speakpaste-audio-\(UUID().uuidString).wav")

        do {
            _ = try await client.transcribe(
                audioURL: missingAudioURL,
                apiKey: "test-key",
                language: .automatic,
                cleanSpeech: false
            )
            XCTFail("Expected missing source preparation to fail")
        } catch {
            // The concrete filesystem error is not part of the client contract;
            // the observable invariant is that no private upload copy remains.
        }

        let after = try Self.multipartUploadTempFiles()
        XCTAssertEqual(after.subtracting(before), [])
    }

    func testLaunchCleanupRemovesOnlyPrivateGeneratedMultipartUploads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakpaste-cleanup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let removable = directory.appendingPathComponent(
            "SpeakPaste-upload-\(UUID().uuidString).multipart"
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: removable.path,
                contents: Data("private audio".utf8),
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
        )
        let unrelated = directory.appendingPathComponent("unrelated.multipart")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: unrelated.path,
                contents: Data("keep".utf8),
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
        )
        let permissive = directory.appendingPathComponent(
            "SpeakPaste-upload-\(UUID().uuidString).multipart"
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: permissive.path,
                contents: Data("keep".utf8),
                attributes: [.posixPermissions: NSNumber(value: Int16(0o644))]
            )
        )
        let symlink = directory.appendingPathComponent(
            "SpeakPaste-upload-\(UUID().uuidString).multipart"
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)

        XCTAssertEqual(
            ElevenLabsClient.cleanupAbandonedMultipartUploads(in: directory),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: permissive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    func testAuthenticationFailureIsActionableAndIsNotRetried() async throws {
        let tracker = RequestTracker()
        let delays = DelayRecorder()
        let client = makeClient(delays: delays)

        MockURLProtocol.requestHandler = { request in
            tracker.begin()
            tracker.finish()
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 401),
                data: Data(#"{"detail":{"message":"Invalid API key"}}"#.utf8)
            )
        }

        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await client.transcribe(
                audioURL: audioURL,
                apiKey: "bad-key",
                language: .automatic,
                cleanSpeech: false
            )
            XCTFail("Expected the request to fail")
        } catch let error as ElevenLabsClientError {
            XCTAssertEqual(error, .api(statusCode: 401, message: "Invalid API key"))
            XCTAssertEqual(error.category, .authentication)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(
                error.recoverySuggestion,
                "Open Settings and update your ElevenLabs API key."
            )
        }

        XCTAssertEqual(tracker.attempts, 1)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [])
    }

    func testImportedAudioFormatsSendMatchingMultipartContentTypes() async throws {
        let expectedTypes = [
            "wav": "audio/wav",
            "mp3": "audio/mpeg",
            "m4a": "audio/mp4",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "ogg": "audio/ogg",
            "opus": "audio/opus",
            "flac": "audio/flac",
            "aac": "audio/aac",
            "caf": "audio/x-caf",
            "aiff": "audio/aiff",
            "webm": "video/webm",
            "unknown": "application/octet-stream",
        ]
        let client = ElevenLabsClient(session: makeSession(), endpoint: endpoint)

        for (fileExtension, expectedType) in expectedTypes {
            MockURLProtocol.requestHandler = { request in
                let body = String(decoding: try Self.bodyData(from: request), as: UTF8.self)
                XCTAssertTrue(
                    body.contains("Content-Type: \(expectedType)\r\n"),
                    "Expected \(fileExtension) to use \(expectedType)"
                )
                return MockHTTPResult(
                    response: Self.response(url: request.url!, statusCode: 200),
                    data: Self.successData(text: "Imported transcript.")
                )
            }

            let audioURL = try makeAudioFile(fileExtension: fileExtension)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let result = try await client.transcribe(
                audioURL: audioURL,
                apiKey: "test-key",
                language: .automatic,
                cleanSpeech: false
            )
            XCTAssertEqual(result.text, "Imported transcript.")
        }
    }

    func testValidationFailureIsNotRetried() async throws {
        let tracker = RequestTracker()
        let delays = DelayRecorder()
        let client = makeClient(delays: delays)

        MockURLProtocol.requestHandler = { request in
            tracker.begin()
            tracker.finish()
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 422),
                data: Data(#"{"detail":"Unsupported audio"}"#.utf8)
            )
        }

        let error = await capturedClientError(from: client)

        XCTAssertEqual(error, .api(statusCode: 422, message: "Unsupported audio"))
        XCTAssertEqual(error?.category, .invalidRequest)
        XCTAssertEqual(error?.isRetryable, false)
        XCTAssertEqual(tracker.attempts, 1)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [])
    }

    func testRateLimitRetriesOnceAndHonorsRetryAfter() async throws {
        let tracker = RequestTracker()
        let delays = DelayRecorder()
        let client = makeClient(delays: delays, maximumDelay: 10)

        MockURLProtocol.requestHandler = { request in
            let attempt = tracker.begin()
            tracker.finish()
            if attempt == 1 {
                return MockHTTPResult(
                    response: Self.response(
                        url: request.url!,
                        statusCode: 429,
                        headers: ["Retry-After": "7"]
                    ),
                    data: Data(#"{"detail":"Too many requests"}"#.utf8)
                )
            }
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 200),
                data: Self.successData(text: "Recovered after throttling.")
            )
        }

        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let result = try await client.transcribe(
            audioURL: audioURL,
            apiKey: "test-key",
            language: .automatic,
            cleanSpeech: false
        )

        XCTAssertEqual(result.text, "Recovered after throttling.")
        XCTAssertEqual(tracker.attempts, 2)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [7])
    }

    func testTransientServiceFailureUsesBoundedExponentialBackoff() async throws {
        let tracker = RequestTracker()
        let delays = DelayRecorder()
        let client = makeClient(
            delays: delays,
            maximumAttempts: 3,
            initialDelay: 0.25,
            maximumDelay: 0.4
        )

        MockURLProtocol.requestHandler = { request in
            tracker.begin()
            tracker.finish()
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 503),
                data: Data(#"{"message":"Temporarily unavailable"}"#.utf8)
            )
        }

        let error = await capturedClientError(from: client)

        XCTAssertEqual(error, .api(statusCode: 503, message: "Temporarily unavailable"))
        XCTAssertEqual(error?.category, .serviceUnavailable)
        XCTAssertEqual(error?.isRetryable, true)
        XCTAssertEqual(tracker.attempts, 3)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [0.25, 0.4])
    }

    func testTransientNetworkFailureRetriesAndReturnsStructuredErrorWhenExhausted() async throws {
        let tracker = RequestTracker()
        let delays = DelayRecorder()
        let client = makeClient(delays: delays, maximumAttempts: 2)

        MockURLProtocol.requestHandler = { _ in
            tracker.begin()
            tracker.finish()
            throw URLError(.networkConnectionLost)
        }

        let error = await capturedClientError(from: client)

        XCTAssertEqual(
            error,
            .transport(
                code: .networkConnectionLost,
                message: "The connection dropped before transcription finished."
            )
        )
        XCTAssertEqual(error?.category, .network)
        XCTAssertEqual(error?.isRetryable, true)
        XCTAssertEqual(tracker.attempts, 2)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [0.25])
    }

    func testBackgroundIntentClientUsesOneBoundedRequestWithoutBackoff() async throws {
        let tracker = RequestTracker()
        let recorder = MultipartRequestRecorder()
        let delays = DelayRecorder()
        let client = ElevenLabsClient(
            session: makeSession(),
            endpoint: endpoint,
            retryPolicy: .backgroundIntent,
            requestTimeout: 25,
            maximumConcurrentRequests: 1,
            sleeper: { delay in await delays.record(delay) }
        )

        MockURLProtocol.requestHandler = { request in
            tracker.begin()
            tracker.finish()
            _ = try recorder.capture(request)
            throw URLError(.networkConnectionLost)
        }

        let error = await capturedClientError(from: client)

        XCTAssertEqual(error?.category, .network)
        XCTAssertEqual(tracker.attempts, 1)
        XCTAssertEqual(recorder.snapshots.map(\.timeoutInterval), [25])
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [])
    }

    func testCertificateFailureIsNotClassifiedAsReconnectableNetworkFailure() async throws {
        let tracker = RequestTracker()
        let delays = DelayRecorder()
        let client = makeClient(delays: delays, maximumAttempts: 3)

        MockURLProtocol.requestHandler = { _ in
            tracker.begin()
            tracker.finish()
            throw URLError(.serverCertificateUntrusted)
        }

        let error = await capturedClientError(from: client)

        XCTAssertEqual(
            error,
            .transport(
                code: .serverCertificateUntrusted,
                message: "The network request failed."
            )
        )
        XCTAssertEqual(error?.category, .unknown)
        XCTAssertEqual(error?.isRetryable, false)
        XCTAssertEqual(tracker.attempts, 1)
        let recordedDelays = await delays.snapshot()
        XCTAssertEqual(recordedDelays, [])
    }

    func testConcurrentDictationsNeverExceedConfiguredRequestCap() async throws {
        let tracker = RequestTracker()
        let client = ElevenLabsClient(
            session: makeSession(),
            endpoint: endpoint,
            retryPolicy: ElevenLabsRetryPolicy(
                maximumAttempts: 1,
                initialDelay: 0,
                maximumDelay: 0
            ),
            maximumConcurrentRequests: 3
        )

        MockURLProtocol.requestHandler = { request in
            tracker.begin()
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 200),
                data: Self.successData(text: "Concurrent transcript."),
                delay: 0.1,
                onCompletion: { tracker.finish() }
            )
        }

        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await client.transcribe(
                        audioURL: audioURL,
                        apiKey: "test-key",
                        language: .automatic,
                        cleanSpeech: false
                    )
                }
            }
            for try await result in group {
                XCTAssertEqual(result.text, "Concurrent transcript.")
            }
        }

        XCTAssertEqual(tracker.attempts, 8)
        XCTAssertEqual(tracker.peakActive, 3)
    }

    func testCancellingAQueuedDictationDoesNotSendOrLeakAdmissionCapacity() async throws {
        let tracker = RequestTracker()
        let firstRequestStarted = expectation(description: "first request started")
        let queuedTaskStarted = expectation(description: "queued task started")
        let client = ElevenLabsClient(
            session: makeSession(),
            endpoint: endpoint,
            retryPolicy: ElevenLabsRetryPolicy(
                maximumAttempts: 1,
                initialDelay: 0,
                maximumDelay: 0
            ),
            maximumConcurrentRequests: 1
        )
        MockURLProtocol.requestHandler = { request in
            let attempt = tracker.begin()
            if attempt == 1 {
                firstRequestStarted.fulfill()
                return MockHTTPResult(
                    response: Self.response(url: request.url!, statusCode: 200),
                    data: Self.successData(text: "Cancelled first request."),
                    delay: 10,
                    onCompletion: { tracker.finish() }
                )
            }
            tracker.finish()
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 200),
                data: Self.successData(text: "Capacity recovered.")
            )
        }

        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let first = Task {
            try await client.transcribe(
                audioURL: audioURL,
                apiKey: "test-key",
                language: .automatic,
                cleanSpeech: false
            )
        }
        await fulfillment(of: [firstRequestStarted], timeout: 1)

        let queued = Task {
            queuedTaskStarted.fulfill()
            return try await client.transcribe(
                audioURL: audioURL,
                apiKey: "test-key",
                language: .automatic,
                cleanSpeech: false
            )
        }
        await fulfillment(of: [queuedTaskStarted], timeout: 1)
        for _ in 0..<10 { await Task.yield() }
        queued.cancel()

        do {
            _ = try await queued.value
            XCTFail("Expected queued cancellation")
        } catch is CancellationError {
            // Expected: a canceled waiter never owns or leaks a request slot.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(tracker.attempts, 1)

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected first request cancellation")
        } catch is CancellationError {
            // Releases the one occupied slot.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let recovered = try await client.transcribe(
            audioURL: audioURL,
            apiKey: "test-key",
            language: .automatic,
            cleanSpeech: false
        )
        XCTAssertEqual(recovered.text, "Capacity recovered.")
        XCTAssertEqual(tracker.attempts, 2)
        XCTAssertEqual(tracker.peakActive, 1)
    }

    func testCancellingAnInFlightRequestThrowsCancellationErrorWithoutRetrying() async throws {
        let tracker = RequestTracker()
        let requestStarted = expectation(description: "request started")
        let client = makeClient(delays: DelayRecorder())

        MockURLProtocol.requestHandler = { request in
            tracker.begin()
            requestStarted.fulfill()
            return MockHTTPResult(
                response: Self.response(url: request.url!, statusCode: 200),
                data: Self.successData(text: "Too late."),
                delay: 10,
                onCompletion: { tracker.finish() }
            )
        }

        let audioURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let task = Task {
            try await client.transcribe(
                audioURL: audioURL,
                apiKey: "test-key",
                language: .automatic,
                cleanSpeech: false
            )
        }

        await fulfillment(of: [requestStarted], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not rewritten as a retryable network failure.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(tracker.attempts, 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient(
        delays: DelayRecorder,
        maximumAttempts: Int = 3,
        initialDelay: TimeInterval = 0.25,
        maximumDelay: TimeInterval = 1
    ) -> ElevenLabsClient {
        ElevenLabsClient(
            session: makeSession(),
            endpoint: endpoint,
            retryPolicy: ElevenLabsRetryPolicy(
                maximumAttempts: maximumAttempts,
                initialDelay: initialDelay,
                maximumDelay: maximumDelay
            ),
            sleeper: { delay in await delays.record(delay) }
        )
    }

    private func capturedClientError(from client: ElevenLabsClient) async -> ElevenLabsClientError? {
        do {
            let audioURL = try makeAudioFile()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            _ = try await client.transcribe(
                audioURL: audioURL,
                apiKey: "test-key",
                language: .automatic,
                cleanSpeech: false
            )
            XCTFail("Expected the request to fail")
            return nil
        } catch let error as ElevenLabsClientError {
            return error
        } catch {
            XCTFail("Expected ElevenLabsClientError, got \(error)")
            return nil
        }
    }

    private func makeAudioFile(
        contents: Data = Data("audio".utf8),
        fileExtension: String = "m4a"
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakpaste-test-\(UUID().uuidString).\(fileExtension)")
        try contents.write(to: url)
        return url
    }

    private static func response(
        url: URL,
        statusCode: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    private static func successData(text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "text": text,
            "language_code": "en",
            "language_probability": 0.99,
        ])
    }

    private static func multipartUploadTempFiles() throws -> Set<URL> {
        Set(
            try FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix("SpeakPaste-upload-")
                    && $0.pathExtension == "multipart"
            }
        )
    }

    fileprivate static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
