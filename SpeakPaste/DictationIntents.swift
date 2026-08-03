import AppIntents

/// Bind this to Back Tap (Settings → Accessibility → Touch → Back Tap) through
/// a one-action Shortcut. `openAppWhenRun` stays false so the app you are
/// typing in never loses the screen.
struct ToggleDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription(
        "Start dictating, or finish and insert the transcript, without leaving the app you are in."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let transcript = try await DictationEngine.shared.toggle() {
            return .result(dialog: IntentDialog("Inserted \(transcript.count) characters"))
        }
        return .result(dialog: IntentDialog("Listening"))
    }
}

struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription(
        "Begin recording in the background without switching apps."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await DictationEngine.shared.start()
        return .result()
    }
}

struct StopDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription(
        "Finish recording, transcribe, and hand the text to the keyboard and clipboard."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let transcript = try await DictationEngine.shared.stop() ?? ""
        return .result(value: transcript)
    }
}

struct CancelDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Dictation"
    static let description = IntentDescription("Discard the dictation in progress.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        DictationEngine.shared.cancel()
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
