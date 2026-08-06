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

    enum Completion: Equatable, Sendable {
        /// No active job used this identifier.
        case ignored
        /// At least one request remains. `nextHeadID` is the attempt that is
        /// now the oldest outstanding work.
        case moreRemain(nextHeadID: UUID)
        /// The final outstanding request ended.
        case becameIdle
    }

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

    /// Every outstanding attempt oldest-first. The HUD depth stack renders
    /// one card per attempt, each with its own heuristic rail; combining
    /// concurrent jobs into one percentage would imply knowledge the app
    /// does not have.
    var orderedJobs: [Job] {
        jobs.enumerated().sorted { lhs, rhs in
            if lhs.element.enqueuedAt == rhs.element.enqueuedAt {
                // Preserve start order when timestamps have the same precision.
                return lhs.offset < rhs.offset
            }
            return lhs.element.enqueuedAt < rhs.element.enqueuedAt
        }.map(\.element)
    }

    private var headJob: Job? { orderedJobs.first }
}
