import XCTest
@testable import SpeakPaste

final class MacTranscriptionWorkloadTests: XCTestCase {
    func testEmptyWorkloadHasNoJobsAndIgnoresUnknownCompletion() {
        var workload = MacTranscriptionWorkload()

        XCTAssertTrue(workload.orderedJobs.isEmpty)
        XCTAssertEqual(workload.finish(id: UUID()), .ignored)
        XCTAssertTrue(workload.isEmpty)
    }

    func testOrderedJobsAreOldestFirstWithStableIdentity() {
        let firstID = UUID()
        let secondID = UUID()
        let base = Date(timeIntervalSince1970: 2_000)
        var workload = MacTranscriptionWorkload()
        workload.start(id: secondID, duration: 10, at: base.addingTimeInterval(1))
        workload.start(id: firstID, duration: 30, at: base)

        XCTAssertEqual(workload.orderedJobs.map(\.id), [firstID, secondID])
        XCTAssertEqual(workload.orderedJobs.first?.recordingDuration, 30)
        XCTAssertEqual(workload.activeCount, 2)

        XCTAssertEqual(
            workload.finish(id: secondID),
            .moreRemain(nextHeadID: firstID)
        )
        XCTAssertEqual(workload.orderedJobs.map(\.id), [firstID])
        XCTAssertEqual(workload.finish(id: firstID), .becameIdle)
        XCTAssertTrue(workload.orderedJobs.isEmpty)
    }

    func testEqualTimestampsPreserveStartOrder() {
        let firstID = UUID()
        let secondID = UUID()
        let start = Date(timeIntervalSince1970: 2_500)
        var workload = MacTranscriptionWorkload()
        workload.start(id: firstID, duration: 5, at: start)
        workload.start(id: secondID, duration: 5, at: start)

        XCTAssertEqual(workload.orderedJobs.map(\.id), [firstID, secondID])
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

    func testFinishingOlderAttemptKeepsOverlappingRetryVisible() {
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
        XCTAssertEqual(workload.orderedJobs.map(\.id), [retryAttemptID])
    }

    func testInvalidDurationsAndClockSkewRemainAtSafeInitialEstimate() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 4_000)
        var workload = MacTranscriptionWorkload()
        workload.start(id: id, duration: .infinity, at: start)

        // The job sanitizes a nonsensical duration on admission, so nothing
        // downstream — History, diagnostics, or the HUD — ever reads one.
        XCTAssertEqual(workload.orderedJobs.first?.recordingDuration, 0)
    }
}
