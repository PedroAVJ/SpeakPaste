import SwiftUI
import UIKit

private enum KBTheme {
    /// The system keyboard follows the appearance the host asks for, so these
    /// resolve per trait collection instead of being fixed light values.
    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(
            UIColor { traits in
                let channels = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: channels.0,
                    green: channels.1,
                    blue: channels.2,
                    alpha: 1
                )
            }
        )
    }

    static let keyboardBackground = adaptive(
        light: (0.82, 0.84, 0.87),
        dark: (0.13, 0.13, 0.14)
    )
    static let key = adaptive(
        light: (0.99, 0.99, 1.0),
        dark: (0.42, 0.42, 0.44)
    )
    static let utilityKey = adaptive(
        light: (0.67, 0.70, 0.74),
        dark: (0.27, 0.27, 0.29)
    )
    static let ink = adaptive(
        light: (0.08, 0.09, 0.10),
        dark: (0.98, 0.98, 1.0)
    )
    static let inkMuted = adaptive(
        light: (0.34, 0.36, 0.39),
        dark: (0.72, 0.73, 0.76)
    )
    static let accent = adaptive(
        light: (0.94, 0.40, 0.20),
        dark: (1.0, 0.51, 0.31)
    )
    static let accentSoft = adaptive(
        light: (1.0, 0.89, 0.83),
        dark: (0.29, 0.16, 0.11)
    )
    static let danger = adaptive(
        light: (0.85, 0.18, 0.16),
        dark: (1.0, 0.42, 0.40)
    )

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

    // The keyboard is an inserter, never an initiator: every dictation state is
    // narrated passively in the accessory bar while the typing keyboard stays
    // usable underneath.
    var body: some View {
        typingKeyboard
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KBTheme.keyboardBackground.ignoresSafeArea())
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

    private enum BarStatus {
        case needsFullAccess
        case ready
        case starting
        case listening
        case transcribing
        case inserting
        case inserted
        case failed(String)
    }

    private var barStatus: BarStatus {
        if !model.hasFullAccess { return .needsFullAccess }
        if let errorMessage { return .failed(errorMessage) }
        if model.isStarting { return .starting }
        if model.isRecording { return .listening }
        if model.isTranscribing { return .transcribing }
        if model.recentlyInserted { return .inserted }
        switch model.snapshot.phase {
        case .completed: return .inserting
        default: return .ready
        }
    }

    private var accessoryBar: some View {
        let status = barStatus
        let announcement = statusText(for: status)
        return HStack(spacing: 8) {
            statusChip(for: status)

            Text(announcement)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusTint(for: status))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if case .listening = status {
                TimelineView(
                    .periodic(from: model.snapshot.startedAt, by: 1)
                ) { context in
                    let elapsed = max(
                        0,
                        context.date.timeIntervalSince(model.snapshot.startedAt)
                    )
                    Text(KBTheme.timeString(elapsed))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(KBTheme.danger)
                        .accessibilityLabel(
                            "\(KBTheme.timeString(elapsed)) elapsed"
                        )
                }
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 5)
        .onChange(of: announcement) { _, newValue in
            announceStatusChange(newValue)
        }
    }

    @ViewBuilder
    private func statusChip(for status: BarStatus) -> some View {
        Group {
            switch status {
            case .needsFullAccess:
                chipImage("lock.fill", tint: KBTheme.accent)
            case .ready:
                chipImage("waveform", tint: KBTheme.accent)
            case .starting, .transcribing, .inserting:
                ProgressView()
                    .tint(KBTheme.accent)
                    .scaleEffect(0.7)
                    .frame(width: 25, height: 25)
            case .listening:
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(KBTheme.danger)
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        isActive: !reduceMotion
                    )
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(KBTheme.accentSoft))
            case .inserted:
                chipImage("checkmark", tint: KBTheme.accent)
            case .failed:
                chipImage("exclamationmark.triangle.fill", tint: KBTheme.danger)
            }
        }
        .accessibilityHidden(true)
    }

    private func chipImage(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 25, height: 25)
            .background(Circle().fill(KBTheme.accentSoft))
    }

    private func statusText(for status: BarStatus) -> String {
        switch status {
        case .needsFullAccess:
            "Enable Full Access in Settings to insert"
        case .ready:
            "Ready · Back Tap to dictate"
        case .starting:
            "Starting…"
        case .listening:
            "Listening"
        case .transcribing:
            "Transcribing…"
        case .inserting:
            "Inserting…"
        case .inserted:
            "Inserted at the cursor"
        case let .failed(message):
            recoveryText(for: message)
        }
    }

    private func recoveryText(for message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("background")
            || normalized.contains("screen recording")
        {
            return "Stop other audio or screen recording, then Back Tap"
        }
        if normalized.contains("api key") {
            return "Open SpeakPaste to add your API key"
        }
        if normalized.contains("microphone") {
            return "Open SpeakPaste to enable the microphone"
        }
        if normalized.contains("live activities") {
            return "Open Settings and enable Live Activities"
        }
        if normalized.contains("app group") || normalized.contains("reinstall") {
            return "Reinstall SpeakPaste to restore shared access"
        }
        return "Dictation failed · Back Tap to try again"
    }

    private func statusTint(for status: BarStatus) -> Color {
        if case .failed = status { return KBTheme.danger }
        return KBTheme.inkMuted
    }

    private func announceStatusChange(_ status: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: status
        )
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

    private var errorMessage: String? {
        if let localError = model.localError { return localError }
        if model.didFail {
            return model.snapshot.errorMessage ?? "Dictation failed. Try again."
        }
        return nil
    }
}
