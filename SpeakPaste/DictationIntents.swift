import AppIntents

/// Bind this to Back Tap (Settings → Accessibility → Touch → Back Tap) through
/// a one-action Shortcut. `openAppWhenRun` stays false so the app you are
/// typing in never loses the screen.
///
/// These intents return no dialog on purpose. A dictation trigger should be
/// invisible; a banner announcing "Listening" every time is worse than
/// silence, and haptics already confirm the state.
///
/// They also return no value. `ReturnsValue<String?>` serializes into the
/// actions database as an unresolvable output type (`typeIdentifier: 0`),
/// and Shortcuts then fails the whole action with "could not be found" —
/// proven on device 2026-08-03. If a wrapper shortcut ever needs the
/// transcript, the output must be a non-optional type, and the start tap
/// then needs a gate that empty text cannot satisfy.
struct ToggleDictationIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription(
        "Start dictating, or stop and hand the transcript to the SpeakPaste keyboard, without leaving the app you are in."
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .background
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await DictationEngine.shared.toggle()
        return .result()
    }
}

struct StartDictationIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription(
        "Begin recording in the background without switching apps."
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .background
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await DictationEngine.shared.start()
        return .result()
    }
}

struct StopDictationIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription(
        "Finish recording, transcribe, and hand the text to the SpeakPaste keyboard."
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await DictationEngine.shared.stop()
        return .result()
    }
}

struct CancelDictationIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel Dictation"
    static let description = IntentDescription("Discard the dictation in progress.")
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        await DictationEngine.shared.cancel()
        return .result()
    }
}

struct SpeakPasteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "\(.applicationName) dictation",
            ],
            shortTitle: "Toggle Dictation",
            systemImageName: "mic.fill"
        )
    }
}
