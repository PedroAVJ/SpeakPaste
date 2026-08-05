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
            self.dashboardWindowController = nil
            self.existingApplication = legacyInstance ?? Self.existingSpeakPasteApplication()
            self.launchFailureMessage = nil
            self.modelObservation = nil
        case .unavailable:
            self.lease = nil
            self.model = nil
            self.statusHUD = nil
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

        // A window, not a menu: the panel is a live picture of the user's own
        // keyboard, and a menu cannot draw one. It is still a menu-bar surface,
        // so opening it never grants Dock or Command-Tab presence.
        MenuBarExtra {
            if let model = runtime.model {
                MacKeyboardMapPanel()
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
        .menuBarExtraStyle(.window)
    }

    private func menuBarSymbol(for model: MacAppModel) -> String {
        return switch model.phase {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .recording: "record.circle.fill"
        case .finalizing: "stop.circle"
        case .paused: "pause.circle.fill"
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
        case .recording: "SpeakPaste, recording. Speak now. Press the same source key again to pause, or the Function key to end and deliver"
        case .finalizing: "SpeakPaste, recording stopped. Releasing microphone"
        case .paused: "SpeakPaste, dictation resting. Nothing has been delivered. Press the Function key to deliver it"
        case .succeeded: "SpeakPaste, done"
        case .failed: "SpeakPaste, error"
        case .ready:
            if let readinessIssue = readinessIssue(for: model) {
                "SpeakPaste, setup needed. \(readinessIssue)"
            } else if !model.networkIsAvailable {
                "SpeakPaste, offline. Recordings remain saved and retry when the connection returns"
            } else {
                "SpeakPaste, ready. Press the Right Command key to dictate through this Mac, or the Right Option key to dictate through your iPhone"
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
