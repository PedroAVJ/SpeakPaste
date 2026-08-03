import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ServiceManagement

/// The system grants SpeakPaste runs on. Every one of them can be revoked in
/// System Settings long after the app was installed, and a revoked grant
/// otherwise presents as the app mysteriously not working: the shortcut stops
/// firing, or recording fails, with nothing on screen to explain why.
enum MacPermission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring
    case launchAtLogin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .launchAtLogin: "Open at Login"
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            "Required to record. Without it, dictation fails the moment it starts."
        case .accessibility:
            "Required for the global shortcut and for pasting into the app you were typing in."
        case .inputMonitoring:
            "Optional. Some Macs need it alongside Accessibility before the shortcut sees key presses."
        case .launchAtLogin:
            "Optional. Keeps the shortcut available after a restart without opening SpeakPaste by hand."
        }
    }
}

@MainActor
final class MacPermissionsModel: ObservableObject {
    /// Always carries every case, so a view reading a grant never has to decide
    /// what a missing key means.
    @Published private(set) var granted: [MacPermission: Bool] = [:]

    /// The only change macOS pushes for the accessibility trust list.
    private static let accessibilityChangedNotification = Notification.Name("com.apple.accessibility.api")
    private static let pollInterval: TimeInterval = 2

    private var onChange: (@MainActor () -> Void)?
    private var accessibilityObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    init() {
        granted = Self.currentGrants()
    }

    /// Re-reads every grant. Deliberately silent: this runs on window
    /// activation and on a timer, where a system dialog would be an ambush.
    func refresh() {
        syncGrants()
    }

    /// Watches for grants changed outside the app, and reports only real
    /// transitions. Both halves are needed. The notification is the single push
    /// macOS offers, it covers accessibility alone, and it arrives before this
    /// process's own trust state has caught up; the poll is what makes the
    /// other three grants — and that late trust update — visible at all.
    ///
    /// This is what saves the user who grants Accessibility in System Settings
    /// and goes straight back to their editor rather than to SpeakPaste:
    /// nothing would otherwise re-arm the global shortcut, and it would stay
    /// dead while the checkbox next to it read as on.
    func startObserving(onChange: @escaping @MainActor () -> Void) {
        stopObserving()
        self.onChange = onChange

        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.accessibilityChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncGrants()
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncGrants()
            }
        }
    }

    func stopObserving() {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
        onChange = nil
    }

    /// Asks the system for a grant. Only ever called from an explicit user
    /// action — a prompt raised on launch teaches the user to dismiss it.
    func request(_ permission: MacPermission) {
        switch permission {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncGrants()
                }
            }
        case .accessibility:
            // macOS shows this prompt at most once per app signature; after a
            // denial the call returns silently forever, which is why the row
            // must also offer `openSettings(for:)`. The return value is the
            // answer from *before* the user decides, so it is discarded and the
            // observers above are what report the grant landing.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            syncGrants()
        case .launchAtLogin:
            setLaunchAtLogin(true)
        }
    }

    func openSettings(for permission: MacPermission) {
        guard permission != .launchAtLogin else {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        guard
            let anchor = permission.settingsAnchor,
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Registration fails when the app is somewhere macOS refuses to launch
    /// from — a build running out of DerivedData, most often. The error is not
    /// surfaced because the re-read below already tells the truth: the switch
    /// reports the state macOS actually holds, never the state that was asked
    /// for, so a failed register visibly stays off instead of lying.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
        }
        syncGrants()
    }

    /// Input Monitoring and the login item are conveniences. These two are the
    /// difference between a working app and a dead one.
    var allEssentialGranted: Bool {
        granted[.microphone] == true && granted[.accessibility] == true
    }

    /// The single place `granted` changes, so a grant flipping reaches the
    /// callback whichever observer noticed it, and an unchanged read stays
    /// silent rather than re-arming the shortcut every two seconds.
    private func syncGrants() {
        let current = Self.currentGrants()
        guard current != granted else { return }
        granted = current
        onChange?()
    }

    private static func currentGrants() -> [MacPermission: Bool] {
        Dictionary(uniqueKeysWithValues: MacPermission.allCases.map { ($0, isGranted($0)) })
    }

    private static func isGranted(_ permission: MacPermission) -> Bool {
        switch permission {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        case .launchAtLogin: SMAppService.mainApp.status == .enabled
        }
    }
}

private extension MacPermission {
    /// Anchors inside the Privacy & Security pane. The login item is absent
    /// because System Settings only reaches it through ServiceManagement.
    var settingsAnchor: String? {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .launchAtLogin: nil
        }
    }
}
