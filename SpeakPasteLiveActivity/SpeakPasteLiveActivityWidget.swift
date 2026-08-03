import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SpeakPasteLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        SpeakPasteLiveActivityWidget()
    }
}

struct SpeakPasteLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeakPasteActivityAttributes.self) { context in
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: context.state.phase.systemImageName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("SpeakPaste")
                        .font(.headline)
                    Text(lockScreenStatus(for: context.state.phase))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if
                    context.state.phase == .recording,
                    let startedAt = context.state.recordingStartedAt
                {
                    Text(startedAt, style: .timer)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .activityBackgroundTint(Color.black.opacity(0.88))
            .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(
                        context.state.phase.title,
                        systemImage: context.state.phase.systemImageName
                    )
                    .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if
                        context.state.phase == .recording,
                        let startedAt = context.state.recordingStartedAt
                    {
                        Text(startedAt, style: .timer)
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(expandedHint(for: context.state.phase))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.systemImageName)
                    .foregroundStyle(.orange)
            } compactTrailing: {
                if
                    context.state.phase == .recording,
                    let startedAt = context.state.recordingStartedAt
                {
                    Text(startedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                } else if [.transcribing, .completed].contains(
                    context.state.phase
                ) {
                    Image(systemName: "keyboard")
                        .accessibilityLabel("Switch to SpeakPaste keyboard")
                } else {
                    Image(systemName: context.state.phase.systemImageName)
                }
            } minimal: {
                Image(systemName: context.state.phase.systemImageName)
                    .foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }

    private func lockScreenStatus(
        for phase: SpeakPasteActivityAttributes.Phase
    ) -> String {
        switch phase {
        case .transcribing:
            "Switch to SpeakPaste keyboard now"
        case .completed:
            "Switch keyboards to insert"
        default:
            phase.title
        }
    }

    private func expandedHint(
        for phase: SpeakPasteActivityAttributes.Phase
    ) -> String {
        switch phase {
        case .starting:
            "Getting the microphone ready…"
        case .recording:
            "Double-tap the back of your iPhone to finish."
        case .transcribing:
            "Switch to the SpeakPaste keyboard now; it will insert when ready."
        case .completed:
            "Switch to the SpeakPaste keyboard to insert it."
        default:
            phase.title
        }
    }
}
