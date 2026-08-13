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

    func testPrivateAggregateExposesOnlySelectedInputDirection() throws {
        let plan = try XCTUnwrap(
            MacVoiceProcessingAggregateChannelPlan.make(
                selectedInputChannels: 1,
                currentOutputChannels: 2
            )
        )
        XCTAssertEqual(plan.selectedInputChannels, 1)
        XCTAssertEqual(plan.selectedInputOutputChannels, 0)
        XCTAssertEqual(plan.currentOutputInputChannels, 0)
        XCTAssertEqual(plan.currentOutputChannels, 2)
        XCTAssertTrue(
            plan.matchesAggregate(inputChannels: 1, outputChannels: 2)
        )
        XCTAssertFalse(
            plan.matchesAggregate(inputChannels: 2, outputChannels: 2),
            "A full-duplex output microphone must not widen capture"
        )
        XCTAssertNil(
            MacVoiceProcessingAggregateChannelPlan.make(
                selectedInputChannels: 0,
                currentOutputChannels: 2
            )
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

    func testCompetingMediaFadeUsesSmoothMonotonicEndpoints() {
        let down = stride(from: 0.0, through: 1.0, by: 0.05).map {
            MacCompetingMediaFadePolicy.volume(
                from: 0.8,
                to: MacCompetingMediaFadePolicy.quietVolume(for: 0.8),
                progress: $0
            )
        }
        XCTAssertEqual(down.first ?? -1, 0.8, accuracy: 0.0001)
        let quiet = MacCompetingMediaFadePolicy.quietVolume(for: 0.8)
        XCTAssertEqual(down.last ?? -1, quiet, accuracy: 0.0001)
        XCTAssertTrue(zip(down, down.dropFirst()).allSatisfy { $0 >= $1 })

        let up = stride(from: 0.0, through: 1.0, by: 0.05).map {
            MacCompetingMediaFadePolicy.volume(
                from: quiet,
                to: 0.8,
                progress: $0
            )
        }
        XCTAssertTrue(zip(up, up.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertEqual(up.last ?? -1, 0.8, accuracy: 0.0001)
    }

    func testCompetingMediaFadeHasGentleEdgesAndRespectsUserChanges() {
        XCTAssertEqual(MacCompetingMediaFadePolicy.easedProgress(0), 0)
        XCTAssertEqual(MacCompetingMediaFadePolicy.easedProgress(1), 1)
        XCTAssertLessThan(MacCompetingMediaFadePolicy.easedProgress(0.05), 0.01)
        XCTAssertGreaterThan(MacCompetingMediaFadePolicy.easedProgress(0.95), 0.99)
        XCTAssertTrue(
            MacCompetingMediaFadePolicy.stillOwns(
                current: 0.201,
                lastWritten: 0.20
            )
        )
        XCTAssertFalse(
            MacCompetingMediaFadePolicy.stillOwns(
                current: 0.30,
                lastWritten: 0.20
            )
        )
    }
}
