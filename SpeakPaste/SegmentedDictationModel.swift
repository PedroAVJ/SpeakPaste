import Foundation

/// Process-local capture state for one intent-driven dictation. Keeping the
/// transition table separate from AVFoundation makes duplicate Back Taps and
/// stale Live Activity commands deterministic even while an async transition
/// temporarily re-enters the main actor.
enum SegmentedDictationCaptureState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case pausing
    case paused
    case resuming
    case closing

    enum ToggleAction: Equatable, Sendable {
        case start
        case pause
        case resume
        case none
    }

    var toggleAction: ToggleAction {
        switch self {
        case .idle:
            .start
        case .recording:
            .pause
        case .paused:
            .resume
        case .starting, .pausing, .resuming, .closing:
            .none
        }
    }
}

struct SegmentedTranscriptPiece: Equatable, Sendable {
    let ordinal: Int
    let text: String
    let languageCode: String?
}

struct SegmentedTranscriptAssembly: Equatable, Sendable {
    let text: String
    let languageCode: String?
}

enum SegmentedTranscriptAssembler {
    /// Segment requests finish independently, so completion order is not spoken
    /// order. Normalize only the seams introduced by pause/resume and otherwise
    /// leave Scribe's punctuation and casing untouched.
    static func assemble(
        _ pieces: [SegmentedTranscriptPiece]
    ) -> SegmentedTranscriptAssembly? {
        let ordered = pieces.sorted {
            if $0.ordinal == $1.ordinal {
                return $0.text < $1.text
            }
            return $0.ordinal < $1.ordinal
        }
        let text = ordered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }

        let languageCodes = Set(
            ordered.compactMap { piece -> String? in
                let code = piece.languageCode?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return code?.isEmpty == false ? code : nil
            }
        )
        return SegmentedTranscriptAssembly(
            text: text,
            languageCode: languageCodes.count == 1
                ? languageCodes.first
                : nil
        )
    }
}
