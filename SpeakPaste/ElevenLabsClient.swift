import Foundation

protocol ElevenLabsClientProtocol: Sendable {
    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool
    ) async throws -> TranscriptionResult
}

enum ElevenLabsClientError: LocalizedError, Equatable {
    case invalidResponse
    case api(statusCode: Int, message: String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "ElevenLabs returned an unreadable response."
        case let .api(statusCode, message):
            "ElevenLabs error \(statusCode): \(message)"
        case .emptyTranscript:
            "ElevenLabs did not hear any speech. Try again a little closer to the microphone."
        }
    }
}

final class ElevenLabsClient: ElevenLabsClientProtocol, @unchecked Sendable {
    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool
    ) async throws -> TranscriptionResult {
        let boundary = "SpeakPaste-\(UUID().uuidString)"
        let audioData = try Data(contentsOf: audioURL)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            audioContentType: Self.audioContentType(for: audioURL),
            languageCode: language.apiCode,
            cleanSpeech: cleanSpeech
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ElevenLabsClientError.api(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        let result = try JSONDecoder().decode(TranscriptionResult.self, from: data)
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

    private static func multipartBody(
        boundary: String,
        audioData: Data,
        filename: String,
        audioContentType: String,
        languageCode: String?,
        cleanSpeech: Bool
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        appendField(name: "model_id", value: "scribe_v2")
        appendField(name: "no_verbatim", value: cleanSpeech ? "true" : "false")
        appendField(name: "tag_audio_events", value: "false")
        if let languageCode {
            appendField(name: "language_code", value: languageCode)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(audioContentType)\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func audioContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        default: "audio/mp4"
        }
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
