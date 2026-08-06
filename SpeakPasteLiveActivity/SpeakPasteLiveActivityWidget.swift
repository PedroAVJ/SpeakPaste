import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SpeakPasteLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        SpeakPasteLiveActivityWidget()
    }
}

/// Palette from `docs/hud-prototypes/ios-live-activity.html`, warmed to the
/// containing app's surface: a near-black translucent card with one phase hue
/// carrying the state.
private enum LAPalette {
    static let card = Color(red: 0.09, green: 0.078, blue: 0.068).opacity(0.86)
    static let recording = Color(red: 1.0, green: 0.56, blue: 0.35)
    static let paused = Color(red: 0.94, green: 0.63, blue: 0.23)
    static let transcribing = Color(red: 0.42, green: 0.67, blue: 0.94)
    static let completed = Color(red: 0.43, green: 0.8, blue: 0.43)
    static let failed = Color(red: 0.98, green: 0.46, blue: 0.4)
    static let neutral = Color(white: 0.78)
}

private extension SpeakPasteActivityAttributes.Phase {
    var tint: Color {
        switch self {
        case .starting, .recording: LAPalette.recording
        case .paused: LAPalette.paused
        case .transcribing: LAPalette.transcribing
        case .completed: LAPalette.completed
        case .failed: LAPalette.failed
        case .cancelled: LAPalette.neutral
        }
    }

    /// The two phases that own a microphone lead with the waveform itself.
    /// Every other phase needs a glyph that reads alone in a 20-point circle,
    /// which a frozen waveform cannot do.
    var isWaveformLed: Bool {
        self == .starting || self == .recording
    }

    var glyphName: String {
        switch self {
        case .starting, .recording: "waveform"
        case .paused: "pause.fill"
        case .transcribing: "ellipsis"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }

    /// Elapsed time is meaningful only while a capture exists to measure.
    var showsElapsedTime: Bool {
        self == .recording || self == .paused
    }

    /// Pause and Cancel act in place only while there is a live capture to
    /// act on. Every later phase is status-only.
    var hasControls: Bool {
        self == .recording || self == .paused
    }

    /// One line for the status-only phases. Delivery happens at the keyboard,
    /// so the card points there instead of claiming a Stop button it does not
    /// have — only the keyboard can place text at a cursor.
    var statusLine: String? {
        switch self {
        case .starting:
            return "Getting the microphone ready…"
        case .recording, .paused:
            return nil
        case .transcribing:
            return "Transcribing — the SpeakPaste keyboard inserts it when ready."
        case .completed:
            return "Transcript ready. Bring up the SpeakPaste keyboard to insert it."
        case .failed:
            return "Dictation failed. Open SpeakPaste to recover it."
        case .cancelled:
            return "Cancelled. The recording stays recoverable in SpeakPaste."
        }
    }
}

private func displayPhase(
    for context: ActivityViewContext<SpeakPasteActivityAttributes>
) -> SpeakPasteActivityAttributes.Phase {
    context.isStale ? .failed : context.state.phase
}

/// The prototype's five-bar mark, drawn rather than animated.
///
/// A Live Activity only animates transitions between content states, so a
/// looping waveform would be a promise the platform never keeps. Fixed bar
/// heights carry the same "this is audio" reading at every size, and are
/// inert under Reduce Motion by construction.
private struct WaveformMark: View {
    var height: CGFloat = 15
    var tint: Color
    /// `starting` is a microphone that is not hot yet, and says so by sitting
    /// lower and dimmer than a live capture.
    var isLive = true

    private static let liveRatios: [CGFloat] = [0.42, 0.78, 1.0, 0.62, 0.34]
    private static let armingRatios: [CGFloat] = [0.3, 0.42, 0.5, 0.38, 0.28]

    private var barWidth: CGFloat { max(2, (height / 6).rounded()) }

    var body: some View {
        let ratios = isLive ? Self.liveRatios : Self.armingRatios
        HStack(alignment: .center, spacing: max(1.5, barWidth * 0.7)) {
            ForEach(ratios.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: barWidth, height: height * ratios[index])
            }
        }
        .frame(height: height)
        .opacity(isLive ? 1 : 0.6)
    }
}

/// The phase mark: waveform while a capture exists, a single decisive glyph
/// otherwise. Sized so it survives the minimal presentation's lone circle.
private struct PhaseMark: View {
    let phase: SpeakPasteActivityAttributes.Phase
    var size: CGFloat = 15

