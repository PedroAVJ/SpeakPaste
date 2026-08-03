import AppIntents

/// Bind this to Back Tap (Settings → Accessibility → Touch → Back Tap) through
/// a one-action Shortcut. `openAppWhenRun` stays false so the app you are
/// typing in never loses the screen.
///
/// These intents return no dialog on purpose. A dictation trigger should be
/// invisible; a banner announcing "Listening" every time is worse than
/// silence, and haptics already confirm the state.
///
/// Toggle and Stop return the transcript as an optional value: the app's own
/// background pasteboard write is the shipping delivery, and the output lets
/// a wrapper shortcut take over copying if that write ever proves unreliable.
/// The start tap returns nil — a genuine no-value, never empty text, so a
/// "has any value" gate in a shortcut cannot fire on it and wipe the
/// clipboard. The current one-action wrapper ignores the output entirely.
struct ToggleDictationIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription(
        "Start dictating, or finish and insert the transcript, without leaving the app you are in."
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .background
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        let transcript = try await DictationEngine.shared.toggle()
        return .result(value: transcript)
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
        "Finish recording, transcribe, and hand the text to the keyboard and clipboard."
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        let transcript = try await DictationEngine.shared.stop()
        return .result(value: transcript)
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
