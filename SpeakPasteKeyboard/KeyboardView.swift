import SwiftUI

private enum KBTheme {
    static let keyboardBackground = Color(red: 0.82, green: 0.84, blue: 0.87)
    static let key = Color(red: 0.99, green: 0.99, blue: 1.0)
    static let utilityKey = Color(red: 0.67, green: 0.70, blue: 0.74)
    static let ink = Color(red: 0.08, green: 0.09, blue: 0.10)
    static let inkMuted = Color(red: 0.34, green: 0.36, blue: 0.39)
    static let accent = Color(red: 0.94, green: 0.40, blue: 0.20)
    static let accentSoft = Color(red: 1.0, green: 0.89, blue: 0.83)
    static let danger = Color(red: 0.85, green: 0.18, blue: 0.16)

    static func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct KBKeyButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
                    .shadow(
                        color: .black.opacity(configuration.isPressed ? 0.04 : 0.22),
                        radius: configuration.isPressed ? 0 : 0.5,
                        y: configuration.isPressed ? 0 : 1.5
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

private struct KBKey: View {
    var text: String?
    var systemImage: String?
    var width: CGFloat?
    var fill = KBTheme.key
    var foreground = KBTheme.ink
    var font: Font = .system(size: 21)
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                } else {
                    Text(text ?? "")
                        .font(font)
                }
            }
        }
        .buttonStyle(KBKeyButtonStyle(fill: fill, foreground: foreground))
        .frame(
            minWidth: width,
            maxWidth: width ?? .infinity,
            minHeight: 40,
            maxHeight: 40
        )
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct KBStatusButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private enum KeyPlane {
    case letters
    case numbers
    case symbols
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShifted = false
    @State private var plane: KeyPlane = .letters

    private let letterRows = [
        Array("qwertyuiop"),
        Array("asdfghjkl"),
        Array("zxcvbnm"),
    ]
    private let numberRows = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
    ]
    private let symbolRows = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
    ]
    private let punctuationRow = [".", ",", "?", "!", "'"]

    var body: some View {
        Group {
            if !model.hasFullAccess {
                fullAccessPanel
            } else if let errorMessage {
                errorPanel(errorMessage)
            } else if model.isLaunching {
                launchingPanel
            } else if model.isRecording {
                recordingPanel
            } else if model.isTranscribing {
                processingPanel
            } else {
                typingKeyboard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KBTheme.keyboardBackground.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.snapshot.phase
        )
    }

    private var typingKeyboard: some View {
        VStack(spacing: 5) {
            accessoryBar

            if plane == .letters {
                letterKeyboard
            } else {
                numberKeyboard
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 5)
        .padding(.bottom, 4)
    }

    private var accessoryBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(KBTheme.accent)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(KBTheme.accentSoft))

                Text("SpeakPaste")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KBTheme.inkMuted)
            }

            Spacer(minLength: 8)

            Button(action: model.startDictation) {
                HStack(spacing: 5) {
                    Text("Start")
                    Image(systemName: "waveform")
                }
            }
            .buttonStyle(
                KBStatusButtonStyle(
                    fill: KBTheme.accent,
                    foreground: .white
                )
            )
            .frame(height: 32)
            .accessibilityLabel("Start dictation")
            .accessibilityHint("Briefly opens SpeakPaste and starts recording.")
        }
        .frame(height: 34)
        .padding(.horizontal, 5)
    }

    private var letterKeyboard: some View {
        VStack(spacing: 5) {
            keyRow(letterRows[0])
            keyRow(letterRows[1])
                .padding(.horizontal, 17)

            HStack(spacing: 5) {
                KBKey(
                    systemImage: isShifted ? "shift.fill" : "shift",
                    width: 44,
                    fill: isShifted ? KBTheme.key : KBTheme.utilityKey,
                    accessibilityLabel: isShifted ? "Shift on" : "Shift"
                ) {
                    isShifted.toggle()
                }

                keyRow(letterRows[2])

                KBKey(
                    systemImage: "delete.left",
                    width: 44,
                    fill: KBTheme.utilityKey,
                    accessibilityLabel: "Delete"
                ) {
                    model.backspace()
                }
            }

            functionalRow(modeLabel: "123") {
                plane = .numbers
                isShifted = false
            }
        }
    }

    private var numberKeyboard: some View {
        let rows = plane == .symbols ? symbolRows : numberRows
        return VStack(spacing: 5) {
            textKeyRow(rows[0])
            textKeyRow(rows[1])
                .padding(.horizontal, 9)

            HStack(spacing: 5) {
                KBKey(
                    text: plane == .symbols ? "123" : "#+=",
                    width: 44,
                    fill: KBTheme.utilityKey,
                    font: .system(size: 14, weight: .medium),
                    accessibilityLabel: plane == .symbols
                        ? "Numbers"
                        : "More symbols"
                ) {
                    plane = plane == .symbols ? .numbers : .symbols
                }

                textKeyRow(punctuationRow)

                KBKey(
                    systemImage: "delete.left",
                    width: 44,
                    fill: KBTheme.utilityKey,
                    accessibilityLabel: "Delete"
                ) {
                    model.backspace()
                }
            }

            functionalRow(modeLabel: "ABC") {
                plane = .letters
            }
        }
    }

    private func keyRow(_ characters: [Character]) -> some View {
        HStack(spacing: 5) {
            ForEach(characters, id: \.self) { character in
                let value = isShifted
                    ? String(character).uppercased()
                    : String(character)
                KBKey(
                    text: value,
                    accessibilityLabel: value
                ) {
                    model.type(value)
                    isShifted = false
                }
            }
        }
    }

    private func textKeyRow(_ values: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(values, id: \.self) { value in
                KBKey(text: value, accessibilityLabel: value) {
                    model.type(value)
                }
            }
        }
    }

    private func functionalRow(
        modeLabel: String,
        modeAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            KBKey(
                text: modeLabel,
                width: 45,
                fill: KBTheme.utilityKey,
                font: .system(size: 14, weight: .medium),
                accessibilityLabel: modeLabel == "ABC"
                    ? "Letters"
                    : "Numbers and symbols",
                action: modeAction
            )

            KBKey(
                systemImage: "globe",
                width: 39,
                fill: KBTheme.utilityKey,
                accessibilityLabel: "Next keyboard"
            ) {
                model.nextKeyboard()
            }

            KBKey(text: ",", width: 34, accessibilityLabel: "Comma") {
                model.type(",")
            }

            KBKey(
                text: "space",
                font: .system(size: 15),
                accessibilityLabel: "Space"
            ) {
                model.type(" ")
            }

            KBKey(text: ".", width: 34, accessibilityLabel: "Period") {
                model.type(".")
            }

            KBKey(
                text: "return",
                width: 57,
                fill: KBTheme.utilityKey,
                font: .system(size: 13, weight: .medium),
                accessibilityLabel: "Return"
            ) {
                model.type("\n")
            }
        }
    }

    private var launchingPanel: some View {
        statusShell {
            ProgressView()
                .tint(KBTheme.accent)
                .controlSize(.large)
            Text("Opening SpeakPaste…")
                .font(.headline)
                .foregroundStyle(KBTheme.ink)
            Text("This should only take a moment.")
                .font(.caption)
                .foregroundStyle(KBTheme.inkMuted)
        }
    }

    private var recordingPanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)

            TimelineView(.periodic(from: model.snapshot.startedAt, by: 1)) { context in
                let elapsed = max(
                    0,
                    context.date.timeIntervalSince(model.snapshot.startedAt)
                )
                VStack(spacing: 10) {
                    HStack(alignment: .center, spacing: 3) {
                        ForEach(0..<13, id: \.self) { index in
                            Capsule()
                                .fill(KBTheme.ink)
                                .frame(
                                    width: 3,
                                    height: CGFloat(8 + ((index * 7) % 23))
                                )
                        }
                    }
                    .accessibilityHidden(true)

                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(KBTheme.danger)
                            .symbolEffect(
                                .pulse,
                                options: .repeating,
                                isActive: !reduceMotion
                            )
                            .accessibilityHidden(true)
                        Text("Listening · \(KBTheme.timeString(elapsed))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(KBTheme.inkMuted)
                            .monospacedDigit()
                    }
                    .accessibilityLabel(
                        "Recording, \(KBTheme.timeString(elapsed)) elapsed"
                    )
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(action: model.cancel) {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(
                    KBStatusButtonStyle(
                        fill: KBTheme.key,
                        foreground: KBTheme.inkMuted
                    )
                )
                .accessibilityHint("Discards the recording without typing anything.")

                Button(action: model.stopAndTranscribe) {
                    Label("Stop & Insert", systemImage: "stop.fill")
                }
                .buttonStyle(
                    KBStatusButtonStyle(
                        fill: KBTheme.accent,
                        foreground: .white
                    )
                )
                .accessibilityHint("Stops recording and types the transcript here.")
            }

            Spacer(minLength: 8)

            utilityFooter
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 5)
    }

    private var processingPanel: some View {
        statusShell {
            ProgressView()
                .tint(KBTheme.accent)
                .controlSize(.large)
            Text("Transcribing…")
                .font(.headline)
                .foregroundStyle(KBTheme.ink)
            Text("Your words will appear at the cursor.")
                .font(.caption)
                .foregroundStyle(KBTheme.inkMuted)
        }
    }

    private var fullAccessPanel: some View {
        statusShell {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 25))
                .foregroundStyle(KBTheme.accent)
            Text("Allow Full Access")
                .font(.headline)
                .foregroundStyle(KBTheme.ink)
            Text("Enable it in Settings › General › Keyboard › Keyboards › SpeakPaste.")
                .font(.caption)
                .foregroundStyle(KBTheme.inkMuted)
                .multilineTextAlignment(.center)
            Button("Open SpeakPaste", action: model.openSpeakPaste)
                .buttonStyle(
                    KBStatusButtonStyle(
                        fill: KBTheme.ink,
                        foreground: .white
                    )
                )
        }
    }

    private func errorPanel(_ message: String) -> some View {
        statusShell {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(KBTheme.danger)
            Text(message)
                .font(.footnote)
                .foregroundStyle(KBTheme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            HStack(spacing: 8) {
                if model.didFail && model.localError == nil {
                    Button("Retry", action: model.retry)
                        .buttonStyle(
                            KBStatusButtonStyle(
                                fill: KBTheme.accentSoft,
                                foreground: KBTheme.accent
                            )
                        )
                }
                Button("Dismiss", action: model.dismissError)
                    .buttonStyle(
                        KBStatusButtonStyle(
                            fill: KBTheme.ink,
                            foreground: .white
                        )
                    )
            }
        }
    }

    private var errorMessage: String? {
        if let localError = model.localError { return localError }
        if model.didFail {
            return model.snapshot.errorMessage ?? "Dictation failed. Try again."
        }
        return nil
    }

    private func statusShell<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 4)
            content()
            Spacer(minLength: 4)
            utilityFooter
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var utilityFooter: some View {
        HStack {
            Button(action: model.nextKeyboard) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 38, height: 32)
                    .background(Capsule().fill(KBTheme.utilityKey.opacity(0.7)))
            }
            .foregroundStyle(KBTheme.ink)
            .accessibilityLabel("Next keyboard")

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .foregroundStyle(KBTheme.accent)
                Text("SpeakPaste")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(KBTheme.inkMuted)
            .accessibilityHidden(true)
        }
    }
}
