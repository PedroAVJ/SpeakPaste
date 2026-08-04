import AppKit
import Combine
import SwiftUI

@MainActor
private final class MacDashboardWindowController: NSObject, NSWindowDelegate {
    private let presence: MacApplicationPresenceCoordinator
    private let window: NSWindow

    init(model: MacAppModel, presence: MacApplicationPresenceCoordinator) {
        self.presence = presence

        let content = MacContentView()
            .environmentObject(model)
            .environmentObject(presence)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        self.window = window

        super.init()

        window.title = "SpeakPaste"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 680))
        window.contentMinSize = NSSize(width: 480, height: 580)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("SpeakPasteDashboard")
        window.delegate = self
    }

    func show() {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !window.isVisible, !window.setFrameUsingName("SpeakPasteDashboard") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        presence.dashboardDidClose()
    }
}

/// Owns everything that must exist only in the process holding the app lease.
/// A secondary launch therefore never initializes `MacAppModel` and cannot
/// migrate defaults, recovery journals, or History before it terminates.
@MainActor
private final class MacAppRuntime: ObservableObject {
    let model: MacAppModel?
    let statusHUD: MacStatusHUDController?
    let realtimeCaretIndicator: MacRealtimeCaretIndicatorController?
    let presence: MacApplicationPresenceCoordinator
    let dashboardWindowController: MacDashboardWindowController?
    let existingApplication: NSRunningApplication?
    let launchFailureMessage: String?

    private let lease: MacSingleInstanceLease?
    private var modelObservation: AnyCancellable?

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        let presence = MacApplicationPresenceCoordinator()
        self.presence = presence
#if SPEAKPASTE_UI_TEST_INSTANCE
        // This code path exists only in a specially compiled QA bundle whose
        // CFFIXED_USER_HOME and TMPDIR are redirected before launch.
        let acquisition = bundleIdentifier.map {
            MacSingleInstanceLease.acquireForIsolatedTesting(
                lockIdentifier: "\($0).isolated-ui-test"
            )
        } ?? .unavailable
        let legacyInstance: NSRunningApplication? = nil
#else
        let acquisition = MacSingleInstanceLease.acquire()
        // Released builds predating the product-wide lease can still be
        // running. Detect them before constructing MacAppModel so a candidate
        // cannot scan or migrate their shared stores.
        let legacyInstance = Self.existingSpeakPasteApplication()
#endif

        switch acquisition {
        case let .acquired(lease):
            guard legacyInstance == nil else {
                self.lease = nil
                self.model = nil
                self.statusHUD = nil
                self.realtimeCaretIndicator = nil
                self.dashboardWindowController = nil
                self.existingApplication = legacyInstance
                self.launchFailureMessage = nil
                self.modelObservation = nil
                return
            }
            let model = MacAppModel()
            let dashboardWindowController = MacDashboardWindowController(
                model: model,
                presence: presence
            )
            self.lease = lease
            self.model = model
            self.statusHUD = MacStatusHUDController(model: model)
            self.realtimeCaretIndicator = MacRealtimeCaretIndicatorController(model: model)
            self.dashboardWindowController = dashboardWindowController
            self.existingApplication = nil
            self.launchFailureMessage = nil
            self.modelObservation = nil
            self.modelObservation = model.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
            presence.installDashboardPresenter { [weak dashboardWindowController] in
                dashboardWindowController?.show()
            }
        case .alreadyHeld:
            self.lease = nil
            self.model = nil
            self.statusHUD = nil
            self.realtimeCaretIndicator = nil
            self.dashboardWindowController = nil
            self.existingApplication = legacyInstance ?? Self.existingSpeakPasteApplication()
            self.launchFailureMessage = nil
            self.modelObservation = nil
        case .unavailable:
            self.lease = nil
            self.model = nil
            self.statusHUD = nil
            self.realtimeCaretIndicator = nil
            self.dashboardWindowController = nil
            self.existingApplication = legacyInstance
            self.launchFailureMessage = "SpeakPaste could not create its per-user safety lock, so it did not open or touch local dictation data. Check the permissions on your temporary folder, then try again."
            self.modelObservation = nil
        }
    }

    var isPrimaryInstance: Bool { lease != nil }

    func start() {
        guard let model else { return }
        statusHUD?.start()
        realtimeCaretIndicator?.start()
        model.startSessionTracking()
    }

    private static func existingSpeakPasteApplication() -> NSRunningApplication? {
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first { application in
            guard application.processIdentifier != mine, !application.isTerminated else {
                return false
            }
            let executableMatches = application.executableURL?.lastPathComponent == "SpeakPaste"
            let bundleMatches = application.bundleURL?.lastPathComponent == "SpeakPaste.app"
                || application.bundleIdentifier?.localizedCaseInsensitiveContains("speakpaste") == true
            return executableMatches && bundleMatches
        }
    }
}