    var body: some View {
        Group {
            if phase.isWaveformLed {
                WaveformMark(
                    height: size,
                    tint: phase.tint,
                    isLive: phase == .recording
                )
            } else {
                Image(systemName: phase.glyphName)
                    .font(.system(size: size * 0.9, weight: .semibold))
                    .foregroundStyle(phase.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(phase.title)
    }
}

/// Continuous hot-microphone time. `recordingStartedAt` is already back-dated
/// by the banked duration of earlier segments, so the system timer reads as
/// one dictation rather than restarting at every resume. Paused shows the
/// frozen banked total; other phases show nothing rather than a stale number.
private struct ElapsedTime: View {
    let state: SpeakPasteActivityAttributes.ContentState
    var font: Font

    var body: some View {
        if state.phase == .recording, let startedAt = state.recordingStartedAt {
            Text(startedAt, style: .timer)
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        } else if state.phase == .paused {
            Text(Self.timeString(state.elapsedDuration))
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    static func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One intent-backed chip, styled like the prototype's expanded-card buttons.
private struct ControlChip<Intent: AppIntent>: View {
    let title: String
    let tint: Color
    let intent: Intent
    let accessibilityLabel: String
    var accessibilityHint: String = ""

    var body: some View {
        Button(intent: intent) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}

/// Pause or Resume plus Cancel, scoped to the live session so a stranded card
/// from an older dictation stays harmless. Stop is deliberately absent: only
/// the keyboard can deliver text to a cursor.
private struct DictationControls: View {
    let phase: SpeakPasteActivityAttributes.Phase
    let sessionID: UUID

    var body: some View {
        HStack(spacing: 8) {
            if phase == .paused {
                ControlChip(
                    title: "Resume",
                    tint: LAPalette.completed,
                    intent: ResumeDictationIntent(sessionID: sessionID),
                    accessibilityLabel: "Resume dictation",
                    accessibilityHint: "Opens a new recording segment in this dictation."
                )
            } else {
                ControlChip(
                    title: "Pause",
                    tint: LAPalette.paused,
                    intent: PauseDictationIntent(sessionID: sessionID),
                    accessibilityLabel: "Pause dictation",
                    accessibilityHint: "Releases the microphone without ending the dictation."
                )
            }
            ControlChip(
                title: "Cancel",
                tint: LAPalette.neutral,
                intent: CancelDictationIntent(sessionID: sessionID),
                accessibilityLabel: "Cancel dictation",
                accessibilityHint: "Closes the dictation and keeps the recording recoverable."
            )
        }
    }
}

/// Controls when there is a capture, one status line when there is not. Both
/// island and Lock Screen use this so the card never changes meaning between
/// the two places the user meets it.
private struct DictationFooter: View {
    let state: SpeakPasteActivityAttributes.ContentState
    let sessionID: UUID
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("Status is out of date. Open SpeakPaste to recover.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.phase.hasControls {
            DictationControls(phase: state.phase, sessionID: sessionID)
        } else if let statusLine = state.phase.statusLine {
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The authored card: the Lock Screen presentation, with the same anatomy the
/// expanded island lays out across its regions — small title row, large
/// elapsed time, then controls or one status line.
private struct DictationCard: View {
    let context: ActivityViewContext<SpeakPasteActivityAttributes>

    var body: some View {
        let phase = displayPhase(for: context)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text("SpeakPaste ·")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(phase.title)
                    .font(.caption)
                    .foregroundStyle(phase.tint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                PhaseMark(phase: phase)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("SpeakPaste, \(phase.title)")

            if phase.showsElapsedTime {
                ElapsedTime(
                    state: context.state,
                    font: .system(size: 30, weight: .medium, design: .rounded)
                )
                .foregroundStyle(.white)
                .accessibilityLabel(elapsedAccessibilityLabel)
            }

            DictationFooter(
                state: context.state,
                sessionID: context.attributes.sessionID,
                isStale: context.isStale
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var elapsedAccessibilityLabel: String {
        switch context.state.phase {
        case .recording:
            "Recording in progress"
        case .paused:
            "Paused at \(ElapsedTime.timeString(context.state.elapsedDuration))"
        default:
            ""
        }
    }
}

struct SpeakPasteLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeakPasteActivityAttributes.self) { context in
            DictationCard(context: context)
                .activityBackgroundTint(LAPalette.card)
                .activitySystemActionForegroundColor(
                    displayPhase(for: context).tint
                )
        } dynamicIsland: { context in
            let phase = displayPhase(for: context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        PhaseMark(phase: phase)
                            .accessibilityHidden(true)
                        Text(phase.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(phase.tint)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "SpeakPaste, \(phase.title)"
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if phase.showsElapsedTime {
                        ElapsedTime(
                            state: context.state,
                            font: .system(.headline, design: .rounded)
                        )
                        .foregroundStyle(.white)
                        .accessibilityLabel(
                            phase == .paused
                                ? "Paused at \(ElapsedTime.timeString(context.state.elapsedDuration))"
                                : "Recording in progress"
                        )
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DictationFooter(
                        state: context.state,
                        sessionID: context.attributes.sessionID,
                        isStale: context.isStale
                    )
                    .padding(.top, 2)
                }
            } compactLeading: {
                // Waveform-led: the leading slot always reads as SpeakPaste's
                // capture state, whatever the trailing slot has room for.
                PhaseMark(phase: phase, size: 13)
                    .accessibilityLabel(
                        "SpeakPaste, \(phase.title)"
                    )
            } compactTrailing: {
                // Elapsed time only where it fits; the leading mark already
                // carries the status on its own for every other phase.
                if phase.showsElapsedTime {
                    ElapsedTime(
                        state: context.state,
                        font: .caption2.weight(.medium)
                    )
                    .foregroundStyle(phase.tint)
                    .frame(maxWidth: 46)
                    .accessibilityHidden(true)
                }
            } minimal: {
                // Two live activities demote one to this lone circle: the mark
                // must say "recording" — or paused, or done — entirely alone.
                PhaseMark(phase: phase, size: 12)
                    .accessibilityLabel(
                        "SpeakPaste, \(phase.title)"
                    )
            }
            .keylineTint(phase.tint)
        }
    }
}
