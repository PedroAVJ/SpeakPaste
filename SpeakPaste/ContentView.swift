import SwiftUI
import UIKit

// Warm-neutral dark palette shared by every SpeakPaste surface.
enum Theme {
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

struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(Theme.accentGradient))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct QuietPillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.stroke))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let message = errorMessage {
                    ErrorCard(model: model, message: message)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                RecordControls(model: model, recorder: model.recorder)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .top) { copiedPill }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.phase)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showHistory) {
            HistoryView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .presentationDragIndicator(.visible)
        }
        .alert("", isPresented: $model.showSwitchbackExplanation) {
            Button("OK") {
                model.confirmSwitchbackExplanation()
            }
        } message: {
            Text(
                "SpeakPaste will now take you back to your previous app. The first time you do this in a new app, iOS may ask for confirmation."
            )
        }
        .alert(
            "Couldn't switch back automatically",
            isPresented: $model.showManualReturnHint
        ) {
            Button("Try Again") {
                model.returnToKeyboardHost()
            }
            Button("Swipe Back", role: .cancel) {}
        } message: {
            Text(
                "Swipe right along the bottom home bar to return to your app. Recording continues while you switch."
            )
        }
    }

    private var errorMessage: String? {
        if case let .failed(message) = model.phase { return message }
        return nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
            Text("SpeakPaste")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.ink)
                Text("Dictate. Copy. Paste anywhere.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            iconButton("clock.arrow.circlepath", label: "History") {
                model.showHistory = true
            }
            iconButton("gearshape.fill", label: "Settings") {
                model.showSettings = true
            }
        }
    }

    private func iconButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().stroke(Theme.stroke))
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var stage: some View {
        switch model.phase {
        case .recording:
            RecordingLiveView(recorder: model.recorder)
        case .transcribing:
            ProcessingView()
        default:
            if model.transcriptText.isEmpty {
                IdleView(model: model)
            } else {
                TranscriptEditor(model: model)
            }
        }
    }

    private var copiedPill: some View {
        Group {
            if model.copiedRecently {
                Label("Copied to clipboard", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.accent))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
            value: model.copiedRecently
        )
        .padding(.top, 4)
    }
}

private struct IdleView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 96, height: 96)
                    .overlay(Circle().stroke(Theme.stroke))
                Image(systemName: "waveform")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)

            Text("Ready when you are")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Text(
                model.autoCopy
                    ? "Tap record and talk. The transcript lands on your clipboard automatically."
                    : "Tap record and talk. Copy the transcript when it's ready."
            )
            .font(.subheadline)
            .foregroundStyle(Theme.inkMuted)
            .multilineTextAlignment(.center)

            if !model.hasAPIKey {
                Button {
                    model.showSettings = true
                } label: {
                    Label("Add ElevenLabs API key", systemImage: "key.fill")
                }
                .buttonStyle(QuietPillButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
    }
}

private struct RecordingLiveView: View {
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 60

    var body: some View {
        VStack(spacing: 26) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.danger)
                    .frame(width: 10, height: 10)
                Text("Recording")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.stroke))
            .accessibilityHidden(true)

            Text(Theme.timeString(recorder.duration))
                .font(.system(size: timerSize, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .accessibilityLabel(
                    "Recording, \(Theme.timeString(recorder.duration)) elapsed"
                )

            MicLevelMeter(level: recorder.level, reduceMotion: reduceMotion)
                .frame(height: 64)
                .accessibilityHidden(true)

            Text("Tap the stop button when you're done.")
                .font(.footnote)
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 24)
    }
}

private struct MicLevelMeter: View {
    var level: Float
    var reduceMotion: Bool

    @State private var samples: [Float] = Array(repeating: 0, count: 28)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(samples.indices, id: \.self) { index in
                Capsule()
                    .fill(Theme.accent.opacity(0.3 + 0.7 * Double(samples[index])))
                    .frame(width: 4, height: 8 + CGFloat(samples[index]) * 52)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: samples)
        .onChange(of: level) { _, newValue in
            samples.removeFirst()
            samples.append(newValue)
        }
    }
}

private struct ProcessingView: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Theme.stroke, lineWidth: 6)
                    .frame(width: 88, height: 88)
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)
            }
            Text("Transcribing…")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Your audio is on its way to ElevenLabs.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcribing your recording")
    }
}

private struct TranscriptEditor: View {
    @ObservedObject var model: AppModel
    @FocusState private var isEditing: Bool

    private var trimmedText: String {
        model.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(1)
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Text("\(model.transcriptText.count) characters")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .accessibilityHidden(true)
            }

            TextEditor(text: $model.transcriptText)
                .focused($isEditing)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 20).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke))
                .accessibilityLabel("Transcript text, editable")

            HStack(spacing: 10) {
                Button {
                    isEditing = false
                    model.copyTranscript()
                } label: {
                    Label(
                        model.copiedRecently ? "Copied" : "Copy",
                        systemImage: model.copiedRecently ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .accessibilityHint("Puts the transcript on the clipboard.")

                ShareLink(item: trimmedText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Theme.surface))
                        .overlay(Circle().stroke(Theme.stroke))
                }
                .accessibilityLabel("Share transcript")

                Button {
                    isEditing = false
                    model.clearTranscript()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Theme.surface))
                        .overlay(Circle().stroke(Theme.stroke))
                }
                .accessibilityLabel("Clear transcript")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

private struct ErrorCard: View {
    @ObservedObject var model: AppModel
    let message: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .font(.body.weight(.semibold))
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if model.needsMicrophoneSettings {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(QuietPillButtonStyle())
                } else if !model.hasAPIKey {
                    Button {
                        model.showSettings = true
                    } label: {
                        Label("Add API key", systemImage: "key.fill")
                    }
                    .buttonStyle(QuietPillButtonStyle())
                } else {
                    Button {
                        model.retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(QuietPillButtonStyle())
                    .accessibilityHint("Sends the kept recording to ElevenLabs again.")
                }

                Button("Dismiss") {
                    model.dismissError()
                    model.needsMicrophoneSettings = false
                }
                .buttonStyle(QuietPillButtonStyle(tint: Theme.inkMuted))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Theme.danger.opacity(0.35))
        )
    }
}

private struct RecordControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var buttonSize: CGFloat = 88

    var body: some View {
        ZStack {
            recordButton

            HStack {
                if model.isRecording {
                    Button {
                        model.cancelRecording()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Theme.surface))
                            .overlay(Circle().stroke(Theme.stroke))
                    }
                    .accessibilityLabel("Cancel recording")
                    .accessibilityHint("Discards the audio without transcribing.")
                    .transition(.opacity)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.isRecording)
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            ZStack {
                if model.isRecording && !reduceMotion {
                    Circle()
                        .fill(Theme.accent.opacity(0.22))
                        .frame(width: buttonSize, height: buttonSize)
                        .scaleEffect(1 + CGFloat(recorder.level) * 0.5)
                        .animation(.easeOut(duration: 0.1), value: recorder.level)
                }

                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: buttonSize, height: buttonSize)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 6)

                if model.isRecording {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white)
                        .frame(width: buttonSize * 0.32, height: buttonSize * 0.32)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: buttonSize * 0.34, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canStartRecording)
        .opacity(model.canStartRecording ? 1 : 0.4)
        .accessibilityLabel(model.isRecording ? "Stop dictation" : "Start dictation")
        .accessibilityHint(
            model.isRecording
                ? "Stops recording and transcribes what you said."
                : "Starts recording your voice."
        )
    }
}
