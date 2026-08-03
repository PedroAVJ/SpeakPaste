import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class MacStatusHUDController: ObservableObject {
    /// Idle and result states stay at the original compact size; recording and
    /// connecting grow enough to hold the level meter and the Stop/Cancel
    /// controls without truncating the status text.
    private static let compactPanelSize = NSSize(width: 330, height: 58)
    private static let interactivePanelSize = NSSize(width: 430, height: 64)
    private static let sideCompactPanelSize = NSSize(width: 200, height: 88)
    private static let sideInteractivePanelSize = NSSize(width: 200, height: 122)

    private let model: MacAppModel
    private let panel: MacStatusPanel
    private var stateCancellable: AnyCancellable?
    private var delayedHideTask: Task<Void, Never>?
    /// Screen-space anchors captured when a user drag begins. Non-nil also
    /// suppresses programmatic repositioning so a phase change cannot yank the
    /// HUD out of the user's hand mid-drag.
    private var dragStartPanelOrigin: NSPoint?
    private var dragStartMouseLocation: NSPoint?

    init(model: MacAppModel) {
        self.model = model

        let panel = MacStatusPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Click-through by default. `present` opens mouse interaction only
        // while the recording controls are on screen, so an idle HUD can sit
        // over the target app without intercepting a single click.
        panel.ignoresMouseEvents = true
        // Dragging is handled by the SwiftUI gesture so the panel can dock
        // back to a placement on release; AppKit background dragging stays off.
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none

        let hostingView = MacStatusHUDHostingView(
            rootView: MacStatusHUDView(
                model: model,
                permissions: model.permissions,
                onDragChanged: { [weak self] in self?.handleDragChanged() },
                onDragEnded: { [weak self] in self?.handleDragEnded() }
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: Self.compactPanelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    /// Starts mirroring the app model into the floating panel. Safe to call
    /// repeatedly from a SwiftUI scene lifecycle callback.
    func start() {
        guard stateCancellable == nil else {
            present(model.phase)
            return
        }

        // A held transcript or an in-flight transcription keeps the HUD up on
        // its own, so the panel reacts to all of these. The enabled flag and
        // placement are merged in too, so a settings change applies to a HUD
        // that is already on screen instead of waiting for the next phase.
        stateCancellable = Publishers.MergeMany(
            model.$phase.map { _ in () }.eraseToAnyPublisher(),
            model.$heldTranscripts.map { _ in () }.eraseToAnyPublisher(),
            model.$inFlightCount.map { _ in () }.eraseToAnyPublisher(),
            model.$networkIsAvailable.map { _ in () }.eraseToAnyPublisher(),
            model.$hudEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$hudAlwaysVisible.map { _ in () }.eraseToAnyPublisher(),
            model.$hudPlacement.map { _ in () }.eraseToAnyPublisher(),
            model.$recordingWarning.map { _ in () }.eraseToAnyPublisher(),
            model.$recordingCancelConfirmation.map { _ in () }.eraseToAnyPublisher(),
            model.$hasSavedAPIKey.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedDeviceID.map { _ in () }.eraseToAnyPublisher(),
            model.$devices.map { _ in () }.eraseToAnyPublisher(),
            model.permissions.$granted.map { _ in () }.eraseToAnyPublisher(),
            model.permissions.$isSecureInputEnabled.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in
            // Combine publishers are not actor-annotated. Hop explicitly to
            // the main actor before touching AppKit or the main-actor model.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.present(self.model.phase)
            }
        }
        present(model.phase)
    }

    private func present(_ phase: MacCapturePhase) {
        delayedHideTask?.cancel()
        delayedHideTask = nil

        guard model.hudEnabled else {
            panel.orderOut(nil)
            return
        }

        panel.ignoresMouseEvents = !acceptsMouse(phase)

        switch phase {
        case .ready:
            if model.hudAlwaysVisible || !model.heldTranscripts.isEmpty || model.inFlightCount > 0 {
                showPanel()
            } else {
                panel.orderOut(nil)
            }
        case .connecting, .recording, .finalizing:
            showPanel()
        case .succeeded:
            showPanel()
            // With the always-visible HUD on, the model's own 1.5-second reset
            // to ready re-presents the panel at the same moment this hide
            // would fire — skipping the hide morphs DONE into READY without a
            // blink. A failure has no automatic reset, so it stays on screen
            // until the next dictation clears it; hiding it would leave the
            // "always visible" HUD invisibly absent.
            if !model.hudAlwaysVisible, model.heldTranscripts.isEmpty, model.inFlightCount == 0 {
                scheduleHide(after: 1.5)
            }
        case .failed:
            showPanel()
            if !model.hudAlwaysVisible, model.heldTranscripts.isEmpty, model.inFlightCount == 0 {
                scheduleHide(after: 4)
            }
        }
    }

    /// Recording and connecting have the Stop and Cancel buttons and grow to
    /// the interactive panel size. The always-visible ready HUD also accepts
    /// the mouse — for its Start button — but stays compact, so mouse
    /// acceptance and sizing are separate questions.
    private static func isInteractive(_ phase: MacCapturePhase) -> Bool {
        phase == .recording || phase == .connecting
    }

    private func acceptsMouse(_ phase: MacCapturePhase) -> Bool {
        if Self.isInteractive(phase) { return true }
        guard model.hudAlwaysVisible else { return false }
        return switch phase {
        case .ready, .failed: model.canStartRecording
        case .connecting, .recording, .finalizing, .succeeded: false
        }
    }

    private func showPanel() {
        let isSideDocked = model.hudPlacement == .left || model.hudPlacement == .right
        let desiredSize: NSSize
        if isSideDocked {
            desiredSize = Self.isInteractive(model.phase)
                ? Self.sideInteractivePanelSize
                : Self.sideCompactPanelSize
        } else {
            desiredSize = Self.isInteractive(model.phase)
                ? Self.interactivePanelSize
                : Self.compactPanelSize
        }
        if panel.frame.size != desiredSize {
            panel.setContentSize(desiredSize)
        }
        if dragStartPanelOrigin == nil {
            positionPanelOnActiveScreen()
        }
        // `orderFrontRegardless` works while SpeakPaste is inactive. The panel
        // is nonactivating and never becomes key, so even its Stop and Cancel
        // buttons cannot steal focus from the app receiving dictated text.
        panel.orderFrontRegardless()
    }

    private func scheduleHide(after delay: TimeInterval) {
        delayedHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }

    /// Moves the panel with the pointer. Deltas come from the pointer's screen
    /// location rather than the gesture's translation because the gesture's
    /// coordinate space moves with the window it is dragging.
    private func handleDragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStartPanelOrigin == nil {
            dragStartPanelOrigin = panel.frame.origin
            dragStartMouseLocation = mouse
        }
        guard
            let startOrigin = dragStartPanelOrigin,
            let startMouse = dragStartMouseLocation
        else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: startOrigin.x + (mouse.x - startMouse.x),
                y: startOrigin.y + (mouse.y - startMouse.y)
            )
        )
    }

    /// Docks the released panel to whichever of the four placements it is
    /// nearest. Persisting through the model keeps the Settings picker in sync
    /// and re-presents the panel at the docked position.
    private func handleDragEnded() {
        dragStartPanelOrigin = nil
        dragStartMouseLocation = nil
        let docked = nearestPlacement()
        if model.hudPlacement != docked {
            model.hudPlacement = docked
        } else {
            positionPanelOnActiveScreen()
        }
    }

    private func nearestPlacement() -> MacHUDPlacement {
        guard let screen = panel.screen ?? NSScreen.main else { return model.hudPlacement }
        let size = panel.frame.size
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var best = model.hudPlacement
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for placement in MacHUDPlacement.allCases {
            let origin = Self.anchorOrigin(for: placement, on: screen, size: size)
            let anchorCenter = NSPoint(
                x: origin.x + size.width / 2,
                y: origin.y + size.height / 2
            )
            let distance = hypot(center.x - anchorCenter.x, center.y - anchorCenter.y)
            if distance < bestDistance {
                best = placement
                bestDistance = distance
            }
        }
        return best
    }

    private func positionPanelOnActiveScreen() {
        let screen = (panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let inset: CGFloat = 12
        let size = panel.frame.size
        let desired = Self.anchorOrigin(for: model.hudPlacement, on: screen, size: size)

        let x = min(
            max(desired.x, visibleFrame.minX + inset),
            visibleFrame.maxX - size.width - inset
        )
        let y = min(
            max(desired.y, visibleFrame.minY),
            visibleFrame.maxY - size.height
        )
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    /// Top is the default because the apps SpeakPaste dictates into put their
    /// text field at the bottom center of the window, which is exactly where a
    /// bottom-anchored HUD lands — it covered the insertion point it was
    /// reporting on. The other placements exist for users whose work lives at
    /// the top of the screen instead, and dragging the HUD docks it to the
    /// nearest one. `visibleFrame` already excludes the menu bar, any notch,
    /// and the Dock.
    private static func anchorOrigin(
        for placement: MacHUDPlacement,
        on screen: NSScreen,
        size: NSSize
    ) -> NSPoint {
        let visibleFrame = screen.visibleFrame
        let inset: CGFloat = 12
        let centeredX = visibleFrame.midX - size.width / 2
        let centeredY = visibleFrame.midY - size.height / 2

        return switch placement {
        case .top:
            NSPoint(x: centeredX, y: visibleFrame.maxY - size.height - inset)
        case .bottom:
            NSPoint(x: centeredX, y: visibleFrame.minY + inset)
        case .left:
            NSPoint(x: visibleFrame.minX + inset, y: centeredY)
        case .right:
            NSPoint(x: visibleFrame.maxX - size.width - inset, y: centeredY)
        }
    }
}

private final class MacStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The first click on a non-key window normally only brings it forward. The
/// HUD's Stop and Cancel buttons must act on that first click — the panel can
/// never become key, and the dictating user has no focus to give up.
private final class MacStatusHUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("MacStatusHUDHostingView does not support init(coder:)")
    }
}

