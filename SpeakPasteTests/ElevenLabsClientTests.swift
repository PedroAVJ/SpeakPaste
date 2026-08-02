import Foundation
import XCTest
@testable import SpeakPaste

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("No request handler configured")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ElevenLabsClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTranscribeSendsScribeV2CleanEnglishMultipartAndDecodesResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = URL(string: "https://example.test/speech-to-text")!
        let client = ElevenLabsClient(session: session, endpoint: endpoint)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
            XCTAssertTrue(body.contains("name=\"no_verbatim\"\r\n\r\ntrue"))
            XCTAssertTrue(body.contains("name=\"language_code\"\r\n\r\nen"))
            XCTAssertTrue(body.contains("name=\"file\"; filename="))

            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(
                #"{"text":"A clean transcript.","language_code":"en","language_probability":0.99}"#.utf8
            )
            return (response, data)
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakpaste-test-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: audioURL)
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

    func testTranscribeSurfacesSafeAPIErrorMessage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = ElevenLabsClient(
            session: URLSession(configuration: configuration),
            endpoint: URL(string: "https://example.test/speech-to-text")!
        )

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"detail":{"message":"Invalid API key"}}"#.utf8))
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakpaste-test-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: audioURL)
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
        }
    }
}
