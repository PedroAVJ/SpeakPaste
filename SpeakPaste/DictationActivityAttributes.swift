import ActivityKit
import Foundation

struct SpeakPasteActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var phase: Phase
    }

    enum Phase: String, Codable, Hashable {
        case recording
        case transcribing
        case completed
        case failed
        case cancelled

        var title: String {
            switch self {
            case .recording: "Recording"
            case .transcribing: "Transcribing"
            case .completed: "Copied"
            case .failed: "Dictation failed"
            case .cancelled: "Cancelled"
            }
        }

        var systemImageName: String {
            switch self {
            case .recording: "waveform"
            case .transcribing: "ellipsis"
            case .completed: "checkmark"
            case .failed: "exclamationmark"
            case .cancelled: "xmark"
            }
        }
    }

    var sessionID: UUID
    var startedAt: Date
}
