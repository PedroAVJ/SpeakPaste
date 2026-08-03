import Darwin
import Foundation
import UniformTypeIdentifiers

protocol ElevenLabsClientProtocol: Sendable {
    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool,
        keyterms: [String]
    ) async throws -> TranscriptionResult
}

extension ElevenLabsClientProtocol {
    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioURL: audioURL,
            apiKey: apiKey,
            language: language,
            cleanSpeech: cleanSpeech,
            keyterms: []
        )
    }
}

enum ElevenLabsClientError: LocalizedError, Equatable {
    case invalidResponse
    case api(statusCode: Int, message: String)
    /// Keeps the URL loading reason typed. Collapsing certificate, ATS, and
    /// unsupported-URL failures into status 0 made all of them look like an
    /// internet outage and eligible for reconnect retry.
    case transport(code: URLError.Code, message: String)
    case emptyTranscript

    enum Category: String, Equatable, Sendable {
        case authentication
        case invalidRequest
        case rateLimited
        case serviceUnavailable
        case network
        case invalidResponse
        case noSpeech
        case unknown
    }

    var category: Category {
        switch self {
        case .invalidResponse:
            .invalidResponse
        case .emptyTranscript:
            .noSpeech
        case let .transport(code, _):
            Self.isConnectivityCode(code) ? .network : .unknown
        case let .api(statusCode, _):
            switch statusCode {
            case 0:
                .network
            case 401, 403:
                .authentication
            case 400, 404, 409, 413, 415, 422:
                .invalidRequest
            case 429:
                .rateLimited
            case 408, 500, 502, 503, 504:
                .serviceUnavailable
            default:
                .unknown
            }
        }
    }

    static func isConnectivityCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable,
             .backgroundSessionWasDisconnected:
            true
        default:
            false
        }
    }

    var isRetryable: Bool {
        switch category {
        case .rateLimited, .serviceUnavailable, .network:
            true
        case .authentication, .invalidRequest, .invalidResponse, .noSpeech, .unknown:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "ElevenLabs returned an unreadable response."
        case let .api(statusCode, message):
            if statusCode == 0 {
                "Could not reach ElevenLabs: \(message)"
            } else {
                "ElevenLabs error \(statusCode): \(message)"
            }
        case let .transport(_, message):
            message
        case .emptyTranscript:
            "ElevenLabs did not hear any speech. Try again a little closer to the microphone."
        }
    }

    var recoverySuggestion: String? {
        switch category {
        case .authentication:
            "Open Settings and update your ElevenLabs API key."
        case .invalidRequest:
            "Check the recording, language, and custom vocabulary, then try again."
        case .rateLimited:
            "SpeakPaste retried automatically. Wait a moment before trying again."
        case .serviceUnavailable:
            "SpeakPaste retried automatically. ElevenLabs may be temporarily unavailable."
        case .network:
            "Check your internet connection and try again."
        case .invalidResponse:
            "Try again. If this keeps happening, ElevenLabs may have changed its response format."
        case .noSpeech:
            "Speak a little closer to the microphone and try again."
        case .unknown:
            "Try again. If this keeps happening, check the ElevenLabs service status."
        }
    }
}

struct ElevenLabsRetryPolicy: Equatable, Sendable {
    static let standard = ElevenLabsRetryPolicy(
        maximumAttempts: 3,
        initialDelay: 0.5,
        maximumDelay: 30
    )
    /// App Intent transcription owns only a finite iOS background assertion.
    /// Its client-level retry loop must leave time to publish a terminal phase
    /// and clean up audio before iOS suspends the process.
    static let backgroundIntent = ElevenLabsRetryPolicy(
        maximumAttempts: 1,
        initialDelay: 0,
        maximumDelay: 0
    )

