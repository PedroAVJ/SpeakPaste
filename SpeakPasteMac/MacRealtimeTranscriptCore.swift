import Foundation

struct MacRealtimeScribeConfiguration: Sendable {
    let apiKey: String
    let languageCode: String?
    let cleanSpeech: Bool
    let keyterms: [String]
}

enum MacRealtimeConnectionPolicy {
    /// Long enough for an intentional pause; the actor's explicit ten-second
    /// handshake deadline owns connection setup instead of URLRequest.
    static let requestTimeout: TimeInterval = 120
    /// A pong keeps Foundation's inbound-data inactivity timer alive without
    /// forcing transcription commits more frequently than Scribe recommends.
    static let pingInterval: Duration = .seconds(10)
}

/// Keeps manual-commit sessions below the service's automatic commit window.
/// The realtime stream is mono 16-bit PCM at 16 kHz, so 25 seconds is exactly
/// 800,000 bytes. A chunk that reaches or crosses that boundary carries the
/// commit flag; the counter restarts only after that send succeeds.
enum MacRealtimeCommitCadence {
    static let intervalByteCount = 25 * 16_000 * MemoryLayout<Int16>.size

    static func shouldCommit(
        bytesSinceLastCommit: Int,
        nextChunkByteCount: Int
    ) -> Bool {
        guard bytesSinceLastCommit >= 0, nextChunkByteCount > 0 else {
            return false
        }
        return bytesSinceLastCommit + nextChunkByteCount >= intervalByteCount
    }
}

struct MacRealtimeTranscriptSnapshot: Equatable, Sendable {
    let committedSegments: [String]
    let partialText: String

    var displayText: String {
        Self.joined(committedSegments + (partialText.isEmpty ? [] : [partialText]))
    }

    var committedText: String { Self.joined(committedSegments) }

    private static func joined(_ segments: [String]) -> String {
        var result = ""
        let attachingMarks = CharacterSet(charactersIn: ",.!?:;%)]}\u{201D}\u{2019}\u{00BB}\u{203A}")
        for rawSegment in segments {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }
            guard !result.isEmpty else {
                result = segment
                continue
            }
            let firstScalar = segment.unicodeScalars.first
            if result.last?.isWhitespace == true
                || firstScalar.map(attachingMarks.contains) == true {
                result += segment
            } else {
                result += " " + segment
            }
        }
        return result
    }
}

struct MacRealtimeTranscriptUpdate: Equatable, Sendable {
    let revision: UInt64
    let snapshot: MacRealtimeTranscriptSnapshot
}

enum MacRealtimeTranscriptEffect: Equatable, Sendable {
    case sessionStarted
    case textChanged(MacRealtimeTranscriptSnapshot)
    case committed(MacRealtimeTranscriptSnapshot)
    case metadata
}

enum MacRealtimeScribeError: LocalizedError, Sendable {
    case invalidEndpoint
    case invalidResponse
    case handshakeTimedOut
    case commitTimedOut
    case socketClosed
    case audioBackpressure
    case noConvertedAudio
    case service(type: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "SpeakPaste could not create the ElevenLabs realtime endpoint."
        case .invalidResponse:
            "ElevenLabs realtime returned an unreadable response."
        case .handshakeTimedOut:
            "ElevenLabs realtime did not start the session in time."
        case .commitTimedOut:
            "ElevenLabs realtime did not finalize the trailing speech in time."
        case .socketClosed:
            "The ElevenLabs realtime connection closed unexpectedly."
        case .audioBackpressure:
            "The realtime connection could not keep up with microphone audio."
        case .noConvertedAudio:
            "The microphone produced no realtime PCM, so SpeakPaste is using the saved WAV."
        case let .service(_, message):
            "ElevenLabs realtime: \(message)"
        }
    }
}

/// Reducer for the official partial/committed event contract. Partial text is a
/// complete replacement for the current tail. Every committed frame is an
/// append-once segment; equal text in two frames is valid repetition and is not
/// semantically deduplicated.
struct MacRealtimeTranscriptAssembler: Sendable {
    private(set) var sessionStarted = false
    private(set) var committedSegments: [String] = []
    private(set) var partialText = ""
    private(set) var commitEventCount = 0

