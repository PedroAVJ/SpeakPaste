import XCTest
@testable import SpeakPaste

final class MacTranscriptionWorkloadTests: XCTestCase {
    func testEmptyWorkloadHasNoSnapshotAndIgnoresUnknownCompletion() {
        var workload = MacTranscriptionWorkload()

        XCTAssertNil(workload.snapshot(at: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(workload.finish(id: UUID()), .ignored)
        XCTAssertTrue(workload.isEmpty)
    }

    func testEstimateUsesRecordingDurationButNeverPretendsToBeComplete() {
        let expected = MacTranscriptionWorkload.expectedDuration(for: 20)

        XCTAssertEqual(expected, 4, accuracy: 0.000_001)
        XCTAssertEqual(
            MacTranscriptionWorkload.estimatedFraction(
                recordingDuration: 20,
                elapsed: 0
            ),
            0.08,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MacTranscriptionWorkload.estimatedFraction(
                recordingDuration: 20,
                elapsed: expected
            ),
            0.826_925,
            accuracy: 0.000_001
        )
        XCTAssertLessThan(
            MacTranscriptionWorkload.estimatedFraction(
                recordingDuration: 20,
                elapsed: 60
            ),
            1
        )
    }

    func testSnapshotProgressesMonotonicallyForTheCurrentHead() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let id = UUID()
        var workload = MacTranscriptionWorkload()
        XCTAssertTrue(workload.start(id: id, duration: 40, at: startedAt))

        let initial = try XCTUnwrap(workload.snapshot(at: startedAt))
        let middle = try XCTUnwrap(
            workload.snapshot(at: startedAt.addingTimeInterval(4))
        )
        let late = try XCTUnwrap(
            workload.snapshot(at: startedAt.addingTimeInterval(30))
        )

        XCTAssertEqual(initial.headID, id)
        XCTAssertEqual(initial.activeCount, 1)
        XCTAssertLessThan(initial.estimatedFraction, middle.estimatedFraction)
        XCTAssertLessThan(middle.estimatedFraction, late.estimatedFraction)
        XCTAssertLessThanOrEqual(late.estimatedFraction, 0.92)
    }

    func testOldestOutstandingAttemptDrivesConcurrentProgress() throws {
        let firstID = UUID()
        let secondID = UUID()
        let base = Date(timeIntervalSince1970: 2_000)
        var workload = MacTranscriptionWorkload()
        workload.start(id: secondID, duration: 10, at: base.addingTimeInterval(1))
        workload.start(id: firstID, duration: 30, at: base)

        let initial = try XCTUnwrap(
            workload.snapshot(at: base.addingTimeInterval(2))
        )
        XCTAssertEqual(initial.headID, firstID)
        XCTAssertEqual(initial.activeCount, 2)

        XCTAssertEqual(
            workload.finish(id: secondID),
            .moreRemain(nextHeadID: firstID)
        )
        XCTAssertEqual(workload.snapshot(at: base.addingTimeInterval(3))?.headID, firstID)
        XCTAssertEqual(workload.finish(id: firstID), .becameIdle)
        XCTAssertNil(workload.snapshot(at: base.addingTimeInterval(4)))
    }

    func testDuplicateStartDoesNotInflateCountAndFinishedIDCanRetry() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 3_000)
        var workload = MacTranscriptionWorkload()

        XCTAssertTrue(workload.start(id: id, duration: 10, at: start))
        XCTAssertFalse(workload.start(id: id, duration: 20, at: start))
        XCTAssertEqual(workload.activeCount, 1)
        XCTAssertEqual(workload.finish(id: id), .becameIdle)
        XCTAssertTrue(
            workload.start(
                id: id,
                duration: 20,
                at: start.addingTimeInterval(10)
            )
        )
        XCTAssertEqual(workload.activeCount, 1)
    }

    func testFinishingOlderAttemptKeepsOverlappingRetryVisible() throws {
        // A connectivity retry can begin for one durable recording before the
        // failed URLSession task has finished unwinding. Each network attempt
        // therefore needs its own workload identity.
        let failedAttemptID = UUID()
        let retryAttemptID = UUID()
        let start = Date(timeIntervalSince1970: 3_500)
        var workload = MacTranscriptionWorkload()

        workload.start(id: failedAttemptID, duration: 12, at: start)
        workload.start(
            id: retryAttemptID,
            duration: 12,
            at: start.addingTimeInterval(1)
        )

        XCTAssertEqual(
            workload.finish(id: failedAttemptID),
            .moreRemain(nextHeadID: retryAttemptID)
        )
        let snapshot = try XCTUnwrap(
            workload.snapshot(at: start.addingTimeInterval(2))
        )
        XCTAssertEqual(snapshot.headID, retryAttemptID)
        XCTAssertEqual(snapshot.activeCount, 1)
    }

    func testInvalidDurationsAndClockSkewRemainAtSafeInitialEstimate() throws {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 4_000)
        var workload = MacTranscriptionWorkload()
        workload.start(id: id, duration: .infinity, at: start)

        XCTAssertEqual(
            MacTranscriptionWorkload.expectedDuration(for: -.infinity),
            2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                workload.snapshot(at: start.addingTimeInterval(-5))
            ).estimatedFraction,
            0.08,
            accuracy: 0.000_001
        )
    }
}