/// Terminates a secondary launch after the process lease has already prevented
/// it from constructing app state. The running copy is brought forward when
/// Launch Services can identify it.
@MainActor
final class MacSingleInstanceGuard: NSObject, NSApplicationDelegate {
    private weak var model: MacAppModel?
    private weak var existingApplication: NSRunningApplication?
    private weak var presence: MacApplicationPresenceCoordinator?
    private var isPrimaryInstance = false
    private var launchFailureMessage: String?
    private var terminationReplyPending = false
    private var startPrimaryRuntime: (() -> Void)?

    fileprivate func configure(runtime: MacAppRuntime) {
        model = runtime.model
        existingApplication = runtime.existingApplication
        presence = runtime.presence
        isPrimaryInstance = runtime.isPrimaryInstance
        launchFailureMessage = runtime.launchFailureMessage
        startPrimaryRuntime = { [weak runtime] in runtime?.start() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if isPrimaryInstance {
            presence?.establishLaunchPolicy()
            return
        }
        existingApplication?.activate(options: [])
        if let launchFailureMessage {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "SpeakPaste did not start"
            alert.informativeText = launchFailureMessage
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isPrimaryInstance else { return }
        // Bootstrap recording recovery, the global hotkey, the HUD observer,
        // and session tracking independently of every visible UI surface.
        startPrimaryRuntime?()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard isPrimaryInstance else { return false }
        presence?.openDashboard()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationReplyPending else { return .terminateLater }

        terminationReplyPending = true
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let mayTerminate = await model.prepareForTermination()
            self.terminationReplyPending = false
            if !mayTerminate {
                sender?.activate(ignoringOtherApps: true)
            }
            sender?.reply(toApplicationShouldTerminate: mayTerminate)
        }
        return .terminateLater
    }
}

@main
struct SpeakPasteMacApp: App {
    @NSApplicationDelegateAdaptor(MacSingleInstanceGuard.self) private var singleInstance
    @StateObject private var runtime: MacAppRuntime

    init() {
        let runtime = MacAppRuntime()
        _runtime = StateObject(wrappedValue: runtime)
        singleInstance.configure(runtime: runtime)
    }

    var body: some Scene {
        Settings {
            if let model = runtime.model {
                MacSettingsView()
                    .environmentObject(model)
                    .environmentObject(runtime.presence)
                    .onAppear { runtime.presence.settingsDidAppear() }
                    .onDisappear { runtime.presence.settingsDidDisappear() }
            } else {
                EmptyView()
            }
        }

        MenuBarExtra {
            if let model = runtime.model {
                MacMenuBarView()
                    .environmentObject(model)
                    .environmentObject(runtime.presence)
            }
        } label: {
            if let model = runtime.model {
                Image(systemName: menuBarSymbol(for: model))
                    .accessibilityLabel(menuBarAccessibilityLabel(for: model))
            } else {
                EmptyView()
            }
        }
    }

    private func menuBarSymbol(for model: MacAppModel) -> String {
        return switch model.phase {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .recording: "record.circle.fill"
        case .finalizing: "stop.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .ready:
            readinessIssue(for: model) != nil
                ? "exclamationmark.triangle.fill"
                : (model.networkIsAvailable ? "waveform" : "wifi.slash")
        }
    }

    private func menuBarAccessibilityLabel(for model: MacAppModel) -> String {
        switch model.phase {
        case .connecting: "SpeakPaste, connecting to microphone"
        case .recording: "SpeakPaste, recording. Speak now. Press the Right Command key to stop and transcribe"
        case .finalizing: "SpeakPaste, recording stopped. Releasing microphone"
        case .succeeded: "SpeakPaste, done"
        case .failed: "SpeakPaste, error"
        case .ready:
            if let readinessIssue = readinessIssue(for: model) {
                "SpeakPaste, setup needed. \(readinessIssue)"
            } else if !model.networkIsAvailable {
                "SpeakPaste, offline. Recordings remain saved and retry when the connection returns"
            } else {
                "SpeakPaste, ready. Press the Right Command key to start"
            }
        }
    }

    private func readinessIssue(for model: MacAppModel) -> String? {
        if !model.hasAPIKey { return "Add an ElevenLabs API key" }
        if model.selectedDevice == nil { return "Choose a microphone" }
        if model.permissions.granted[.microphone] != true { return "Grant microphone access" }
        return nil
    }
}

struct MacMenuBarView: View {
    @EnvironmentObject private var model: MacAppModel
    @EnvironmentObject private var presence: MacApplicationPresenceCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        captureItems
        queueItems

        Divider()

        lastTranscriptItems

        Divider()

        appItems

        Divider()

        microphoneStatus

        Divider()