    let maximumAttempts: Int
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(maximumAttempts: Int, initialDelay: TimeInterval, maximumDelay: TimeInterval) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialDelay = initialDelay.isFinite ? max(0, initialDelay) : 0
        self.maximumDelay = maximumDelay.isFinite ? max(0, maximumDelay) : 0
    }

    func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter {
            return min(max(0, retryAfter), maximumDelay)
        }

        let exponent = Double(max(0, attempt - 1))
        return min(initialDelay * pow(2, exponent), maximumDelay)
    }
}

private actor ElevenLabsRequestLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
            return
        }
        activeCount = max(0, activeCount - 1)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// Speech uploads carry a custom `xi-api-key` header and a replayable body
/// stream. URLSession is not required to scrub custom credentials on a
/// cross-origin redirect, so SpeakPaste rejects every redirect before a second
/// request can be created. ElevenLabs' documented endpoint is final; a 3xx is
/// safer as a visible retryable failure than as credential/audio forwarding.
final class ElevenLabsNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class ElevenLabsClient: ElevenLabsClientProtocol, @unchecked Sendable {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let session: URLSession
    private let endpoint: URL
    private let retryPolicy: ElevenLabsRetryPolicy
    private let requestTimeout: TimeInterval
    private let limiter: ElevenLabsRequestLimiter
    private let sleeper: Sleeper
    private let now: @Sendable () -> Date
    private let redirectDelegate = ElevenLabsNoRedirectDelegate()

