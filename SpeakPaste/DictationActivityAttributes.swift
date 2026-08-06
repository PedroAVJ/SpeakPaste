import ActivityKit
import Foundation

struct SpeakPasteActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Mutable because microphone activation happens after the Live
        /// Activity is created. The timer must begin only once capture is real.
        var recordingStartedAt: Date?
        /// Total hot-microphone time already banked before the current segment.
        /// Pauses freeze this value; resumes use it to anchor a continuous timer
        /// without keeping the microphone alive.
        var elapsedDuration: TimeInterval

        init(
            phase: Phase,
            recordingStartedAt: Date? = nil,
            elapsedDuration: TimeInterval = 0
        ) {
            self.phase = phase
            self.recordingStartedAt = recordingStartedAt
            self.elapsedDuration = max(0, elapsedDuration)
        }
    }

    enum Phase: String, Codable, Hashable {
        case starting
        case recording
        case paused
        case transcribing
        case completed
        case failed
        case cancelled

        var title: String {
            switch self {
            case .starting: "Starting"
            case .recording: "Recording"
            case .paused: "Paused"
            case .transcribing: "Transcribing"
            case .completed: "Transcript ready"
            case .failed: "Dictation failed"
            case .cancelled: "Cancelled"
            }
        }

        var systemImageName: String {
            switch self {
            case .starting: "ellipsis"
            case .recording: "waveform"
            case .paused: "pause.fill"
            case .transcribing: "ellipsis"
            case .completed: "checkmark"
            case .failed: "exclamationmark"
            case .cancelled: "xmark"
            }
        }
    }

    var sessionID: UUID
    /// Creation time retained as immutable session metadata. Recording UI uses
    /// `ContentState.recordingStartedAt`, which is set after audio activation.
    var startedAt: Date
}
