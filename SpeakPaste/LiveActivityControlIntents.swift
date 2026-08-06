import AppIntents
import Foundation

/// Session-scoped controls embedded in the Live Activity. The same intent
/// declarations are compiled into the widget extension so WidgetKit can render
/// them, while `LiveActivityIntent` asks iOS to execute the app-target copy in
/// SpeakPaste's background process. The UUID guard makes a stranded card from
/// an older session harmless.
private protocol SessionScopedDictationIntent: AppIntent {
    var sessionID: String { get }
}

private extension SessionScopedDictationIntent {
    var parsedSessionID: UUID? { UUID(uuidString: sessionID) }
}

struct PauseDictationIntent: LiveActivityIntent, SessionScopedDictationIntent {
    static let title: LocalizedStringResource = "Pause Dictation"
    static let description = IntentDescription(
        "Release the microphone and bank this segment without ending the dictation."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Dictation Session")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if SPEAKPASTE_LIVE_ACTIVITY_EXTENSION || SPEAKPASTE_KEYBOARD_EXTENSION
        return .result()
        #else
        guard let parsedSessionID else { return .result() }
        try await DictationEngine.shared.pause(
            expectedSessionID: parsedSessionID
        )
        return .result()
        #endif
    }
}

struct ResumeDictationIntent:
    AudioRecordingIntent,
    LiveActivityIntent,
    SessionScopedDictationIntent
{
    static let title: LocalizedStringResource = "Resume Dictation"
    static let description = IntentDescription(
        "Start a new recording segment in the current dictation."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Dictation Session")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if SPEAKPASTE_LIVE_ACTIVITY_EXTENSION || SPEAKPASTE_KEYBOARD_EXTENSION
        return .result()
        #else
        guard let parsedSessionID else { return .result() }
        try await DictationEngine.shared.resume(
            expectedSessionID: parsedSessionID
        )
        return .result()
        #endif
    }
}

struct CancelDictationIntent: LiveActivityIntent, SessionScopedDictationIntent {
    static let title: LocalizedStringResource = "Cancel Dictation"
    static let description = IntentDescription(
        "Close the dictation and keep its audio available for recovery."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Dictation Session")
    var sessionID: String

    init() {
        sessionID = ""
    }

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if SPEAKPASTE_LIVE_ACTIVITY_EXTENSION || SPEAKPASTE_KEYBOARD_EXTENSION
        return .result()
        #else
        guard let parsedSessionID else { return .result() }
        await DictationEngine.shared.cancel(
            expectedSessionID: parsedSessionID
        )
        return .result()
        #endif
    }
}

/// Intent-backed wakeup for the keyboard's Stop & Insert button. The keyboard
/// first claims its exact cursor and writes the shared Stop command, then asks
/// the system to perform this app-target copy. `LiveActivityIntent` keeps the
/// containing app off screen while still reviving a process that iOS suspended
/// during a long, microphone-free pause.
struct StopAndInsertDictationIntent:
    AudioRecordingIntent,
    LiveActivityIntent,
    SessionScopedDictationIntent
{
    static let title: LocalizedStringResource = "Stop Dictation for Insertion"
    static let description = IntentDescription(
        "Finish this dictation and deliver it to the active SpeakPaste keyboard."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Dictation Session")
    var sessionID: String

    init() {
        sessionID = ""
    }

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if SPEAKPASTE_LIVE_ACTIVITY_EXTENSION || SPEAKPASTE_KEYBOARD_EXTENSION
        return .result()
        #else
        guard let parsedSessionID else { return .result() }
        try await DictationEngine.shared.stop(
            expectedSessionID: parsedSessionID
        )
        return .result()
        #endif
    }
}