    var snapshot: MacRealtimeTranscriptSnapshot {
        MacRealtimeTranscriptSnapshot(
            committedSegments: committedSegments,
            partialText: partialText
        )
    }

    mutating func consume(_ data: Data) throws -> MacRealtimeTranscriptEffect {
        let event: Event
        do {
            event = try JSONDecoder().decode(Event.self, from: data)
        } catch {
            throw MacRealtimeScribeError.invalidResponse
        }

        if let message = event.error,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MacRealtimeScribeError.service(
                type: event.messageType,
                message: message
            )
        }
        if Self.errorMessageTypes.contains(event.messageType) {
            throw MacRealtimeScribeError.service(
                type: event.messageType,
                message: event.message ?? "The realtime session failed."
            )
        }

        switch event.messageType {
        case "session_started":
            if let config = event.config {
                guard
                    config.modelID == nil || config.modelID == "scribe_v2_realtime",
                    config.audioFormat == nil || config.audioFormat == "pcm_16000",
                    config.sampleRate == nil || config.sampleRate == 16_000
                else {
                    throw MacRealtimeScribeError.invalidResponse
                }
            }
            sessionStarted = true
            return .sessionStarted

        case "partial_transcript":
            partialText = event.text ?? ""
            return .textChanged(snapshot)

        case "final_transcript":
            // The low-level schema exposes this event, while the public event
            // guide and SDK make committed_transcript authoritative. Use it only
            // as a better tentative tail and never append it to history.
            partialText = event.text ?? ""
            return .textChanged(snapshot)

        case "committed_transcript":
            let text = (event.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { committedSegments.append(text) }
            partialText = ""
            commitEventCount += 1
            return .committed(snapshot)

        case "committed_transcript_with_timestamps",
             "committed_transcript_entities",
             "final_transcript_with_timestamps":
            // These repeat transcript text with metadata. Appending them would
            // duplicate a committed segment.
            return .metadata

        default:
            return .metadata
        }
    }

    private struct Event: Decodable {
        let messageType: String
        let text: String?
        let error: String?
        let message: String?
        let config: SessionConfiguration?

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
            case text
            case error
            case message
            case config
        }
    }

    private struct SessionConfiguration: Decodable {
        let audioFormat: String?
        let modelID: String?
        let sampleRate: Int?

        enum CodingKeys: String, CodingKey {
            case audioFormat = "audio_format"
            case modelID = "model_id"
            case sampleRate = "sample_rate"
        }
    }

    private static let errorMessageTypes: Set<String> = [
        "error",
        "auth_error",
        "quota_exceeded",
        "commit_throttled",
        "transcriber_error",
        "unaccepted_terms",
        "rate_limited",
        "input_error",
        "queue_overflow",
        "resource_exhausted",
        "session_time_limit_exceeded",
        "chunk_size_exceeded",
        "insufficient_audio_activity",
    ]
}

enum MacRealtimeScribeRequestBuilder {
    static let endpoint = URL(
        string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    )!

    static func request(
        configuration: MacRealtimeScribeConfiguration,
        endpoint: URL = endpoint
    ) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MacRealtimeScribeError.invalidEndpoint
        }
        var items = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "no_verbatim", value: configuration.cleanSpeech ? "true" : "false"),
        ]
        if let languageCode = configuration.languageCode {
            items.append(URLQueryItem(name: "language_code", value: languageCode))
        }
        // Realtime has a deliberately smaller contract than batch: at most 50
        // keyterms, each no longer than 20 characters. The model supplies
        // already prioritized context first, but the request builder enforces
        // the service boundary again.
        let validKeyterms: [URLQueryItem] = configuration.keyterms.compactMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 20 else { return nil }
            return URLQueryItem(name: "keyterms", value: trimmed)
        }
        items.append(contentsOf: validKeyterms.prefix(50))
        components.queryItems = items
        guard let url = components.url else {
            throw MacRealtimeScribeError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = MacRealtimeConnectionPolicy.requestTimeout
        request.setValue(configuration.apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    static func audioMessage(data: Data, commit: Bool) throws -> String {
        let object: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": data.base64EncodedString(),
            "commit": commit,
            "sample_rate": 16_000,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: encoded, encoding: .utf8) else {
            throw MacRealtimeScribeError.invalidResponse
        }
        return string
    }
}
