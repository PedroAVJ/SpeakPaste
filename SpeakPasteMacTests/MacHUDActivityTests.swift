import Combine
import XCTest
@testable import SpeakPaste

final class MacHUDActivityTests: XCTestCase {
    func testTranscribingRemainsVisibleUntilEveryRequestFinishes() {
        XCTAssertEqual(
            MacHUDActivity.resolve(capture: .inactive, inFlightTranscriptionCount: 2),
            .transcribing
        )
        XCTAssertEqual(
            MacHUDActivity.resolve(capture: .inactive, inFlightTranscriptionCount: 1),
            .transcribing
        )
        XCTAssertEqual(
            MacHUDActivity.resolve(capture: .inactive, inFlightTranscriptionCount: 0),
            .hidden
        )
    }

    func testCaptureStateTakesPriorityOverBackgroundTranscription() {
        XCTAssertEqual(
            MacHUDActivity.resolve(capture: .connecting, inFlightTranscriptionCount: 1),
            .connecting
        )
        XCTAssertEqual(
            MacHUDActivity.resolve(capture: .listening, inFlightTranscriptionCount: 1),
            .listening
        )
        XCTAssertEqual(
            MacHUDActivity.resolve(capture: .releasing, inFlightTranscriptionCount: 1),
            .releasing
        )
    }

    func testNegativeCountCannotCreateAVisibleTranscriptionState() {
        XCTAssertEqual(
            MacHUDActivity.resolve(capture: .inactive, inFlightTranscriptionCount: -1),
            .hidden
        )
    }

    func testActivityPublisherReactsWhenOnlyTranscriptionCountChanges() {
        let capture = CurrentValueSubject<MacHUDCaptureActivity, Never>(.inactive)
        let count = CurrentValueSubject<Int, Never>(0)
        var received: [MacHUDActivity] = []
        let observation = MacHUDActivity.publisher(
            capture: capture,
            inFlightTranscriptionCount: count
        )
        .sink { received.append($0) }

        count.send(1)
        count.send(2)
        capture.send(.listening)
        capture.send(.inactive)
        count.send(0)

        XCTAssertEqual(
            received,
            [.hidden, .transcribing, .listening, .transcribing, .hidden]
        )
        withExtendedLifetime(observation) {}
    }
}
