@preconcurrency import ActivityKit
import Foundation

@MainActor
final class DictationLiveActivity {
    enum LiveActivityError: LocalizedError {
        case disabled
        case couldNotStart(String)

        var errorDescription: String? {
            switch self {
            case .disabled:
                "Enable Live Activities for SpeakPaste in Settings."
            case let .couldNotStart(message):
                "The recording indicator could not start: \(message)"
            }
        }
    }

    private var activity: Activity<SpeakPasteActivityAttributes>?

    /// `AudioRecordingIntent` requires a Live Activity for the entire capture.
    /// Without it, iOS stops recording as soon as the intent returns.
    func start(sessionID: UUID, startedAt: Date) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LiveActivityError.disabled
        }

        // A process termination can strand the old indicator even though its
        // recorder is gone. There can only be one SpeakPaste dictation.
        for existing in Activity<SpeakPasteActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }

        let attributes = SpeakPasteActivityAttributes(
            sessionID: sessionID,
            startedAt: startedAt
        )
        let content = ActivityContent(
            state: SpeakPasteActivityAttributes.ContentState(phase: .recording),
            staleDate: nil
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            throw LiveActivityError.couldNotStart(error.localizedDescription)
        }
    }

    func update(_ phase: SpeakPasteActivityAttributes.Phase) async {
        guard let activity = currentActivity else { return }
        await activity.update(
            ActivityContent(
                state: SpeakPasteActivityAttributes.ContentState(phase: phase),
                staleDate: nil
            )
        )
    }

    func end(_ phase: SpeakPasteActivityAttributes.Phase) async {
        guard let activity = currentActivity else { return }
        let content = ActivityContent(
            state: SpeakPasteActivityAttributes.ContentState(phase: phase),
            staleDate: nil
        )
        let policy: ActivityUIDismissalPolicy = phase == .cancelled
            ? .immediate
            : .after(Date().addingTimeInterval(3))
        await activity.end(content, dismissalPolicy: policy)
        self.activity = nil
    }

    private var currentActivity: Activity<SpeakPasteActivityAttributes>? {
        activity ?? Activity<SpeakPasteActivityAttributes>.activities.first
    }
}
