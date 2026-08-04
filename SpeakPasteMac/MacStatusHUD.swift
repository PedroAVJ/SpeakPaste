import AppKit
import Combine
import Foundation
import SwiftUI

/// The panel and its SwiftUI surface share this presentation snapshot so a
/// state can morph all the way out before AppKit removes the window. The
/// model remains the authority for product state; this object owns only the
/// few hundred milliseconds of visual choreography around it.
@MainActor
private final class MacHUDPresentationState: ObservableObject {
    @Published private(set) var activity: MacHUDActivity = .hidden
    @Published private(set) var isExiting = false

    func show(_ activity: MacHUDActivity) {
        self.activity = activity
        isExiting = false
    }

    func beginExit() {
        guard activity != .hidden else { return }
        isExiting = true
    }

    func finishExit() {
        activity = .hidden
        isExiting = false
    }
}

@MainActor
final class MacStatusHUDController: ObservableObject {
    /// Finalizing normally lasts well under a second while AVFoundation
    /// releases the microphone. If that release ever hangs, the indicator must
    /// not sit on screen forever — the dashboard and menu bar own long-lived
    /// problem reporting.
    private static let finalizingVisibilityCap: TimeInterval = 15
    /// Connection readiness is bounded in the recorder, but AVFoundation's
    /// synchronous session startup can still stall below that timeout. Keep the
    /// capture attempt alive while moving long-lived status out of the way.
    private static let connectingVisibilityCap: TimeInterval = 20
    /// A stalled network request should not turn a peripheral indicator into
    /// permanent screen furniture. Recovery and retry state remain available
    /// in the dashboard after this presentation-only cap.
    private static let transcribingVisibilityCap: TimeInterval = 90

    private let model: MacAppModel
    private let panel: MacStatusPanel
    private let presentation = MacHUDPresentationState()
    private var stateCancellables = Set<AnyCancellable>()
    private var currentActivity: MacHUDActivity = .hidden
    private var transcribingPresentedAt: Date?
    private var delayedHideTask: Task<Void, Never>?
    private var releaseBridgeTask: Task<Void, Never>?
    private var fadeOutTask: Task<Void, Never>?
    /// Invalidates an in-flight fade-out when a newer show or hide begins.
    private var hideGeneration = 0