        Button("Quit SpeakPaste") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var captureItems: some View {
        if !model.networkIsAvailable {
            Text("OFFLINE — recordings stay saved and retry on reconnect")
        }
        switch model.phase {
        case .connecting:
            Button("WAIT — connecting; do not speak yet") {}
                .disabled(true)
            Button("Cancel  \(model.cancelHotKeyLabel)") { model.requestRecordingCancellation() }
                .accessibilityLabel("Cancel connecting, Escape key")
        case .recording:
            Button("SPEAK NOW — Stop & Transcribe  \(model.hotKeyLabel)") {
                model.toggleRecording()
            }
            .accessibilityLabel("Stop and transcribe, Right Command key")
            Button("Cancel Recording  \(model.cancelHotKeyLabel)") {
                model.requestRecordingCancellation()
            }
            .accessibilityLabel("Cancel recording immediately, Escape key")
        case .finalizing:
            Button("RELEASING MICROPHONE…") {}
                .disabled(true)
        case let .succeeded(detail):
            Button("DONE — \(detail)") {}
                .disabled(true)
        case let .failed(message):
            Text("ERROR — \(message)")
            Button("Start New Recording  \(model.hotKeyLabel)") { model.toggleRecording() }
                .disabled(!canStartRecording)
                .accessibilityLabel("Start a new recording, Right Command key")
        case .ready:
            if model.inFlightCount > 0 {
                Text("TRANSCRIBING \(model.inFlightCount) — microphone is free")
            }
            Button("Start Recording  \(model.hotKeyLabel)") { model.toggleRecording() }
                .disabled(!canStartRecording)
                .accessibilityLabel("Start recording, Right Command key")
        }
    }

    @ViewBuilder
    private var queueItems: some View {
        if !model.heldTranscripts.isEmpty {
            Button(heldMenuTitle) {
                if model.hasUncertainHeldTranscripts {
                    presence.openDashboard()
                } else {
                    model.releaseHeldTranscripts()
                }
            }
            .accessibilityLabel(
                model.hasUncertainHeldTranscripts
                    ? "Review possibly delivered transcripts in SpeakPaste"
                    : "Paste all waiting transcripts here, Option Command V"
            )
        }
        if !model.retryableFailures.isEmpty {
            Button("Retry \(model.retryableFailures.count) Failed — audio is saved") {
                model.retryAllFailures()
            }
        }
    }

    @ViewBuilder
    private var lastTranscriptItems: some View {
        Button("Paste Last Transcript  \(model.pasteLastHotKeyLabel)") { model.pasteLastTranscript() }
            .disabled(model.transcript.isEmpty)
            .accessibilityLabel("Paste last transcript, Control Command V")
        Button("Copy Last Transcript  \(model.copyLastHotKeyLabel)") { model.copyTranscript() }
            .disabled(model.transcript.isEmpty)
            .accessibilityLabel("Copy last transcript, Control Command C")
    }

    @ViewBuilder
    private var appItems: some View {
        // The whole Scribe catalog is one submenu away, with the original
        // pinned choices on top, so switching languages never requires the
        // Settings window mid-dictation.
        Menu("Language: \(model.language.title)") {
            Picker("Language", selection: $model.language) {
                ForEach(TranscriptionLanguage.macPinnedChoices) { language in
                    Text(language.title).tag(language)
                }
                Divider()
                ForEach(TranscriptionLanguage.macAdditionalChoices) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityLabel("Transcription language, currently \(model.language.title)")
        Button("Open SpeakPaste") {
            presence.openDashboard()
        }
        Button("Settings…") {
            presence.openSettings { openSettings() }
        }
        Button("Replay Onboarding") {
            model.showOnboardingAgain()
            presence.openDashboard()
        }
    }

    @ViewBuilder
    private var microphoneStatus: some View {
        if let readinessMessage {
            Label(readinessMessage, systemImage: "exclamationmark.triangle.fill")
        } else if model.isMicrophoneConnected, let device = model.selectedDevice {
            Text("\(device.name) · \(device.sourceLabel) active — released on stop")
        } else if let device = model.selectedDevice {
            Text("Microphone: \(device.name) · \(device.sourceLabel)")
        } else {
            Text("No microphone available")
        }
    }

    /// "Held" text auto-pastes when its destination regains focus; "recovered"
    /// text (from a previous session) never does. The label must not promise an
    /// automatic paste for transcripts that will only move on this click.
    private var heldMenuTitle: String {
        let count = model.heldTranscripts.count
        if model.hasUncertainHeldTranscripts {
            return "Review \(count) Possibly Delivered  \(model.releaseHotKeyLabel)"
        }
        if model.heldTranscripts.allSatisfy(\.isRecovered) {
            return "Paste \(count) Recovered Here  \(model.releaseHotKeyLabel)"
        }
        return "Paste \(count) Held Here  \(model.releaseHotKeyLabel)"
    }

    private var canStartRecording: Bool {
        model.canStartRecording
    }

    private var readinessMessage: String? {
        if !model.hasAPIKey { return "Setup needed: add an ElevenLabs API key" }
        if model.selectedDevice == nil { return "Setup needed: choose a microphone" }
        if model.permissions.granted[.microphone] != true {
            return "Setup needed: grant microphone access"
        }
        return nil
    }
}
