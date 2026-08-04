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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .scaleEffect(
                reduceMotion ? 1 : (configuration.isPressed ? 0.96 : 1)
            )
            .offset(y: reduceMotion ? 0 : (configuration.isPressed ? 1 : 0))
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
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

/// A keyboard delete key begins deleting immediately, then repeats while held.
/// SwiftUI's `Button` only fires on release, so this small control owns the
/// touch-down lifecycle while retaining an explicit VoiceOver action.
private struct KBRepeatingKey: View {
    var width: CGFloat
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(KBTheme.ink)
            .frame(
                minWidth: width,
                maxWidth: width,
                minHeight: 40,
                maxHeight: 40
            )
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(KBTheme.utilityKey)
                    .shadow(
                        color: .black.opacity(isPressed ? 0.04 : 0.22),
                        radius: isPressed ? 0 : 0.5,
                        y: isPressed ? 0 : 1.5
                    )
            )
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.96 : 1))
            .offset(y: reduceMotion ? 0 : (isPressed ? 1 : 0))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        beginPress()
                    }
                    .onEnded { _ in
                        endPress()
                    }
            )
            .onDisappear(perform: endPress)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Touch and hold to delete continuously.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                action()
            }
    }

    private func beginPress() {
        isPressed = true
        action()
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }

            var repeatCount = 0
            while !Task.isCancelled {
                action()
                repeatCount += 1

                // Character deletion starts deliberately, then catches up to
                // a long hold without suddenly erasing an entire word.
                let delay: Duration = if repeatCount < 12 {
                    .milliseconds(88)
                } else if repeatCount < 30 {
                    .milliseconds(58)
                } else {
                    .milliseconds(38)
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func endPress() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}

private struct KBCharacterKey: View {
    let text: String
    let alternatives: [String]
    let accessibilityLabel: String
    let action: () -> Void
    let alternativeAction: (String) -> Void

    var body: some View {
        Menu {
            ForEach(alternatives, id: \.self) { alternative in
                Button(alternative) {
                    alternativeAction(alternative)
                }
                .accessibilityLabel(alternative)
            }
        } label: {
            Text(text)
                .font(.system(size: 21))
        } primaryAction: {
            action()
        }
        .buttonStyle(
            KBKeyButtonStyle(fill: KBTheme.key, foreground: KBTheme.ink)
        )
        .frame(minHeight: 40, maxHeight: 40)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            alternatives.isEmpty
                ? ""
                : "Touch and hold for accented characters."
        )
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

enum KeyboardShiftState: Equatable {
    case lowercase
    case shifted
    case capsLocked

    var usesUppercase: Bool {
        self != .lowercase
    }
}

enum KeyboardCapitalizationMode: Equatable {
    case none
    case words
    case sentences
    case allCharacters
}

enum KeyboardReturnKey: Equatable {
    case `return`
    case go
    case google
    case join
    case next
    case route
    case search
    case send
    case yahoo
    case done
    case emergencyCall
    case `continue`

    var label: String {
        switch self {
        case .return: "return"
        case .go: "go"
        case .google: "Google"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .search: "search"
        case .send: "send"
        case .yahoo: "Yahoo"
        case .done: "done"
        case .emergencyCall: "emergency"
        case .continue: "continue"
        }
    }

    var accessibilityLabel: String {
        self == .emergencyCall ? "Emergency call" : label
    }
}

/// The host-specific facts the SwiftUI keyboard needs for field-aware
/// capitalization and Return labels.
struct KeyboardDocumentContext: Equatable {
    var textBeforeInput: String?
    var capitalization: KeyboardCapitalizationMode
    var returnKey: KeyboardReturnKey

    static let unavailable = KeyboardDocumentContext(
        textBeforeInput: nil,
        capitalization: .sentences,
        returnKey: .return
    )

    init(
        textBeforeInput: String?,
        capitalization: KeyboardCapitalizationMode = .sentences,
        returnKey: KeyboardReturnKey = .return
    ) {
        self.textBeforeInput = textBeforeInput
        self.capitalization = capitalization
        self.returnKey = returnKey
    }

    init(
        textBeforeInput: String?,
        autocapitalizationType: UITextAutocapitalizationType?,
        returnKeyType: UIReturnKeyType?
    ) {
        self.textBeforeInput = textBeforeInput
        self.capitalization = switch autocapitalizationType ?? .sentences {
        case .none: .none
        case .words: .words
        case .sentences: .sentences
        case .allCharacters: .allCharacters
        @unknown default: .sentences
        }
        self.returnKey = switch returnKeyType ?? .default {
        case .default: .return
        case .go: .go
        case .google: .google
        case .join: .join
        case .next: .next
        case .route: .route
        case .search: .search
        case .send: .send
        case .yahoo: .yahoo
        case .done: .done
        case .emergencyCall: .emergencyCall
        case .continue: .continue
        @unknown default: .return
        }
    }
}

struct KeyboardTypingEdit: Equatable {
    var deletedCharacters = 0
    var insertedText: String
}

/// Pure, deterministic typing behavior backed by a bounded suffix of the
/// host's document context.
struct KeyboardTypingState: Equatable {
    private static let maximumTrackedCharacters = 160
    private static let capsLockTapInterval: TimeInterval = 0.4
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
    private static let safeDoubleSpaceClosers: Set<Character> = [
        ")", "]", "}",
    ]

    private(set) var shiftState: KeyboardShiftState = .shifted
    private(set) var returnKey: KeyboardReturnKey = .return
    private(set) var trackedContext = ""
    private(set) var capitalization: KeyboardCapitalizationMode = .sentences

    private var hasAuthoritativeContext = false
    private var manualShiftOverride = false
    private var lastShiftTapAt: Date?

    init(documentContext: KeyboardDocumentContext = .unavailable) {
        synchronize(with: documentContext)
    }

    mutating func synchronize(with documentContext: KeyboardDocumentContext) {
        capitalization = documentContext.capitalization
        returnKey = documentContext.returnKey

        if let textBeforeInput = documentContext.textBeforeInput {
            trackedContext = Self.tail(of: textBeforeInput)
            hasAuthoritativeContext = true
        }

        applyAutomaticShiftIfAllowed()
    }

    mutating func tapShift(at date: Date = Date()) {
        switch shiftState {
        case .lowercase:
            shiftState = .shifted
            manualShiftOverride = true
            lastShiftTapAt = date

        case .shifted:
            if
                manualShiftOverride,
                let lastShiftTapAt,
                date.timeIntervalSince(lastShiftTapAt)
                    <= Self.capsLockTapInterval
            {
                shiftState = .capsLocked
                self.lastShiftTapAt = nil
            } else {
                shiftState = .lowercase
                manualShiftOverride = true
                lastShiftTapAt = nil
            }

        case .capsLocked:
            shiftState = .lowercase
            manualShiftOverride = true
            lastShiftTapAt = nil
        }
    }

    mutating func letter(_ value: String) -> String {
        let output = shiftState.usesUppercase
            ? value.uppercased()
            : value.lowercased()
        append(output)

        if shiftState != .capsLocked {
            manualShiftOverride = false
            applyAutomaticShiftIfAllowed()
        }
        return output
    }

    mutating func insert(_ text: String) {
        append(text)
        if text.contains("\n"), shiftState != .capsLocked {
            manualShiftOverride = false
        }
        applyAutomaticShiftIfAllowed()
    }

    mutating func space() -> KeyboardTypingEdit {
        if Self.shouldReplaceDoubleSpace(in: trackedContext) {
            trackedContext.removeLast()
            append(". ")
            if shiftState != .capsLocked {
                manualShiftOverride = false
            }
            applyAutomaticShiftIfAllowed()
            return KeyboardTypingEdit(
                deletedCharacters: 1,
                insertedText: ". "
            )
        }

        append(" ")
        applyAutomaticShiftIfAllowed()
        return KeyboardTypingEdit(insertedText: " ")
    }

    mutating func deleteBackward() {
        if !trackedContext.isEmpty {
            trackedContext.removeLast()
        } else if hasAuthoritativeContext {
            // The tracked suffix was exhausted. Until the host publishes a
            // fresh context, do not infer punctuation beyond this boundary.
            hasAuthoritativeContext = false
        }
        applyAutomaticShiftIfAllowed()
    }

    private mutating func append(_ text: String) {
        trackedContext.append(contentsOf: text)
        trackedContext = Self.tail(of: trackedContext)
    }

    private mutating func applyAutomaticShiftIfAllowed() {
        guard shiftState != .capsLocked, !manualShiftOverride else { return }
        shiftState = shouldAutomaticallyShift ? .shifted : .lowercase
    }

    private var shouldAutomaticallyShift: Bool {
        switch capitalization {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard let last = trackedContext.last else { return true }
            return last.isWhitespace
        case .sentences:
            guard !trackedContext.isEmpty else { return true }

            let trailingWhitespace = trackedContext.reversed().prefix {
                $0 == " " || $0 == "\t"
            }
            let beforeTrailingWhitespace = trackedContext.dropLast(
                trailingWhitespace.count
            )
            guard let last = beforeTrailingWhitespace.last else { return true }
            return last == "\n" || Self.sentenceTerminators.contains(last)
        }
    }

    private static func shouldReplaceDoubleSpace(in context: String) -> Bool {
        guard context.last == " " else { return false }
        guard let preceding = context.dropLast().last else { return false }
        return preceding.isLetter
            || preceding.isNumber
            || safeDoubleSpaceClosers.contains(preceding)
    }

    private static func tail(of text: String) -> String {
        String(text.suffix(maximumTrackedCharacters))
    }
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typingState: KeyboardTypingState
    @State private var plane: KeyPlane = .letters

    private let documentContext: () -> KeyboardDocumentContext

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

    private let alternateCharacters: [Character: [String]] = [
        "a": ["á", "à", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["é", "è", "ê", "ë", "ē", "ė", "ę"],
        "i": ["í", "ì", "î", "ï", "ī", "į"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ó", "ò", "ô", "ö", "õ", "ø", "œ", "ō"],
        "s": ["ß", "ś", "š"],
        "u": ["ú", "ù", "û", "ü", "ū"],
        "y": ["ý", "ÿ"],
        "z": ["ž", "ź", "ż"],
    ]

    init(
        model: KeyboardModel,
        documentContext: @escaping () -> KeyboardDocumentContext = {
            .unavailable
        }
    ) {
        self.model = model
        self.documentContext = documentContext
        _typingState = State(
            initialValue: KeyboardTypingState(
                documentContext: documentContext()
            )
        )
    }

    var body: some View {
        Group {
            if !model.hasFullAccess {
                fullAccessPanel
            } else if let errorMessage {
                errorPanel(errorMessage)
            } else if model.isStarting {
                startingPanel
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
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.snapshot.phase
        )
        .onAppear(perform: synchronizeTypingContext)
        .onReceive(model.$snapshot) { _ in
            synchronizeTypingContext()
        }
        .onChange(of: model.snapshot.phase) { _, phase in
            announceStatusChange(phaseAnnouncement(for: phase))
        }
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
                Image(systemName: model.recentlyInserted ? "checkmark" : "waveform")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(KBTheme.accent)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(KBTheme.accentSoft))

                Text(model.recentlyInserted ? "Inserted" : "SpeakPaste")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KBTheme.inkMuted)
            }

            Spacer(minLength: 8)

            Button(action: model.startDictation) {
                HStack(spacing: 5) {
                    Text(model.isPreparingHost ? "Preparing" : "Start")
                    if model.isPreparingHost {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    } else {
                        Image(systemName: "waveform")
                    }
                }
            }
            .buttonStyle(
                KBStatusButtonStyle(
                    fill: KBTheme.accent,
                    foreground: .white
                )
            )
            .frame(height: 32)
            .disabled(model.isPreparingHost)
            .accessibilityLabel(
                model.isPreparingHost
                    ? "Preparing dictation"
                    : "Start dictation"
            )
            .accessibilityHint(
                "Briefly opens SpeakPaste, starts recording, and returns here."
            )
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
                    systemImage: shiftSystemImage,
                    width: 44,
                    fill: shiftKeyFill,
                    foreground: shiftKeyForeground,
                    accessibilityLabel: shiftAccessibilityLabel
                ) {
                    synchronizeTypingContext()
                    typingState.tapShift()
                }

                keyRow(letterRows[2])

                KBRepeatingKey(
                    width: 44,
                    accessibilityLabel: "Delete"
                ) {
                    deleteOneCharacter()
                }
            }

            functionalRow(modeLabel: "123") {
                plane = .numbers
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

                KBRepeatingKey(
                    width: 44,
                    accessibilityLabel: "Delete"
                ) {
                    deleteOneCharacter()
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
                let baseValue = String(character)
                let value = typingState.shiftState.usesUppercase
                    ? baseValue.uppercased()
                    : baseValue
                let alternatives = (alternateCharacters[character] ?? []).map {
                    typingState.shiftState.usesUppercase
                        ? $0.uppercased()
                        : $0
                }
                if alternatives.isEmpty {
                    KBKey(text: value, accessibilityLabel: value) {
                        typeLetter(baseValue)
                    }
                } else {
                    KBCharacterKey(
                        text: value,
                        alternatives: alternatives,
                        accessibilityLabel: value
                    ) {
                        typeLetter(baseValue)
                    } alternativeAction: { alternative in
                        typeLetter(alternative)
                    }
                }
            }
        }
    }

    private func textKeyRow(_ values: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(values, id: \.self) { value in
                KBKey(text: value, accessibilityLabel: value) {
                    typeText(value)
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
                typeText(",")
            }

            KBKey(
                text: "space",
                font: .system(size: 15),
                accessibilityLabel: "Space"
            ) {
                typeSpace()
            }

            KBKey(text: ".", width: 34, accessibilityLabel: "Period") {
                typeText(".")
            }

            KBKey(
                text: typingState.returnKey.label,
                width: 57,
                fill: KBTheme.utilityKey,
                font: .system(size: 13, weight: .medium),
                accessibilityLabel: typingState.returnKey.accessibilityLabel
            ) {
                typeText("\n")
            }
        }
    }

    private var shiftSystemImage: String {
        switch typingState.shiftState {
        case .lowercase: "shift"
        case .shifted: "shift.fill"
        case .capsLocked: "capslock.fill"
        }
    }

    private var shiftKeyFill: Color {
        switch typingState.shiftState {
        case .lowercase: KBTheme.utilityKey
        case .shifted: KBTheme.key
        case .capsLocked: KBTheme.accentSoft
        }
    }

    private var shiftKeyForeground: Color {
        typingState.shiftState == .capsLocked
            ? KBTheme.accent
            : KBTheme.ink
    }

    private var shiftAccessibilityLabel: String {
        switch typingState.shiftState {
        case .lowercase: "Shift"
        case .shifted: "Shift on"
        case .capsLocked: "Caps lock on"
        }
    }

    private func synchronizeTypingContext() {
        typingState.synchronize(with: documentContext())
    }

    private func typeLetter(_ letter: String) {
        synchronizeTypingContext()
        model.type(typingState.letter(letter))
    }

    private func typeText(_ text: String) {
        synchronizeTypingContext()
        model.type(text)
        typingState.insert(text)
    }

    private func typeSpace() {
        synchronizeTypingContext()
        let edit = typingState.space()
        for _ in 0..<edit.deletedCharacters {
            model.backspace()
        }
        model.type(edit.insertedText)
    }

    private func deleteOneCharacter() {
        synchronizeTypingContext()
        model.backspace()
        typingState.deleteBackward()
    }

    private var startingPanel: some View {
        statusShell {
            ProgressView()
                .tint(KBTheme.accent)
                .controlSize(.large)
            Text(model.startingStatusText)
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
                        foreground: KBTheme.keyboardBackground
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
                    Button(model.recoveryButtonTitle, action: model.retry)
                        .buttonStyle(
                            KBStatusButtonStyle(
                                fill: KBTheme.accentSoft,
                                foreground: KBTheme.accent
                            )
                        )
                }
                if model.canDismissError {
                    Button(
                        model.errorDismissalButtonTitle,
                        action: model.dismissError
                    )
                        .buttonStyle(
                            KBStatusButtonStyle(
                                fill: KBTheme.ink,
                                foreground: KBTheme.keyboardBackground
                            )
                        )
                }
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

    private func phaseAnnouncement(for phase: SharedDictationPhase) -> String {
        switch phase {
        case .launching: "Opening SpeakPaste"
        case .starting: "Starting microphone"
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .completed: "Inserting at the cursor"
        case .inserting: "Confirm whether the transcript was inserted"
        case .deliveryBlocked: "Transcript ready for explicit insertion"
        case .inserted: "Inserted at the cursor"
        case .failed: errorMessage ?? "Dictation failed"
        case .cancelled: "Dictation cancelled"
        case .idle, .handled: "Ready"
        }
    }

    private func announceStatusChange(_ status: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: status
        )
    }
}