    init(model: MacAppModel) {
        self.model = model

        let panel = MacStatusPanel(
            contentRect: NSRect(origin: .zero, size: MacHUDMetrics.panelSize),
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
        // The capsule morphs between widths inside a fixed transparent panel.
        // An AppKit window shadow would hug the stale outline mid-morph, so
        // the SwiftUI surface draws its own shadow instead.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Always click-through: the indicator has no controls, so it must
        // never intercept a click meant for the app underneath it.
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none

        let hostingView = NSHostingView(
            rootView: MacStatusHUDView(
                model: model,
                presentation: presentation
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: MacHUDMetrics.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    /// Starts mirroring the app model into the floating panel. Safe to call
    /// repeatedly from a SwiftUI scene lifecycle callback.
    func start() {
        guard stateCancellables.isEmpty else {
            currentActivity = resolvedActivity
            if currentActivity == .transcribing, transcribingPresentedAt == nil {
                transcribingPresentedAt = Date()
            }
            present(currentActivity)
            return
        }

        currentActivity = resolvedActivity
        if currentActivity == .transcribing {
            transcribingPresentedAt = Date()
        }

        // Consume the emitted activity itself. Published values arrive before
        // their backing property finishes mutating, so throwing the value away
        // and immediately re-reading the model can present the previous state.
        MacHUDActivity.publisher(
            capture: model.$phase.map(\.hudCaptureActivity),
            inFlightTranscriptionCount: model.$inFlightCount
        )
        // A serial main-queue delivery preserves the exact Combine emission
        // order. Spawning one unstructured Task per value can reorder the
        // short releasing → hidden → transcribing burst and strand the panel
        // in a stale state with no later emission to repair it.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                if activity == .transcribing,
                   self.currentActivity != .transcribing {
                    self.transcribingPresentedAt = Date()
                } else if activity != .transcribing {
                    self.transcribingPresentedAt = nil
                }
                self.currentActivity = activity
                self.present(activity)
            }
        }
        .store(in: &stateCancellables)

        // These values affect chrome, placement, or visibility caps without
        // changing the semantic activity. Re-present the last emitted state.
        Publishers.MergeMany(
            model.$phaseStartedAt.map { _ in () }.eraseToAnyPublisher(),
            model.$hudEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$hudPlacement.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedDeviceID.map { _ in () }.eraseToAnyPublisher(),
            model.$devices.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.present(self.currentActivity)
            }
        }
        .store(in: &stateCancellables)
        present(currentActivity)
    }

    /// The indicator exists while SpeakPaste holds (or is acquiring or
    /// releasing) the microphone, and stays up as a quiet "Transcribing"
    /// state while spoken dictations still await text. Every other state —
    /// ready, success, failure, offline, setup, held text — is hidden here
    /// and reported by the dashboard and menu bar instead.
    private func present(_ activity: MacHUDActivity) {
        delayedHideTask?.cancel()
        delayedHideTask = nil

        guard model.hudEnabled else {
            hidePanel()
            return
        }

        switch activity {
        case .connecting:
            let remaining = remainingVisibility(
                within: Self.connectingVisibilityCap
            )
            guard remaining > 0 else {
                hidePanel()
                return
            }
            showPanel(activity)
            scheduleHide(after: remaining)
        case .listening:
            showPanel(activity)
        case .releasing:
            let remaining = remainingVisibility(
                within: Self.finalizingVisibilityCap
            )
            guard remaining > 0 else {
                hidePanel()
                return
            }
            showPanel(activity)
            // Device-list refreshes can call `present` repeatedly. Measure the
            // cap from the phase transition so those refreshes can never keep
            // the indicator alive indefinitely.
            scheduleHide(after: remaining)
        case .transcribing:
            let startedAt = transcribingPresentedAt ?? Date()
            transcribingPresentedAt = startedAt
            let remaining = max(
                0,
                Self.transcribingVisibilityCap
                    - Date().timeIntervalSince(startedAt)
            )
            guard remaining > 0 else {
                hidePanel()
                return
            }
            showPanel(activity)
            scheduleHide(after: remaining)
        case .hidden:
            // `phase = .ready` is published just before its durable audio is
            // admitted to the transcription workload. Hold the collapsing
            // waveform for one beat so that ordinary release morphs directly
            // into progress instead of flashing an empty panel between them.
            if presentation.activity == .releasing {
                scheduleReleaseBridgeHide()
            } else {
                hidePanel()
            }
        }
    }

    private var resolvedActivity: MacHUDActivity {
        MacHUDActivity.resolve(
            capture: model.phase.hudCaptureActivity,
            inFlightTranscriptionCount: model.inFlightCount
        )
    }

    private func showPanel(_ activity: MacHUDActivity) {
        // A pending gentle fade-out must never order the panel back out after
        // this show. Invalidate it and restore full opacity so entry is brisk.
        releaseBridgeTask?.cancel()
        releaseBridgeTask = nil
        fadeOutTask?.cancel()
        fadeOutTask = nil
        hideGeneration &+= 1
        panel.alphaValue = 1
        presentation.show(activity)
        if panel.frame.size != MacHUDMetrics.panelSize {
            panel.setContentSize(MacHUDMetrics.panelSize)
        }
        positionPanelOnActiveScreen()
        // `orderFrontRegardless` works while SpeakPaste is inactive; the panel
        // is nonactivating and never becomes key, so it cannot steal focus
        // from the app receiving dictated text.
        panel.orderFrontRegardless()
    }

    /// Exit is deliberately gentle: SwiftUI collapses the last meaningful
    /// surface before AppKit orders out its fixed transparent host window.
    private func hidePanel() {
        releaseBridgeTask?.cancel()
        releaseBridgeTask = nil
        guard panel.isVisible else {
            presentation.finishExit()
            return
        }
        hideGeneration &+= 1
        let generation = hideGeneration
        presentation.beginExit()
        fadeOutTask?.cancel()
        fadeOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.35))
            guard let self, !Task.isCancelled else { return }
            guard self.hideGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.presentation.finishExit()
        }
    }

    private func scheduleReleaseBridgeHide() {
        releaseBridgeTask?.cancel()
        releaseBridgeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.20))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.hidePanel()
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        delayedHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.hidePanel()
        }
    }

    private func remainingVisibility(within cap: TimeInterval) -> TimeInterval {
        let elapsed = Date().timeIntervalSince(model.phaseStartedAt)
        return max(0, cap - elapsed)
    }

    private func positionPanelOnActiveScreen() {
        let screen = (panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let inset: CGFloat = 4
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
    /// the top of the screen instead. `visibleFrame` already excludes the menu
    /// bar, any notch, and the Dock.
    private static func anchorOrigin(
        for placement: MacHUDPlacement,
        on screen: NSScreen,
        size: NSSize
    ) -> NSPoint {
        let visibleFrame = screen.visibleFrame
        // The panel now includes 18 points of transparent shadow breathing
        // room around the 36-point capsule. Four points here preserves the
        // prior 22-point visible edge gap.
        let inset: CGFloat = 4
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

/// Shared geometry between the AppKit panel and the SwiftUI capsule. The
/// panel never resizes; the capsule morphs between widths centered inside it,
/// which keeps every transition in Core Animation and out of AppKit frame
/// changes.
private enum MacHUDMetrics {
    // Leave enough transparent breathing room for the SwiftUI shadow at every
    // capsule width; clipping that shadow is the quickest way for glass to
    // read like a flat rounded rectangle.
    static let panelSize = NSSize(width: 216, height: 72)
    static let capsuleHeight: CGFloat = 36

    static func capsuleWidth(
        for activity: MacHUDActivity,
        reduceMotion: Bool
    ) -> CGFloat {
        // Under Reduce Motion the surface holds one width so state changes
        // are pure crossfades with no shape travel.
        if reduceMotion { return 150 }
        return switch activity {
        case .connecting: 56
        case .listening: 176
        case .releasing: 120
        case .transcribing: 120
        case .hidden: 56
        }
    }
}

/// One continuous Liquid Glass capsule that morphs between activities instead
/// of swapping labeled status rows. It shows no words, icons, timers, or
/// spinners; the state is carried by shape, motion, and color, with the
/// descriptive text living only in the accessibility label.
private struct MacStatusHUDView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var presentation: MacHUDPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let activity = presentation.activity
        ZStack {
            if activity != .hidden {
                MacHUDCapsule(
                    activity: activity,
                    inputLevel: model.inputLevel,
                    transcriptionWorkload: model.transcriptionWorkload,
                    reduceMotion: reduceMotion
                )
                .transition(capsuleTransition)
                .scaleEffect(
                    presentation.isExiting && !reduceMotion ? 0.90 : 1
                )
                .opacity(presentation.isExiting ? 0 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(for: activity))
            }
        }
        .frame(
            width: MacHUDMetrics.panelSize.width,
            height: MacHUDMetrics.panelSize.height
        )
        .animation(morphAnimation, value: activity)
        .animation(exitAnimation, value: presentation.isExiting)
    }

    private var morphAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.25)
            : .spring(response: 0.35, dampingFraction: 0.8)
    }

    /// Entry is brisk (a small scale-up with the surface spring); exit is a
    /// plain fade that overlaps the panel's own gentle alpha fade-out.
    private var capsuleTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.86).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var exitAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.28, dampingFraction: 0.92)
    }

    private var sourceName: String? {
        model.inputMode?.title ?? model.selectedDevice?.name
    }

    private func accessibilityText(for activity: MacHUDActivity) -> String {
        var parts = ["SpeakPaste"]
        switch activity {
        case .connecting:
            parts.append("Connecting")
        case .listening:
            parts.append("Listening")
        case .releasing:
            parts.append("Releasing the microphone")
        case .transcribing:
            parts.append("Transcribing")
        case .hidden:
            break
        }
        switch activity {
        case .connecting, .listening, .releasing:
            // Background transcription may belong to a different microphone
            // than the current sticky selection, so only capture states name
            // their source.
            if let sourceName {
                parts.append(sourceName)
            }
        case .transcribing, .hidden:
            break
        }
        return parts.joined(separator: ", ")
    }
}