    /// A process can be terminated after URLSession cancellation but before
    /// this client's normal `defer` runs. At primary-app launch, remove only
    /// exact private multipart files created by this client. Holding an open,
    /// non-following descriptor and rechecking the inode keeps a swapped path,
    /// symlink, directory, or unrelated temp file out of scope.
    @discardableResult
    static func cleanupAbandonedMultipartUploads(
        in temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> Int {
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: temporaryDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return 0
        }

        var removedCount = 0
        for url in candidates where isGeneratedMultipartUploadName(url.lastPathComponent) {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { continue }

            var openedMetadata = stat()
            let isSafe = Darwin.fstat(descriptor, &openedMetadata) == 0
                && openedMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                && openedMetadata.st_uid == Darwin.getuid()
                && openedMetadata.st_nlink == 1
                && openedMetadata.st_mode & mode_t(0o777) == mode_t(0o600)
            guard isSafe else {
                Darwin.close(descriptor)
                continue
            }

            var currentMetadata = stat()
            let stillSameFile = url.path.withCString {
                Darwin.lstat($0, &currentMetadata) == 0
            }
                && currentMetadata.st_dev == openedMetadata.st_dev
                && currentMetadata.st_ino == openedMetadata.st_ino
                && currentMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                && currentMetadata.st_uid == Darwin.getuid()
                && currentMetadata.st_nlink == 1
                && currentMetadata.st_mode & mode_t(0o777) == mode_t(0o600)
            guard stillSameFile else {
                Darwin.close(descriptor)
                continue
            }

            let status = url.path.withCString { Darwin.unlink($0) }
            Darwin.close(descriptor)
            if status == 0 { removedCount += 1 }
        }
        return removedCount
    }

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
        retryPolicy: ElevenLabsRetryPolicy = .standard,
        requestTimeout: TimeInterval = 300,
        maximumConcurrentRequests: Int = 3,
        sleeper: @escaping Sleeper = { delay in
            try Task.checkCancellation()
            guard delay > 0 else {
                await Task.yield()
                return
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.endpoint = endpoint
        self.retryPolicy = retryPolicy
        self.requestTimeout = requestTimeout.isFinite ? max(1, requestTimeout) : 300
        limiter = ElevenLabsRequestLimiter(limit: maximumConcurrentRequests)
        self.sleeper = sleeper
        self.now = now
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool,
        keyterms: [String]
    ) async throws -> TranscriptionResult {
        // Admission covers multipart preparation, retries, and response decode.
        // Eight simultaneous twenty-minute WAVs must not each allocate/build a
        // request before discovering that only three may run.
        try await limiter.acquire()
        do {
            let result = try await transcribeAdmitted(
                audioURL: audioURL,
                apiKey: apiKey,
                language: language,
                cleanSpeech: cleanSpeech,
                keyterms: keyterms
            )
            await limiter.release()
            return result
        } catch {
            await limiter.release()
            throw error
        }
    }

    private func transcribeAdmitted(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool,
        keyterms: [String]
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let boundary = "SpeakPaste-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakPaste-upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")
        // Register cleanup before writing. A missing/unreadable source or task
        // cancellation can fail halfway through multipart preparation, and that
        // partial file contains private dictated audio just like a complete one.
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try Self.writeMultipartBody(
            to: bodyURL,
            boundary: boundary,
            audioURL: audioURL,
            // A local filename can contain a person's name, customer name, or
            // project title. Scribe only needs a useful extension, so do not
            // disclose the original basename in the multipart headers.
            filename: Self.uploadFilename(for: audioURL),
            audioContentType: Self.audioContentType(for: audioURL),
            languageCode: language.apiCode,
            cleanSpeech: cleanSpeech,
            keyterms: Self.validKeyterms(keyterms)
        )
        try Task.checkCancellation()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        // Imported files and the supported twenty-minute dictations can take
        // materially longer than a short voice note to upload and process.
        // Keep the request bounded, but do not manufacture a timeout while
        // Scribe is still doing the quality-first batch transcription.
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if
            let values = try? bodyURL.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        {
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        }

        var attempt = 0
        while attempt < retryPolicy.maximumAttempts {
            try Task.checkCancellation()
            attempt += 1

            let data: Data
            let response: URLResponse
            do {
                var attemptRequest = request
                guard let bodyStream = InputStream(url: bodyURL) else {
                    throw ElevenLabsClientError.invalidResponse
                }
                attemptRequest.httpBodyStream = bodyStream
                (data, response) = try await perform(attemptRequest)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if let clientError = error as? ElevenLabsClientError {
                    throw clientError
                }
                if let urlError = error as? URLError {
                    if urlError.code == .cancelled {
                        throw CancellationError()
                    }
                    if Self.isTransient(urlError), attempt < retryPolicy.maximumAttempts {
                        try await waitBeforeRetry(attempt: attempt, retryAfter: nil)
                        continue
                    }
                    throw ElevenLabsClientError.transport(
                        code: urlError.code,
                        message: Self.networkMessage(for: urlError)
                    )
                }
                throw ElevenLabsClientError.transport(
                    code: .unknown,
                    message: "The network request failed."
                )
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ElevenLabsClientError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let apiError = ElevenLabsClientError.api(
                    statusCode: httpResponse.statusCode,
                    message: Self.errorMessage(from: data)
                )
                if
                    Self.isTransient(statusCode: httpResponse.statusCode),
                    attempt < retryPolicy.maximumAttempts
                {
                    try await waitBeforeRetry(
                        attempt: attempt,
                        retryAfter: Self.retryAfter(from: httpResponse, now: now())
                    )
                    continue
                }
                throw apiError
            }

            guard let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else {
                throw ElevenLabsClientError.invalidResponse
            }
            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                throw ElevenLabsClientError.emptyTranscript
            }

            return TranscriptionResult(
                text: trimmedText,
                languageCode: result.languageCode,
                languageProbability: result.languageProbability
            )
        }

