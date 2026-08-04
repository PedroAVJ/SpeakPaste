import Foundation

/// Pure, presentation-facing state for transcription work that is still
/// awaiting a terminal result. The estimate deliberately stops short of
/// completion because the batch transcription endpoint does not report real
/// progress; only `finish(id:)` knows that an attempt actually ended.
struct MacTranscriptionWorkload: Equatable, Sendable {
    struct Job: Equatable, Identifiable, Sendable {
        let id: UUID
        let enqueuedAt: Date
        let recordingDuration: TimeInterval

        init(id: UUID, enqueuedAt: Date, recordingDuration: TimeInterval) {
            self.id = id
            self.enqueuedAt = enqueuedAt
            self.recordingDuration = Self.sanitized(recordingDuration)
        }

        private static func sanitized(_ duration: TimeInterval) -> TimeInterval {
            guard duration.isFinite else { return 0 }
            return max(0, duration)
        }
    }

    struct Snapshot: Equatable, Sendable {
        /// The oldest outstanding attempt. A view can use this identity to
        /// crossfade when one request ends and another remains instead of
        /// interpolating a heuristic value backward.
        let headID: UUID
        let activeCount: Int
        let estimatedFraction: Double
    }

    enum Completion: Equatable, Sendable {
        /// No active job used this identifier.
        case ignored
        /// At least one request remains. `nextHeadID` is the attempt whose
        /// progress should now drive the presentation.
        case moreRemain(nextHeadID: UUID)
        /// The final outstanding request ended.
        case becameIdle
    }

    private static let minimumExpectedDuration: TimeInterval = 2
    private static let durationRatio = 0.20
    private static let initialFraction = 0.08
    private static let estimatedRange = 0.84
    private static let curveRate = 2.2
    private static let activeCeiling = 0.92

    private var jobs: [Job] = []

    var activeCount: Int { jobs.count }
    var isEmpty: Bool { jobs.isEmpty }

    /// Adds one current attempt. A duplicate ID is ignored so repeated model
    /// publication cannot inflate the visible workload. Once an attempt has
    /// finished, the same durable recording ID may be started again as a retry.
    @discardableResult
    mutating func start(
        id: UUID,
        duration: TimeInterval,
        at date: Date = Date()
    ) -> Bool {
        guard !jobs.contains(where: { $0.id == id }) else { return false }
        jobs.append(Job(id: id, enqueuedAt: date, recordingDuration: duration))
        return true
    }

    /// Removes one terminal attempt and reports whether the whole workload is
    /// now idle. Success and failure remain a UI-policy decision outside this
    /// pure accounting type.
    @discardableResult
    mutating func finish(id: UUID) -> Completion {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }
        jobs.remove(at: index)
        guard let head = headJob else { return .becameIdle }
        return .moreRemain(nextHeadID: head.id)
    }

    /// Returns the heuristic state of the oldest outstanding attempt. Several
    /// jobs can run concurrently, so combining them into one percentage would
    /// imply knowledge the app does not have.
    func snapshot(at date: Date = Date()) -> Snapshot? {
        guard let head = headJob else { return nil }
        let elapsed = max(0, date.timeIntervalSince(head.enqueuedAt))
        return Snapshot(
            headID: head.id,
            activeCount: jobs.count,
            estimatedFraction: Self.estimatedFraction(
                recordingDuration: head.recordingDuration,
                elapsed: elapsed
            )
        )
    }

    static func expectedDuration(
        for recordingDuration: TimeInterval
    ) -> TimeInterval {
        let sanitizedDuration: TimeInterval
        if recordingDuration.isFinite {
            sanitizedDuration = max(0, recordingDuration)
        } else {
            sanitizedDuration = 0
        }
        return max(
            minimumExpectedDuration,
            durationRatio * sanitizedDuration
        )
    }

    static func estimatedFraction(
        recordingDuration: TimeInterval,
        elapsed: TimeInterval
    ) -> Double {
        let sanitizedElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let expected = expectedDuration(for: recordingDuration)
        let fraction = initialFraction
            + estimatedRange * (1 - exp(-curveRate * sanitizedElapsed / expected))
        return min(activeCeiling, max(initialFraction, fraction))
    }

    private var headJob: Job? {
        jobs.enumerated().min { lhs, rhs in
            if lhs.element.enqueuedAt == rhs.element.enqueuedAt {
                // Preserve start order when timestamps have the same precision.
                return lhs.offset < rhs.offset
            }
            return lhs.element.enqueuedAt < rhs.element.enqueuedAt
        }?.element
    }
}