/// The morphing surface: a fixed-height capsule whose width and contents
/// track the activity. Listening and releasing share one branch so the
/// waveform keeps its identity and visibly collapses instead of being
/// replaced.
private struct MacHUDCapsule: View {
    let activity: MacHUDActivity
    let inputLevel: Double
    let transcriptionWorkload: MacTranscriptionWorkload
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            switch activity {
            case .connecting:
                MacHUDWakeSignal(reduceMotion: reduceMotion)
            case .listening, .releasing:
                MacHUDWaveform(
                    level: inputLevel,
                    isCollapsing: activity == .releasing,
                    reduceMotion: reduceMotion
                )
            case .transcribing:
                MacHUDTranscribeProgress(
                    workload: transcriptionWorkload,
                    reduceMotion: reduceMotion
                )
            case .hidden:
                EmptyView()
            }
        }
        .frame(
            width: MacHUDMetrics.capsuleWidth(
                for: activity,
                reduceMotion: reduceMotion
            ),
            height: MacHUDMetrics.capsuleHeight
        )
        .modifier(MacHUDSurface())
        // The panel's AppKit shadow is off so it cannot lag behind the morph;
        // this shadow is the capsule's only sense of elevation.
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// Connecting: a minimal wake signal. A single warm dot breathes while the
/// session starts — deliberately not a spinner, because nothing is being
/// measured yet; the system is only waking up.
private struct MacHUDWakeSignal: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: reduceMotion ? 1 : 1.0 / 30,
                paused: reduceMotion
            )
        ) { context in
            let pulse = reduceMotion
                ? 0.5
                : (sin(context.date.timeIntervalSinceReferenceDate * 3.5) + 1) / 2
            Circle()
                .fill(Color(nsColor: .systemOrange))
                .frame(width: 7, height: 7)
                .scaleEffect(reduceMotion ? 1 : 0.82 + 0.42 * pulse)
                .opacity(0.48 + 0.47 * pulse)
                .shadow(
                    color: Color(nsColor: .systemOrange).opacity(
                        reduceMotion ? 0 : 0.16 + 0.36 * pulse
                    ),
                    radius: reduceMotion ? 0 : 2 + 4 * pulse
                )
        }
        .accessibilityHidden(true)
    }
}

