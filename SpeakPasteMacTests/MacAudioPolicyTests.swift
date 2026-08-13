import Foundation
import XCTest
@testable import SpeakPaste

final class MacAudioPolicyTests: XCTestCase {
    func testCompetingMediaAttenuationKeepsBackgroundAudible() {
        XCTAssertEqual(MacCompetingMediaFadePolicy.attenuationDecibels, 12)
        XCTAssertEqual(
            pow(10, -MacCompetingMediaFadePolicy.attenuationDecibels / 20),
            0.25,
            accuracy: 0.002
        )
    }

    func testCompetingMediaFadeUsesSmoothMonotonicEndpoints() {
        let down = stride(from: 0.0, through: 1.0, by: 0.05).map {
            MacCompetingMediaFadePolicy.decibels(
                from: -4,
                to: -20,
                progress: $0
            )
        }
        XCTAssertEqual(down.first ?? 0, -4, accuracy: 0.0001)
        XCTAssertEqual(down.last ?? 0, -20, accuracy: 0.0001)
        XCTAssertTrue(zip(down, down.dropFirst()).allSatisfy { $0 >= $1 })

        let up = stride(from: 0.0, through: 1.0, by: 0.05).map {
            MacCompetingMediaFadePolicy.decibels(
                from: -20,
                to: -4,
                progress: $0
            )
        }
        XCTAssertTrue(zip(up, up.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertEqual(up.last ?? 0, -4, accuracy: 0.0001)
    }

    func testCompetingMediaFadeHasGentleEdgesAndRespectsUserChanges() {
        XCTAssertEqual(MacCompetingMediaFadePolicy.easedProgress(0), 0)
        XCTAssertEqual(MacCompetingMediaFadePolicy.easedProgress(1), 1)
        XCTAssertLessThan(MacCompetingMediaFadePolicy.easedProgress(0.05), 0.01)
        XCTAssertGreaterThan(MacCompetingMediaFadePolicy.easedProgress(0.95), 0.99)
        XCTAssertTrue(
            MacCompetingMediaFadePolicy.stillOwns(
                current: 0.2005,
                lastWritten: 0.20
            )
        )
        XCTAssertFalse(
            MacCompetingMediaFadePolicy.stillOwns(
                current: 0.202,
                lastWritten: 0.20
            )
        )
    }

    func testCompetingMediaLeaseRecognizesOnlyDurableWriteStates() {
        let lease = MacCompetingMediaStoredLease(
            deviceUID: "output",
            original: [0: 0.80, 1: 0.70],
            committed: [0: 0.30, 1: 0.25],
            pendingWrite: MacCompetingMediaPendingWrite(
                from: [0: 0.30, 1: 0.25],
                to: [0: 0.20, 1: 0.15],
                kind: .fade
            )
        )

        XCTAssertTrue(
            MacCompetingMediaLeasePolicy.ownsLiveState(
                current: [0: 0.30, 1: 0.25],
                lease: lease
            )
        )
        XCTAssertTrue(
            MacCompetingMediaLeasePolicy.ownsLiveState(
                current: [0: 0.20, 1: 0.25],
                lease: lease
            ),
            "A crash halfway through a multi-channel write is recoverable"
        )
        XCTAssertFalse(
            MacCompetingMediaLeasePolicy.ownsLiveState(
                current: [0: 0.09, 1: 0.15],
                lease: lease
            ),
            "A value beyond the bounded hardware realization must end ownership"
        )
    }

    func testCompetingMediaRecoveryRecognizesPartialRestoreButNotUserChoice() {
        let lease = MacCompetingMediaStoredLease(
            deviceUID: "output",
            original: [0: 0.80, 1: 0.70],
            committed: [0: 0.30, 1: 0.25],
            pendingWrite: MacCompetingMediaPendingWrite(
                from: [0: 0.20, 1: 0.25],
                to: [0: 0.80, 1: 0.70],
                kind: .restore
            )
        )

        XCTAssertTrue(
            MacCompetingMediaLeasePolicy.ownsRecoverableState(
                current: [0: 0.80, 1: 0.25],
                lease: lease
            )
        )
        XCTAssertTrue(
            MacCompetingMediaLeasePolicy.ownsRecoverableState(
                current: [0: 0.20, 1: 0.70],
                lease: lease
            ),
            "Either channel may be the one restored before a crash"
        )
        XCTAssertTrue(
            MacCompetingMediaLeasePolicy.ownsRecoverableState(
                current: lease.original,
                lease: lease
            )
        )
        XCTAssertFalse(
            MacCompetingMediaLeasePolicy.ownsRecoverableState(
                current: [0: 0.42, 1: 0.25],
                lease: lease
            )
        )
    }

    func testPendingWriteAcceptsBoundedNearestHardwareRounding() {
        let pending = MacCompetingMediaPendingWrite(
            from: [0: 0.30, 1: 0.25],
            to: [0: 0.24, 1: 0.20],
            kind: .fade
        )

        XCTAssertTrue(
            MacCompetingMediaLeasePolicy.matchesPendingRealization(
                [0: 0.20, 1: 0.175],
                pending: pending
            ),
            "Nearest hardware steps may land just past the requested scalar"
        )
        XCTAssertFalse(
            MacCompetingMediaLeasePolicy.matchesPendingRealization(
                [0: 0.17, 1: 0.175],
                pending: pending
            ),
            "A value farther from the request than the known selectable start is external"
        )

        let rising = MacCompetingMediaPendingWrite(
            from: [0: 0.60],
            to: [0: 0.65],
            kind: .restore
        )
        XCTAssertTrue(
            MacCompetingMediaLeasePolicy.matchesPendingRealization(
                [0: 0.69],
                pending: rising
            )
        )
        XCTAssertFalse(
            MacCompetingMediaLeasePolicy.matchesPendingRealization(
                [0: 0.71],
                pending: rising
            )
        )
    }

    func testCompetingMediaLeaseStoreRoundTripsPendingWriteAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpeakPasteMediaLeaseTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacCompetingMediaLeaseStore(
            applicationSupportDirectory: directory
        )
        var lease = MacCompetingMediaStoredLease(
            deviceUID: "output",
            original: [0: 0.80, 1: 0.70],
            committed: [0: 0.30, 1: 0.25]
        )

        try store.save(lease)
        XCTAssertEqual(try store.load(), lease)

        lease.pendingWrite = MacCompetingMediaPendingWrite(
            from: lease.committed,
            to: [0: 0.20, 1: 0.15],
            kind: .fade
        )
        try store.save(lease)
        XCTAssertEqual(try store.load(), lease)

        try store.remove()
        XCTAssertNil(try store.load())
    }
}
