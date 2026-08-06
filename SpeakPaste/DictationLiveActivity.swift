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
    private var elapsedDurationBySessionID: [UUID: TimeInterval] = [:]

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
        elapsedDurationBySessionID.removeAll()

        let attributes = SpeakPasteActivityAttributes(
            sessionID: sessionID,
            startedAt: startedAt
        )
        let content = ActivityContent(
            state: SpeakPasteActivityAttributes.ContentState(
                phase: .starting,
                recordingStartedAt: nil,
                elapsedDuration: 0
            ),
            staleDate: staleDate(for: .starting)
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
        recordingStartedAt: Date? = nil,
        elapsedDuration: TimeInterval? = nil
    ) async {
        guard let activity = currentActivity(for: sessionID) else { return }
        if let elapsedDuration {
            elapsedDurationBySessionID[sessionID] = max(0, elapsedDuration)
        }
        if phase == .recording {
            if let recordingStartedAt {
                let bankedDuration = elapsedDurationBySessionID[sessionID] ?? 0
                recordingStartedAtBySessionID[sessionID] =
                    recordingStartedAt.addingTimeInterval(-bankedDuration)
            } else if recordingStartedAtBySessionID[sessionID] == nil {
                let bankedDuration = elapsedDurationBySessionID[sessionID] ?? 0
                recordingStartedAtBySessionID[sessionID] =
                    Date().addingTimeInterval(-bankedDuration)
            }
        }
        await activity.update(
            ActivityContent(
                state: SpeakPasteActivityAttributes.ContentState(
                    phase: phase,
                    recordingStartedAt: recordingStartedAtBySessionID[sessionID],
                    elapsedDuration: elapsedDurationBySessionID[sessionID] ?? 0
                ),
                staleDate: staleDate(for: phase)
            )
        )
    }

    /// Active phases periodically extend a short deadline. If the app process
    /// is killed, ActivityKit marks the card stale instead of advertising a
    /// microphone that no longer exists. Paused is intentionally durable and
    /// has no deadline because it owns no microphone or process runtime.
    func refreshStaleness(
        _ phase: SpeakPasteActivityAttributes.Phase,
        sessionID: UUID
    ) async {
        guard phase == .starting || phase == .recording else { return }
        await update(phase, sessionID: sessionID)
    }

    func end(
        _ phase: SpeakPasteActivityAttributes.Phase,
        sessionID: UUID
    ) async {
        guard let activity = currentActivity(for: sessionID) else { return }
        let content = ActivityContent(
            state: SpeakPasteActivityAttributes.ContentState(
                phase: phase,
                recordingStartedAt: recordingStartedAtBySessionID[sessionID],
                elapsedDuration: elapsedDurationBySessionID[sessionID] ?? 0
            ),
            staleDate: nil
        )
        let policy: ActivityUIDismissalPolicy = phase == .cancelled
            ? .immediate
            : .after(Date().addingTimeInterval(3))
        await activity.end(content, dismissalPolicy: policy)
        recordingStartedAtBySessionID[sessionID] = nil
        elapsedDurationBySessionID[sessionID] = nil
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

    private func staleDate(
        for phase: SpeakPasteActivityAttributes.Phase
    ) -> Date? {
        switch phase {
        case .starting, .recording:
            // The engine refreshes every three seconds. Fifteen seconds leaves
            // room for ordinary scheduling jitter without masking a dead mic.
            Date().addingTimeInterval(15)
        case .transcribing:
            // Final transcription runs under a finite UIKit background task.
            Date().addingTimeInterval(45)
        case .paused, .completed, .failed, .cancelled:
            nil
        }
    }
}