/// Listening and releasing: a compact center-symmetric waveform driven by the
/// real captured input level, answering the one question the HUD exists for —
/// "is my voice reaching this microphone". During release the target level
/// drops to zero so the same bars visibly collapse, and a single glint hands
/// the energy forward toward the transcription state.
private struct MacHUDWaveform: View {
    let level: Double
    let isCollapsing: Bool
    let reduceMotion: Bool

    @State private var envelope = MacHUDLevelEnvelope()

    private static let barCount = 15
    private static let barWidth: CGFloat = 3.5
    private static let barSpacing: CGFloat = 3.5
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 22

    private static var canvasWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    var body: some View {
        ZStack {
            TimelineView(
                .animation(minimumInterval: reduceMotion ? 1.0 / 15 : 1.0 / 60)
            ) { context in
                Canvas { graphics, size in
                    drawBars(in: graphics, size: size, at: context.date)
                }
            }
            .frame(width: Self.canvasWidth, height: Self.maxBarHeight + 2)

            if isCollapsing, !reduceMotion {
                MacHUDReleaseGlint()
            }
        }
        .accessibilityHidden(true)
    }

    private func drawBars(in graphics: GraphicsContext, size: CGSize, at date: Date) {
        let target = isCollapsing ? 0 : min(max(level, 0), 1)
        let display = envelope.step(
            toward: target,
            at: date,
            collapsing: isCollapsing
        )
        // The recorder publishes linear amplitude, where ordinary laptop-mic
        // speech occupies only the bottom few percent. Remove the true noise
        // floor, then lift that real signal into the small visual range so a
        // normal voice reads as bars instead of a nearly static row of dots.
        let perceptualInput = min(max((display - 0.004) * 10, 0), 1)
        let shaped = pow(perceptualInput, 0.60)
        let time = date.timeIntervalSinceReferenceDate
        let midY = size.height / 2

        for index in 0..<Self.barCount {
            let fraction = Double(index) / Double(Self.barCount - 1)
            // Center-symmetric arch so the shape reads as a voice waveform at
            // a glance rather than a VU meter.
            let arch = 0.30 + 0.70 * sin(fraction * .pi)
            let wobble: Double
            if reduceMotion {
                wobble = 1
            } else {
                // Deterministic per-bar drift, scaled by the same level so
                // silence stays calm instead of shimmering artificially.
                let speed = 6.5 + Double(index).truncatingRemainder(dividingBy: 4) * 1.4
                let phase = Double(index) * 1.7
                wobble = 0.78 + 0.22 * sin(time * speed + phase)
            }
            let height = Self.minBarHeight
                + (Self.maxBarHeight - Self.minBarHeight) * CGFloat(arch * wobble * shaped)
            let x = CGFloat(index) * (Self.barWidth + Self.barSpacing)
            let bar = CGRect(
                x: x,
                y: midY - height / 2,
                width: Self.barWidth,
                height: height
            )
            graphics.fill(
                Path(roundedRect: bar, cornerRadius: Self.barWidth / 2),
                with: .color(
                    Color(nsColor: .systemRed).opacity(0.45 + 0.55 * arch)
                )
            )
        }
    }
}

/// Asymmetric level smoothing: attack is near-instant so speech onsets are
/// never missed, decay is slower so the waveform breathes instead of
/// flickering at the ~12 Hz the recorder publishes. Collapse (release) decays
/// faster than listening so letting go feels decisive. A reference type so
/// the Canvas can integrate across timeline frames without triggering SwiftUI
/// invalidation.
private final class MacHUDLevelEnvelope {
    private var displayLevel: Double = 0
    private var lastStepAt: Date?

