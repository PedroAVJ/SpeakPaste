import Combine

/// The microphone-facing portion of the floating HUD. Background
/// transcription is deliberately separate because the microphone may already
/// be capturing the next dictation while an earlier one awaits text.
enum MacHUDCaptureActivity: Equatable {
    case inactive
    case connecting
    case listening
    case releasing
}

/// The complete user-visible state of the floating HUD. Keeping this resolver
/// pure gives the AppKit panel controller and SwiftUI content one source of
/// truth for visibility and capture-over-transcription precedence.
enum MacHUDActivity: Equatable {
    case hidden
    case connecting
    case listening
    case releasing
    case transcribing

    static func resolve(
        capture: MacHUDCaptureActivity,
        inFlightTranscriptionCount: Int
    ) -> Self {
        switch capture {
        case .connecting:
            return .connecting
        case .listening:
            return .listening
        case .releasing:
            return .releasing
        case .inactive:
            return inFlightTranscriptionCount > 0 ? .transcribing : .hidden
        }
    }

    /// Combines the two independently changing facts that control the HUD.
    /// The panel controller consumes this exact publisher, so a transcription
    /// count change cannot be missed merely because capture remains inactive.
    static func publisher<Capture: Publisher, Count: Publisher>(
        capture: Capture,
        inFlightTranscriptionCount: Count
    ) -> AnyPublisher<Self, Never>
    where
        Capture.Output == MacHUDCaptureActivity,
        Capture.Failure == Never,
        Count.Output == Int,
        Count.Failure == Never
    {
        Publishers.CombineLatest(capture, inFlightTranscriptionCount)
            .map { capture, count in
                resolve(
                    capture: capture,
                    inFlightTranscriptionCount: count
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
