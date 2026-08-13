import Foundation
import XCTest
@testable import SpeakPaste

final class MacAudioPolicyTests: XCTestCase {
    func testDirectVoiceRouteRequiresOneFullDuplexSelectedDevice() {
        XCTAssertEqual(
            MacVoiceProcessingRoutePlan.choose(
                selectedInputUID: "same",
                selectedInputChannelCount: 1,
                currentOutputUID: "same",
                currentOutputChannelCount: 2
            ),
            .directDevice
        )
        XCTAssertNil(
            MacVoiceProcessingRoutePlan.choose(
                selectedInputUID: "same",
                selectedInputChannelCount: 0,
                currentOutputUID: "same",
                currentOutputChannelCount: 2
            )
        )
        XCTAssertNil(
            MacVoiceProcessingRoutePlan.choose(
                selectedInputUID: "same",
                selectedInputChannelCount: 1,
                currentOutputUID: "same",
                currentOutputChannelCount: 0
            )
        )
    }

    func testDifferentOutputAlwaysUsesPrivateAggregate() {
        XCTAssertEqual(
            MacVoiceProcessingRoutePlan.choose(
                selectedInputUID: "continuity-input",
                selectedInputChannelCount: 1,
                currentOutputUID: "full-duplex-airpods",
                currentOutputChannelCount: 2
            ),
            .privateAggregate
        )
    }

    func testChannelMapCanReferenceOnlyLeadingSelectedInputChannels() {
        let map = MacSelectedInputChannelMap.make(
            selectedInputChannelCount: 2,
            destinationChannelCount: 5
        )
        XCTAssertEqual(map, [0, 1, 0, 1, 0])
        XCTAssertTrue(map?.allSatisfy { $0 < 2 } == true)
        XCTAssertNil(
            MacSelectedInputChannelMap.make(
                selectedInputChannelCount: 0,
                destinationChannelCount: 1
            )
        )
    }

    func testReadinessRequiresAudibleInputInAdditionToSteadyBuffers() {
        XCTAssertFalse(MacAudibleReadinessPolicy.isAudible(rms: 0))
        XCTAssertFalse(MacAudibleReadinessPolicy.isAudible(rms: .nan))
        XCTAssertTrue(MacAudibleReadinessPolicy.isAudible(rms: 0.01))
        XCTAssertFalse(
            MacAudibleReadinessPolicy.isReady(
                steadyWindows: 6,
                audibleWindows: 0,
                requiredSteadyWindows: 6
            )
        )
        XCTAssertTrue(
            MacAudibleReadinessPolicy.isReady(
                steadyWindows: 6,
                audibleWindows: 1,
                requiredSteadyWindows: 6
            )
        )
    }

    func testVoiceIsolationPreferenceRequiresVoiceIsolationActive() {
        XCTAssertFalse(
            MacMicrophoneModeReadinessPolicy.permitsRecording(
                preferred: .voiceIsolation,
                active: .standard
            )
        )
        XCTAssertTrue(
            MacMicrophoneModeReadinessPolicy.permitsRecording(
                preferred: .voiceIsolation,
                active: .voiceIsolation
            )
        )
        XCTAssertTrue(
            MacMicrophoneModeReadinessPolicy.permitsRecording(
                preferred: .standard,
                active: .wideSpectrum
            )
        )
    }

    func testLateDuckingEnableCannotOutliveItsRecording() {
        let activation = UUID()
        XCTAssertTrue(
            MacOtherAudioDuckingLifecyclePolicy.shouldKeepActivation(
                activationID: activation,
                currentActivationID: activation,
                isRecording: true
            )
        )
        XCTAssertFalse(
            MacOtherAudioDuckingLifecyclePolicy.shouldKeepActivation(
                activationID: activation,
                currentActivationID: nil,
                isRecording: true
            )
        )
        XCTAssertFalse(
            MacOtherAudioDuckingLifecyclePolicy.shouldKeepActivation(
                activationID: activation,
                currentActivationID: activation,
                isRecording: false
            )
        )
    }
}
