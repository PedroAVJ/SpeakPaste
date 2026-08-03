import ActivityKit
import Foundation

struct SpeakPasteActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Mutable because microphone activation happens after the Live
        /// Activity is created. The timer must begin only once capture is real.
        var recordingStartedAt: Date?

        init(phase: Phase, recordingStartedAt: Date? = nil) {
            self.phase = phase
            self.recordingStartedAt = recordingStartedAt
        }
    }

    enum Phase: String, Codable, Hashable {
        case starting
        case recording
        case transcribing
        case completed
        case failed
        case cancelled

        var title: String {
            switch self {
            case .starting: "Starting"
            case .recording: "Recording"
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
