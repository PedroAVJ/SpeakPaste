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
    private var recordingStartedAtBySessionID: [UUID: Date] = [:]

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
        recordingStartedAtBySessionID.removeAll()

        let attributes = SpeakPasteActivityAttributes(
            sessionID: sessionID,
            startedAt: startedAt
        )
        let content = ActivityContent(
            state: SpeakPasteActivityAttributes.ContentState(
                phase: .starting,
                recordingStartedAt: nil
            ),
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

    func update(
        _ phase: SpeakPasteActivityAttributes.Phase,
        sessionID: UUID,
        recordingStartedAt: Date? = nil
    ) async {
        guard let activity = currentActivity(for: sessionID) else { return }
        if phase == .recording {
            recordingStartedAtBySessionID[sessionID] = recordingStartedAt ?? Date()
        }
        await activity.update(
            ActivityContent(
                state: SpeakPasteActivityAttributes.ContentState(
                    phase: phase,
                    recordingStartedAt: recordingStartedAtBySessionID[sessionID]
                ),
                staleDate: nil
            )
        )
    }

    func end(
        _ phase: SpeakPasteActivityAttributes.Phase,
        sessionID: UUID
    ) async {
        guard let activity = currentActivity(for: sessionID) else { return }
        let content = ActivityContent(
            state: SpeakPasteActivityAttributes.ContentState(
                phase: phase,
                recordingStartedAt: recordingStartedAtBySessionID[sessionID]
            ),
            staleDate: nil
        )
        let policy: ActivityUIDismissalPolicy = phase == .cancelled
            ? .immediate
            : .after(Date().addingTimeInterval(3))
        await activity.end(content, dismissalPolicy: policy)
        recordingStartedAtBySessionID[sessionID] = nil
        if self.activity?.id == activity.id {
            self.activity = nil
        }
    }

    private func currentActivity(
        for sessionID: UUID
    ) -> Activity<SpeakPasteActivityAttributes>? {
        if activity?.attributes.sessionID == sessionID {
            return activity
        }
        return Activity<SpeakPasteActivityAttributes>.activities.first {
            $0.attributes.sessionID == sessionID
        }
    }
}