private struct MacStatusHUDView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var permissions: MacPermissionsModel
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void

    var body: some View {
        let state = displayState
        if state.showsElapsedTime {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statusContent(state: state, date: context.date)
            }
        } else {
            statusContent(state: state, date: nil)
        }
    }

    private func statusContent(
        state: MacStatusHUDDisplayState,
        date: Date?
    ) -> some View {
        Group {
            if isSideDocked {
                VStack(alignment: .leading, spacing: 8) {
                    statusIdentity(state: state)
                    HStack(spacing: 8) {
                        statusMeterAndTimer(state: state, date: date)
                        Spacer(minLength: 4)
                        if state.isInteractive {
                            controls(state: state)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    statusIdentity(state: state)
                    Spacer(minLength: 8)
                    statusMeterAndTimer(state: state, date: date)
                    if state.isInteractive {
                        controls(state: state)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .frame(width: panelWidth, height: panelHeight)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    state.isWarning
                        ? AnyShapeStyle(Color.orange.opacity(0.7))
                        : AnyShapeStyle(Color.primary.opacity(0.12)),
                    lineWidth: state.isWarning ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gesture(dragGesture, including: state.isInteractive ? .all : .subviews)
    }

    private var isSideDocked: Bool {
        model.hudPlacement == .left || model.hudPlacement == .right
    }

    /// Only connecting and recording earn the larger panel: the meter, timer,
    /// and two buttons need the room. The always-visible ready HUD is
    /// interactive too — one Start button — but stays at the compact size the
    /// panel controller gives it.
    private var usesExpandedSize: Bool {
        model.phase == .connecting || model.phase == .recording
    }

    private var panelWidth: CGFloat {
        isSideDocked ? 200 : (usesExpandedSize ? 430 : 330)
    }

    private var panelHeight: CGFloat {
        isSideDocked ? (usesExpandedSize ? 122 : 88) : (usesExpandedSize ? 64 : 58)
    }

    private func statusIdentity(state: MacStatusHUDDisplayState) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(state.color)
                    .frame(width: 34, height: 34)
                Image(systemName: state.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(state.title)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    if permissions.isSecureInputEnabled {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                }
                Text(state.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        state.isWarning
                            ? AnyShapeStyle(.orange)
                            : AnyShapeStyle(.secondary)
                    )
                    .lineLimit(isSideDocked || state.isWarning ? 2 : 1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: state))
    }

    @ViewBuilder
    private func statusMeterAndTimer(
        state: MacStatusHUDDisplayState,
        date: Date?
    ) -> some View {
        if state.showsInputLevel {
            MacInputLevelMeter(level: model.inputLevel)
        }
        if let date {
            Text(elapsedText(at: date))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in onDragChanged() }
            .onEnded { _ in onDragEnded() }
    }

    @ViewBuilder
    private func controls(state: MacStatusHUDDisplayState) -> some View {
        HStack(spacing: 6) {
            if state.showsStartButton {
                // The ready HUD's whole reason to accept the mouse: one
                // Start button, no Cancel — there is nothing to cancel yet.
                hudControlButton(
                    symbol: "mic.fill",
                    tint: AnyShapeStyle(Color.red),
                    help: "Start dictating",
                    accessibilityLabel: "Start dictating"
                ) {
                    model.toggleRecording()
                }
            } else {
                if state.showsStopButton {
                    hudControlButton(
                        symbol: "stop.fill",
                        help: "Stop and transcribe",
                        accessibilityLabel: "Stop recording and transcribe"
                    ) {
                        model.toggleRecording()
                    }
                }
                hudControlButton(
                    symbol: "xmark",
                    help: state.showsStopButton ? "Discard this recording" : "Cancel",
                    accessibilityLabel: state.showsStopButton
                        ? "Cancel recording and discard the audio"
                        : "Cancel connecting"
                ) {
                    model.requestRecordingCancellation()
                }
            }
        }
    }

    private func hudControlButton(
        symbol: String,
        tint: AnyShapeStyle = AnyShapeStyle(.primary),
        help: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.quaternary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func accessibilityText(for state: MacStatusHUDDisplayState) -> String {
        let spokenDetail = state.detail
            .replacingOccurrences(of: model.hotKeyLabel, with: "Right Command key")
            .replacingOccurrences(of: model.releaseHotKeyLabel, with: "Option Command V")
        var text = "SpeakPaste, \(state.title), \(spokenDetail)"
        if permissions.isSecureInputEnabled {
            text += ". A secure input field is active; pasting is blocked until it closes."
        }
        return text
    }

    private var displayState: MacStatusHUDDisplayState {
        switch model.phase {
        case .ready:
            let showsStart = model.hudAlwaysVisible && model.canStartRecording
            if model.heldTranscripts.isEmpty, model.inFlightCount > 0 {
                // The microphone is already free. Say so, so the wait never
                // reads as "you have to stand still until this finishes".
                // The mic is free in every ready substate, so the always-
                // visible HUD offers its Start button in all three.
                return MacStatusHUDDisplayState(
                    symbol: "waveform.badge.magnifyingglass",
                    title: model.inFlightCount == 1
                        ? "TRANSCRIBING"
                        : "TRANSCRIBING ×\(model.inFlightCount)",
                    detail: model.canStartRecording
                        ? "Mic is free — tap \(model.hotKeyLabel) to keep going"
                        : "Mic is free — \(readinessDetail)",
                    color: .blue,
                    showsElapsedTime: false,
                    isInteractive: showsStart,
                    showsStartButton: showsStart
                )
            } else if model.heldTranscripts.isEmpty, !model.networkIsAvailable {
                return MacStatusHUDDisplayState(
                    symbol: "wifi.slash",
                    title: "OFFLINE",
                    detail: model.canStartRecording
                        ? "Saved locally — tap \(model.hotKeyLabel) to record"
                        : readinessDetail,
                    color: .orange,
                    showsElapsedTime: false,
                    isWarning: true,
                    isInteractive: showsStart,
                    showsStartButton: showsStart
                )
            } else if model.heldTranscripts.isEmpty {
                return MacStatusHUDDisplayState(
                    symbol: model.canStartRecording ? "waveform" : "exclamationmark.triangle.fill",
                    title: model.canStartRecording ? "READY" : "SETUP NEEDED",
                    detail: model.canStartRecording
                        ? "Tap \(model.hotKeyLabel) to start"
                        : readinessDetail,
                    color: model.canStartRecording ? .secondary : .orange,
                    showsElapsedTime: false,
                    isWarning: !model.canStartRecording,
                    isInteractive: showsStart,
                    showsStartButton: showsStart
                )
            } else {
                return MacStatusHUDDisplayState(
                    symbol: "tray.full.fill",
                    title: heldTitle,
                    detail: heldDetail,
                    color: .blue,
                    showsElapsedTime: false,
                    isWarning: permissions.isSecureInputEnabled
                        || model.hasUncertainHeldTranscripts,
                    isInteractive: showsStart,
                    showsStartButton: showsStart
                )
            }
        case .connecting:
            return MacStatusHUDDisplayState(
                symbol: "antenna.radiowaves.left.and.right",
                title: "WAIT",
                detail: "Connecting — do not speak yet",
                color: .orange,
                showsElapsedTime: true,
                isInteractive: true
            )
        case .recording:
            if let confirmation = model.recordingCancelConfirmation {
                // A protected recording has one Escape armed. This warning is
                // the whole point of the confirmation window, so it displaces
                // the meter and timer for its three seconds on screen.
                return MacStatusHUDDisplayState(
                    symbol: "exclamationmark.triangle.fill",
                    title: "DISCARD RECORDING?",
                    detail: confirmation.message,
                    color: .orange,
                    showsElapsedTime: false,
                    isWarning: true,
                    isInteractive: true,
                    showsStopButton: true
                )
            } else {
                return MacStatusHUDDisplayState(
                    symbol: model.recordingWarning == nil ? "mic.fill" : "exclamationmark.triangle.fill",
                    title: "SPEAK NOW",
                    detail: model.recordingWarning ?? "\(model.hotKeyLabel) to stop and transcribe",
                    color: .red,
                    showsElapsedTime: true,
                    isWarning: model.recordingWarning != nil,
                    isInteractive: true,
                    showsStopButton: true,
                    showsInputLevel: true
                )
            }
        case .finalizing:
            return MacStatusHUDDisplayState(
                symbol: "stop.fill",
                title: "RECORDING STOPPED",
                detail: model.recordingWarning ?? "Releasing microphone",
                color: .orange,
                showsElapsedTime: true,
                isWarning: model.recordingWarning != nil
            )
        case let .succeeded(detail):
            return MacStatusHUDDisplayState(
                symbol: "checkmark",
                title: "DONE",
                detail: detail,
                color: .green,
                showsElapsedTime: false
            )
        case let .failed(message):
            let showsStart = model.hudAlwaysVisible && model.canStartRecording
            return MacStatusHUDDisplayState(
                symbol: "exclamationmark",
                title: "ERROR",
                detail: message,
                color: .red,
                showsElapsedTime: false,
                isWarning: true,
                isInteractive: showsStart,
                showsStartButton: showsStart
            )
        }
    }

    private var heldTitle: String {
        model.heldTranscripts.count == 1
            ? "TEXT WAITING"
            : "\(model.heldTranscripts.count) WAITING"
    }

    private var heldDetail: String {
        if model.hasUncertainHeldTranscripts {
            return "Text may already be pasted — verify or discard it in the dashboard"
        }
        if permissions.isSecureInputEnabled {
            return "Secure input is blocking paste — text stays safe"
        }
        let recoveredCount = model.heldTranscripts.filter(\.isRecovered).count
        let live = model.heldTranscripts.filter { !$0.isRecovered }
        let destinations = Array(Set(live.map(\.destinationApplicationName))).sorted()

        if live.isEmpty {
            // Recovered transcripts never auto-paste; do not promise they will.
            return recoveredCount == 1
                ? "Recovered — \(model.releaseHotKeyLabel) places it here"
                : "Recovered ×\(recoveredCount) — \(model.releaseHotKeyLabel) places all here"
        }
        if recoveredCount > 0 {
            return "\(recoveredCount) recovered; live text waits for its exact original field"
        }
        if destinations.count == 1, let destination = destinations.first {
            return "Return to the exact field in \(destination), or \(model.releaseHotKeyLabel)"
        }
        return "Waiting for \(destinations.count) original fields · \(model.releaseHotKeyLabel) places all here"
    }

    private var readinessDetail: String {
        if !model.hasAPIKey { return "Add an ElevenLabs API key in Settings" }
        if model.selectedDevice == nil { return "Choose a microphone in SpeakPaste" }
        if permissions.granted[.microphone] != true {
            return "Grant microphone access in SpeakPaste"
        }
        return "Open SpeakPaste to finish setup"
    }

    private func elapsedText(at date: Date) -> String {
        let totalSeconds = max(0, Int(date.timeIntervalSince(model.phaseStartedAt)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// A compact live input meter: ten fixed slots that fill from the left as the
/// captured level rises, under a gentle arch so it reads as a waveform at a
/// glance. Threshold bars rather than a scrolling waveform, because the one
/// question the HUD answers is "is my voice reaching this microphone".
private struct MacInputLevelMeter: View {
    let level: Double

    private static let barCount = 10

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(
                        index < litCount
                            ? AnyShapeStyle(Color.red)
                            : AnyShapeStyle(.quaternary)
                    )
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .animation(.linear(duration: 0.1), value: litCount)
        // The combined HUD label already announces the recording state; a
        // level readout that changes many times a second is VoiceOver noise.
        .accessibilityHidden(true)
    }

    private var litCount: Int {
        let clamped = min(max(level, 0), 1)
        return Int((clamped * Double(Self.barCount)).rounded())
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let position = Double(index) / Double(Self.barCount - 1)
        return 8 + CGFloat(sin(position * .pi) * 10)
    }
}

private struct MacStatusHUDDisplayState {
    let symbol: String
    let title: String
    let detail: String
    let color: Color
    let showsElapsedTime: Bool
    var isWarning = false
    var isInteractive = false
    var showsStopButton = false
    var showsStartButton = false
    var showsInputLevel = false
}
