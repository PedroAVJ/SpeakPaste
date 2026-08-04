import XCTest
@testable import SpeakPaste

final class MacRealtimeTranscriptCoreTests: XCTestCase {
    func testPartialTranscriptFramesReplaceTheTentativeTail() throws {
        var assembler = MacRealtimeTranscriptAssembler()

        XCTAssertEqual(
            try assembler.consume(event("session_started", config: [
                "model_id": "scribe_v2_realtime",
                "audio_format": "pcm_16000",
                "sample_rate": 16_000,
            ])),
            .sessionStarted
        )
        XCTAssertEqual(
            try assembler.consume(event("partial_transcript", text: "hel")),
            .textChanged(
                MacRealtimeTranscriptSnapshot(
                    committedSegments: [],
                    partialText: "hel"
                )
            )
        )
        XCTAssertEqual(
            try assembler.consume(event("partial_transcript", text: "hello")),
            .textChanged(
                MacRealtimeTranscriptSnapshot(
                    committedSegments: [],
                    partialText: "hello"
                )
            )
        )
        XCTAssertEqual(assembler.snapshot.displayText, "hello")
    }

    func testCommittedFramesAppendOnceWhileMetadataDoesNotDuplicateText() throws {
        var assembler = MacRealtimeTranscriptAssembler()
        _ = try assembler.consume(event("partial_transcript", text: "hello"))

        XCTAssertEqual(
            try assembler.consume(event("committed_transcript", text: " hello ")),
            .committed(
                MacRealtimeTranscriptSnapshot(
                    committedSegments: ["hello"],
                    partialText: ""
                )
            )
        )
        XCTAssertEqual(
            try assembler.consume(
                event("committed_transcript_with_timestamps", text: "hello")
            ),
            .metadata
        )
        XCTAssertEqual(assembler.snapshot.committedText, "hello")

        // Equal committed frames can represent intentional repeated speech and
        // are each authoritative; only metadata mirrors are ignored.
        _ = try assembler.consume(event("committed_transcript", text: "hello"))
        XCTAssertEqual(assembler.snapshot.committedText, "hello hello")
        XCTAssertEqual(assembler.commitEventCount, 2)
    }

    func testServiceErrorFrameFailsWithItsMessage() throws {
        var assembler = MacRealtimeTranscriptAssembler()

        XCTAssertThrowsError(
            try assembler.consume(
                event("rate_limited", message: "Retry after a moment.")
            )
        ) { error in
            guard case let MacRealtimeScribeError.service(type, message) = error else {
                return XCTFail("Expected a realtime service error, got \(error)")
            }
            XCTAssertEqual(type, "rate_limited")
            XCTAssertEqual(message, "Retry after a moment.")
        }
    }

    func testRequestUsesRealtimeQueryAndHeaderWithoutPuttingKeyInURL() throws {
        let secret = "test-api-key-that-must-stay-out-of-the-url"
        let terms = [String(repeating: "x", count: 21)]
            + (0..<51).map { "term\($0)" }
        let request = try MacRealtimeScribeRequestBuilder.request(
            configuration: MacRealtimeScribeConfiguration(
                apiKey: secret,
                languageCode: "en",
                cleanSpeech: true,
                keyterms: terms
            )
        )
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(grouping: components.queryItems ?? [], by: \URLQueryItem.name)

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.elevenlabs.io")
        XCTAssertEqual(query["model_id"]?.map(\.value), ["scribe_v2_realtime"])
        XCTAssertEqual(query["audio_format"]?.map(\.value), ["pcm_16000"])
        XCTAssertEqual(query["commit_strategy"]?.map(\.value), ["manual"])
        XCTAssertEqual(query["no_verbatim"]?.map(\.value), ["true"])
        XCTAssertEqual(query["language_code"]?.map(\.value), ["en"])
        XCTAssertEqual(query["keyterms"]?.count, 50)
        XCTAssertEqual(query["keyterms"]?.first?.value, "term0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), secret)
        XCTAssertFalse(url.absoluteString.contains(secret))
    }

    func testCommitAudioMessageUsesEmptyPCMChunkAndRequiredSampleRate() throws {
        let message = try MacRealtimeScribeRequestBuilder.audioMessage(
            data: Data(),
            commit: true
        )
        let data = try XCTUnwrap(message.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(object["audio_base_64"] as? String, "")
        XCTAssertEqual(object["commit"] as? Bool, true)
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
    }

    func testManualCommitCadenceCrossesAtTwentyFiveSecondsOfPCM() {
        XCTAssertEqual(MacRealtimeCommitCadence.intervalByteCount, 800_000)
        XCTAssertFalse(
            MacRealtimeCommitCadence.shouldCommit(
                bytesSinceLastCommit: 793_599,
                nextChunkByteCount: 6_400
            )
        )
        XCTAssertTrue(
            MacRealtimeCommitCadence.shouldCommit(
                bytesSinceLastCommit: 793_600,
                nextChunkByteCount: 6_400
            )
        )
    }

    private func event(
        _ messageType: String,
        text: String? = nil,
        message: String? = nil,
        config: [String: Any]? = nil
    ) throws -> Data {
        var object: [String: Any] = ["message_type": messageType]
        if let text { object["text"] = text }
        if let message { object["message"] = message }
        if let config { object["config"] = config }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
