import SwiftUI

// The keyboard extension is a separate target and cannot link the app's
// Theme, so the warm-dark palette is mirrored here. Keep values in sync with
// SpeakPaste/ContentView.swift.
private enum KBTheme {
    static let background = Color(red: 0.09, green: 0.078, blue: 0.068)
    static let backgroundTop = Color(red: 0.128, green: 0.106, blue: 0.09)
    static let surface = Color(red: 0.15, green: 0.132, blue: 0.117)
    static let surfaceRaised = Color(red: 0.185, green: 0.164, blue: 0.146)
    static let stroke = Color.white.opacity(0.07)
    static let accent = Color(red: 1.0, green: 0.56, blue: 0.35)
    static let accentDeep = Color(red: 0.91, green: 0.39, blue: 0.24)
    static let onAccent = Color(red: 0.17, green: 0.09, blue: 0.05)
    static let ink = Color(red: 0.96, green: 0.94, blue: 0.91)
    static let inkMuted = Color(red: 0.65, green: 0.61, blue: 0.56)
    static let danger = Color(red: 0.98, green: 0.46, blue: 0.4)

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, background],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct KBPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(KBTheme.onAccent)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Capsule().fill(KBTheme.accentGradient))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct KBQuietButtonStyle: ButtonStyle {
    var tint: Color = KBTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Capsule().fill(KBTheme.surface))
            .overlay(Capsule().stroke(KBTheme.stroke))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var micDiameter: CGFloat = 64

    var body: some View {
        VStack(spacing: 6) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KBTheme.backgroundGradient.ignoresSafeArea())
        .tint(KBTheme.accent)
        .environment(\.colorScheme, .dark)
        // The keyboard has a fixed 272pt frame; text scales with Dynamic Type
        // up to xxLarge, then caps so every state still fits.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: model.snapshot.phase
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: model.localError
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: model.hasFullAccess
        )
    }

    // MARK: - States

    @ViewBuilder
    private var stage: some View {
        if !model.hasFullAccess {
            fullAccessPrompt
        } else if let message = errorMessage {
            errorCard(message)
        } else if model.isLaunching {
            launchingState
        } else if model.isRecording {
            recordingState
        } else if model.isTranscribing {
            transcribingState
        } else {
            idleState
        }
    }

    private var errorMessage: String? {
        if let localError = model.localError { return localError }
        if model.didFail {
            return model.snapshot.errorMessage ?? "Dictation failed. Try again."
        }
        return nil
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Button(action: model.startDictation) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(KBTheme.accentGradient)
                            .frame(width: micDiameter, height: micDiameter)
                            .shadow(color: KBTheme.accent.opacity(0.35), radius: 14, y: 5)
                        Image(systemName: "mic.fill")
                            .font(.system(size: micDiameter * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text("Start Dictation")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(KBTheme.ink)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start dictation")
            .accessibilityHint(
                "Opens SpeakPaste briefly to record. Your words are typed here when you finish."
            )

            Text("Hops to SpeakPaste to record, then types your words right here.")
                .font(.caption)
                .foregroundStyle(KBTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var launchingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
                .tint(KBTheme.accent)
            Text("Opening SpeakPaste…")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(KBTheme.ink)
            Text("The app takes over for a moment to record, then hands the words back to this keyboard.")
                .font(.caption)
                .foregroundStyle(KBTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Opening SpeakPaste. The app records for a moment, then hands the words back to this keyboard."
        )
    }

    private var recordingState: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(KBTheme.danger)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                Text("Recording")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(KBTheme.ink)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(KBTheme.surface))
            .overlay(Capsule().stroke(KBTheme.stroke))
            .accessibilityHidden(true)

            TimelineView(.periodic(from: model.snapshot.startedAt, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(model.snapshot.startedAt))
                Text(KBTheme.timeString(elapsed))
                    .font(.system(size: 36, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(KBTheme.ink)
                    .accessibilityLabel("Recording, \(KBTheme.timeString(elapsed)) elapsed")
            }

            HStack(spacing: 10) {
                Button {
                    model.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(KBQuietButtonStyle(tint: KBTheme.inkMuted))
                .accessibilityHint("Discards the recording without typing anything.")

                Button {
                    model.stopAndTranscribe()
                } label: {
                    Label("Stop & Insert", systemImage: "stop.fill")
                }
                .buttonStyle(KBPrimaryButtonStyle())
                .accessibilityHint("Stops recording and types the transcript here.")
            }
        }
        .padding(.horizontal, 20)
    }

    private var transcribingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
                .tint(KBTheme.accent)
            Text("Transcribing…")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(KBTheme.ink)
            Text("Your words will be typed at the cursor in a moment.")
                .font(.caption)
                .foregroundStyle(KBTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcribing. Your words will be typed at the cursor in a moment.")
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KBTheme.danger)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(KBTheme.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    model.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KBTheme.inkMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.top, -10)
                .padding(.trailing, -10)
                .accessibilityLabel("Dismiss error")
            }

            HStack(spacing: 8) {
                // A launch failure (localError) can't be retried from here
                // because the containing app never opened; the shared retry
                // command only reaches an app that is already running.
                if model.didFail && model.localError == nil {
                    Button {
                        model.retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(KBQuietButtonStyle())
                    .accessibilityHint("Asks SpeakPaste to transcribe the recording again.")
                }

                Button {
                    model.openSpeakPaste()
                } label: {
                    Label("Open SpeakPaste", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(KBQuietButtonStyle())
                .accessibilityHint("Opens the SpeakPaste app.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(KBTheme.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(KBTheme.danger.opacity(0.35))
        )
        .padding(.horizontal, 2)
    }

    private var fullAccessPrompt: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KBTheme.accent)
                    .accessibilityHidden(true)
                Text("Allow Full Access")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(KBTheme.ink)
            }

            Text(
                "SpeakPaste needs Full Access to hand dictation between this keyboard and the app. Turn it on in Settings › General › Keyboard › Keyboards › SpeakPaste."
            )
            .font(.caption)
            .foregroundStyle(KBTheme.inkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                model.openSpeakPaste()
            } label: {
                Label("Open SpeakPaste", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(KBPrimaryButtonStyle())
            .accessibilityHint("Opens the SpeakPaste app with setup instructions.")
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Button(action: model.nextKeyboard) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(KBTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(KBTheme.surface))
                    .overlay(Circle().stroke(KBTheme.stroke))
            }
            .accessibilityLabel("Next keyboard")
            .accessibilityHint("Switches to your next keyboard.")

            Spacer()

            Text("SpeakPaste")
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(KBTheme.inkMuted.opacity(0.8))
                .accessibilityHidden(true)
        }
    }
}