        throw ElevenLabsClientError.invalidResponse
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        return try await session.data(for: request, delegate: redirectDelegate)
    }

    private func waitBeforeRetry(attempt: Int, retryAfter: TimeInterval?) async throws {
        try Task.checkCancellation()
        let delay = retryPolicy.delay(afterAttempt: attempt, retryAfter: retryAfter)
        try await sleeper(delay)
        try Task.checkCancellation()
    }

    private static func isTransient(statusCode: Int) -> Bool {
        statusCode == 429 || [408, 500, 502, 503, 504].contains(statusCode)
    }

    private static func isTransient(_ error: URLError) -> Bool {
        ElevenLabsClientError.isConnectivityCode(error.code)
    }

    private static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            "The connection timed out."
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            "There is no internet connection."
        case .networkConnectionLost:
            "The connection dropped before transcription finished."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            "Could not connect to ElevenLabs."
        default:
            "The network request failed."
        }
    }

    private static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard
            let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else {
            return nil
        }

        if let seconds = TimeInterval(rawValue), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: rawValue) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func writeMultipartBody(
        to destinationURL: URL,
        boundary: String,
        audioURL: URL,
        filename: String,
        audioContentType: String,
        languageCode: String?,
        cleanSpeech: Bool,
        keyterms: [String]
    ) throws {
        _ = FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        func append(_ string: String) throws {
            try output.write(contentsOf: Data(string.utf8))
        }

        func appendField(name: String, value: String) throws {
            try append("--\(boundary)\r\n")
            try append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try append("\(value)\r\n")
        }

        try appendField(name: "model_id", value: "scribe_v2")
        try appendField(name: "no_verbatim", value: cleanSpeech ? "true" : "false")
        try appendField(name: "tag_audio_events", value: "false")
        if let languageCode {
            try appendField(name: "language_code", value: languageCode)
        }
        // Repeated `keyterms` fields match ElevenLabs' multipart array
        // encoding and bias recognition toward the user's own
        // names and jargon. This is the only lever the batch endpoint gives for
        // vocabulary, and it is context-aware rather than a forced substitution,
        // so an always-on list does not distort ordinary speech.
        for keyterm in keyterms {
            try appendField(name: "keyterms", value: keyterm)
        }

        let safeFilename = filename
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n")
        try append("Content-Type: \(audioContentType)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: audioURL)
        defer { try? input.close() }
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }
        try append("\r\n--\(boundary)--\r\n")
    }

    private static func audioContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "ogg": "audio/ogg"
        case "opus": "audio/opus"
        case "flac": "audio/flac"
        case "aac": "audio/aac"
        case "caf": "audio/x-caf"
        case "aif", "aiff": "audio/aiff"
        case "webm": "video/webm"
        default:
            UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }

    private static func uploadFilename(for url: URL) -> String {
        let sourceExtension = url.pathExtension.lowercased()
        let isSafeExtension = !sourceExtension.isEmpty
            && sourceExtension.count <= 12
            && sourceExtension.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
        guard isSafeExtension,
              let type = UTType(filenameExtension: sourceExtension),
              type.conforms(to: .audio) || type.conforms(to: .movie) else {
            return "recording.bin"
        }
        return "recording.\(sourceExtension)"
    }

    private static func isGeneratedMultipartUploadName(_ fileName: String) -> Bool {
        let prefix = "SpeakPaste-upload-"
        let suffix = ".multipart"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return false }
        let identifier = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        guard let uuid = UUID(uuidString: identifier) else { return false }
        return uuid.uuidString == identifier
    }

    /// Defense in depth for callers other than the macOS vocabulary store.
    /// Invalid keyterms make ElevenLabs reject the entire transcription, and
    /// control characters could also break the multipart field framing.
    private static func validKeyterms(_ candidates: [String]) -> [String] {
        let unsupported = CharacterSet(charactersIn: "<>{}[]\\")
            .union(.controlCharacters)
        var accepted: [String] = []
        var seen = Set<String>()

        for candidate in candidates {
            guard accepted.count < 1_000 else { break }
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !term.isEmpty,
                term.count < 50,
                term.split(whereSeparator: \.isWhitespace).count <= 5,
                term.rangeOfCharacter(from: unsupported) == nil
            else {
                continue
            }
            let duplicateKey = term.lowercased()
            guard seen.insert(duplicateKey).inserted else { continue }
            accepted.append(term)
        }
        return accepted
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return "The request failed."
        }

        if let detail = dictionary["detail"] as? String {
            return detail
        }
        if
            let detail = dictionary["detail"] as? [String: Any],
            let message = detail["message"] as? String
        {
            return message
        }
        if let message = dictionary["message"] as? String {
            return message
        }
        return "The request failed."
    }
}