    func step(toward target: Double, at date: Date, collapsing: Bool) -> Double {
        let dt: TimeInterval
        if let lastStepAt {
            dt = min(max(date.timeIntervalSince(lastStepAt), 0), 0.25)
        } else {
            dt = 1.0 / 60
        }
        lastStepAt = date

        let rising = target > displayLevel
        let timeConstant = rising ? 0.045 : (collapsing ? 0.12 : 0.32)
        let alpha = 1 - exp(-dt / timeConstant)
        displayLevel += (target - displayLevel) * alpha
        if displayLevel < 0.0005 { displayLevel = 0 }
        return displayLevel
    }
}

/// The release hand-off: one bright fleck leaves the collapsing waveform's
/// center and exits toward the leading edge of the upcoming progress fill.
private struct MacHUDReleaseGlint: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let travel = proxy.size.width / 2 - 10
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.88),
                            Color(nsColor: .systemCyan).opacity(0.82),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 12, height: 4)
                .blur(radius: 0.5)
                .position(
                    x: proxy.size.width / 2 + travel * progress,
                    y: proxy.size.height / 2
                )
                .opacity(1 - Double(progress))
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { progress = 1 }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Transcribing: a luminous line that advances from the left, plus a
/// restrained shimmer. Progress is an honest asymptotic estimate — it climbs
/// quickly through the expected turnaround window, keeps creeping forward
/// afterwards, and never reaches the end on its own. Completion is signaled
/// by the HUD leaving, not by the bar filling; no percentage is ever shown.
private struct MacHUDTranscribeProgress: View {
    let workload: MacTranscriptionWorkload
    let reduceMotion: Bool

    @State private var progressMemory = MacHUDProgressMemory()

    private static let trackWidth: CGFloat = 84
    private static let trackHeight: CGFloat = 4
    private static let shimmerWidth: CGFloat = 26
    private static let shimmerPeriod: TimeInterval = 1.5

    var body: some View {
        TimelineView(
            .animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 30)
        ) { context in
            let snapshot = progressMemory.resolve(
                workload.snapshot(at: context.date)
            )
            let fill = max(
                Self.trackHeight,
                Self.trackWidth * CGFloat(snapshot?.estimatedFraction ?? 0.08)
            )
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: Self.trackWidth, height: Self.trackHeight)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .systemBlue),
                                Color(nsColor: .systemCyan),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fill, height: Self.trackHeight)
                    .overlay(alignment: .leading) {
                        if !reduceMotion {
                            shimmer(at: context.date, fillWidth: fill)
                        }
                    }
                    .clipShape(Capsule())
                    .shadow(
                        color: Color(nsColor: .systemCyan).opacity(0.42),
                        radius: 3
                    )
            }
            // When concurrent dictations advance to a new head request, fade
            // the rail rather than visually scrubbing the estimate backward.
            .id(snapshot?.headID)
            .transition(.opacity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: snapshot?.headID
            )
        }
        .accessibilityHidden(true)
    }

    private func shimmer(at date: Date, fillWidth: CGFloat) -> some View {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.shimmerPeriod) / Self.shimmerPeriod
        let x = -Self.shimmerWidth + (fillWidth + 2 * Self.shimmerWidth) * CGFloat(phase)
        return LinearGradient(
            colors: [.clear, Color.white.opacity(0.65), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: Self.shimmerWidth, height: Self.trackHeight)
        .offset(x: x)
    }
}

/// Keeps the last real network estimate alive for the brief terminal fade.
/// Without this memory the workload becomes empty first and the rail visibly
/// snaps back to its 8% starting point just before the capsule disappears.
private final class MacHUDProgressMemory {
    private var lastSnapshot: MacTranscriptionWorkload.Snapshot?

    func resolve(
        _ snapshot: MacTranscriptionWorkload.Snapshot?
    ) -> MacTranscriptionWorkload.Snapshot? {
        if let snapshot {
            lastSnapshot = snapshot
            return snapshot
        }
        return lastSnapshot
    }
}

private extension MacCapturePhase {
    var hudCaptureActivity: MacHUDCaptureActivity {
        switch self {
        case .connecting: .connecting
        case .recording: .listening
        case .finalizing: .releasing
        case .ready, .succeeded, .failed: .inactive
        }
    }
}

/// The HUD chrome: native Liquid Glass on macOS 26 and later, with a plain
/// material capsule standing in down to the macOS 14 deployment target. The
/// compiler guard keeps the file building under pre-26 SDKs, where the glass
/// API does not exist even behind a runtime availability check.
private struct MacHUDSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            materialFallback(content)
        }
        #else
        materialFallback(content)
        #endif
    }

    private func materialFallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
    }
}
