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
    @Published private(set) var stack = MacHUDStack.empty
    @Published private(set) var isExiting = false

    func show(_ stack: MacHUDStack) {
        self.stack = stack
        isExiting = false
    }

    func beginExit() {
        guard !stack.isEmpty else { return }
        isExiting = true
    }

    func finishExit() {
        stack = .empty
        isExiting = false
    }
}

@MainActor
final class MacStatusHUDController: ObservableObject {
    private let model: MacAppModel
    private let panel: MacStatusPanel
    private let presentation = MacHUDPresentationState()
    private var stateCancellables = Set<AnyCancellable>()
    /// The last emitted pipeline snapshot. Each chunk keeps one UUID through
    /// capture, transcription, queueing, and a possible held state, so SwiftUI
    /// can morph the same surface instead of swapping anonymous status pills.
    private var currentPipeline = MacHUDPipeline()
    /// Re-resolves the stack when the earliest per-card visibility cap
    /// (connecting, releasing, a transcription card's 90 seconds, or a held
    /// card's two seconds) lapses.
    private var expiryTask: Task<Void, Never>?
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
        // The card stack morphs inside a fixed transparent panel. An AppKit
        // window shadow would hug a stale outline mid-morph, so the SwiftUI
        // surface draws its own per-card shadows instead.
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
            currentPipeline = model.hudPipeline
            present()
            return
        }

        currentPipeline = model.hudPipeline
        model.$hudPipeline
        // A serial main-queue delivery preserves the exact Combine emission
        // order. Spawning one unstructured Task per value can reorder the
        // short releasing → hidden → transcribing burst and strand the panel
        // in a stale state with no later emission to repair it.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] pipeline in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentPipeline = pipeline
                self.present()
            }
        }
        .store(in: &stateCancellables)

        // These values affect chrome, placement, or visibility caps without
        // changing the semantic stack inputs. Re-present the last emitted state.
        Publishers.MergeMany(
            model.$hudEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$hudPlacement.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedDeviceID.map { _ in () }.eraseToAnyPublisher(),
            model.$devices.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.present()
            }
        }
        .store(in: &stateCancellables)
        present()
    }

    /// The stack exists while SpeakPaste holds (or is acquiring or releasing)
    /// the microphone, while spoken dictations still await text, and — for two
    /// seconds only — when a just-finished chunk is held instead of delivered.
    /// The hold marker is declarative and transient; the durable held queue,
    /// along with ready, success, failure, offline, and setup states, lives in
    /// the dashboard and menu bar.
    private func present() {
        expiryTask?.cancel()
        expiryTask = nil

        guard model.hudEnabled else {
            hidePanel()
            return
        }

        let now = Date()
        let stack = MacHUDStack.resolve(
            pipeline: currentPipeline,
            at: now
        )
        guard !stack.isEmpty else {
            // `phase = .ready` is published just before its durable audio is
            // admitted to the transcription workload. Hold the collapsing
            // waveform for one beat so that ordinary release morphs directly
            // into its progress card instead of flashing an empty panel.
            if presentation.stack.frontIsReleasing {
                scheduleReleaseBridgeHide()
            } else {
                hidePanel()
            }
            return
        }
        showPanel(stack)
        scheduleNextExpiry(at: now)
    }

    /// Nothing is scheduled while only an uncapped listening capture is
    /// visible; every other surface — including the two-second transient hold
    /// marker — reports its deadline through `nextExpiry`.
    private func scheduleNextExpiry(at now: Date) {
        guard let next = MacHUDStack.nextExpiry(
            in: currentPipeline,
            after: now
        ) else { return }
        let delay = max(0.05, next.timeIntervalSince(now))
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.present()
        }
    }

    private func showPanel(_ stack: MacHUDStack) {
        // A pending gentle fade-out must never order the panel back out after
        // this show. Invalidate it and restore full opacity so entry is brisk.
        releaseBridgeTask?.cancel()
        releaseBridgeTask = nil
        fadeOutTask?.cancel()
        fadeOutTask = nil
        hideGeneration &+= 1
        panel.alphaValue = 1
        presentation.show(stack)
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
        // The panel includes transparent breathing room around the 36-point
        // cards for shadows and for the receding levels that lift above the
        // front card. Four points here preserves the prior visible edge gap.
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

/// Shared geometry between the AppKit panel and the SwiftUI cards. The panel
/// never resizes; the cards morph and recede centered inside it, which keeps
/// every transition in Core Animation and out of AppKit frame changes.
private enum MacHUDMetrics {
    // Leave enough transparent breathing room for the SwiftUI shadows at
    // every card width, plus headroom for two receding card levels lifting
    // above the front card; clipping either is the quickest way for glass to
    // read like a flat rounded rectangle.
    static let panelSize = NSSize(width: 216, height: 84)
    static let capsuleHeight: CGFloat = 36
    /// iOS-notification-stack recession per depth level.
    static let depthScaleStep: CGFloat = 0.92
    static let depthLift: CGFloat = 6
    static let depthOpacityStep: Double = 0.16
    /// Keeps the front card at the prior visual position now that the panel
    /// carries extra top headroom for the receding levels.
    static let frontCardDrop: CGFloat = 6

    /// Under Reduce Motion every surface holds one width so state changes are
    /// pure crossfades with no shape travel.
    static func capsuleWidth(
        for content: MacHUDStack.CardContent,
        reduceMotion: Bool
    ) -> CGFloat {
        switch content {
        case .sourceNudge:
            return reduceMotion ? 150 : 104
        case .resting:
            return reduceMotion ? 150 : 88
        case .held:
            return reduceMotion ? 150 : 56
        case .capture(.connecting), .capture(.inactive):
            return reduceMotion ? 150 : 56
        case .capture(.listening):
            return reduceMotion ? 150 : 176
        case .capture(.releasing):
            return reduceMotion ? 150 : 120
        case .transcription:
            return reduceMotion ? 150 : 120
        }
    }
}

/// The depth stack: one Liquid Glass card per dictation, capture always
/// frontmost, transcriptions receding behind it oldest-rearmost, and a
/// transient held marker taking its slot for the two seconds before it
/// expires. Cards show no words, timers, or spinners — state is carried by
/// shape, motion, and color; the held marker is a single restrained glyph.
/// Descriptive text lives in the accessibility label.
private struct MacStatusHUDView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var presentation: MacHUDPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stack = presentation.stack
        ZStack {
            // Rear cards first so the front card paints on top; the explicit
            // zIndex keeps that order stable while cards insert and remove.
            ForEach(renderedCards(for: stack).reversed()) { rendered in
                let card = rendered.card
                MacHUDStackCardView(
                    card: card,
                    inputLevel: model.inputLevel,
                    heldClipboardBacked: model.hasVisibleClipboardFallback
                        || model.heldClipboardOwnerID != nil,
                    reduceMotion: reduceMotion
                )
                .scaleEffect(
                    pow(MacHUDMetrics.depthScaleStep, CGFloat(card.depth))
                )
                .offset(
                    y: MacHUDMetrics.frontCardDrop
                        - MacHUDMetrics.depthLift * CGFloat(card.depth)
                )
                .opacity(1 - MacHUDMetrics.depthOpacityStep * Double(card.depth))
                .zIndex(Double(MacHUDStack.visibleCardBudget - card.depth))
                .transition(transition(for: card))
            }
        }
        .scaleEffect(presentation.isExiting && !reduceMotion ? 0.90 : 1)
        .opacity(presentation.isExiting ? 0 : 1)
        .frame(
            width: MacHUDMetrics.panelSize.width,
            height: MacHUDMetrics.panelSize.height
        )
        .animation(stackAnimation, value: stack)
        .animation(exitAnimation, value: presentation.isExiting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            stack.accessibilityLabel(
                sourceName: sourceName,
                heldClipboardBacked: model.hasVisibleClipboardFallback
                    || model.heldClipboardOwnerID != nil
            )
        )
    }

    /// Identity handed to SwiftUI. With full motion a card keeps one identity
    /// across depth changes so it visibly travels backward and forward in the
    /// pile. Under Reduce Motion the depth joins the identity, so a depth
    /// change is a crossfade between two stationary renderings instead of
    /// animated depth travel.
    private struct RenderedCard: Identifiable {
        struct Key: Hashable {
            let cardID: UUID
            let depthSlot: Int
        }

        let card: MacHUDStack.Card
        let id: Key
    }

    private func renderedCards(for stack: MacHUDStack) -> [RenderedCard] {
        stack.cards.map { card in
            RenderedCard(
                card: card,
                id: RenderedCard.Key(
                    cardID: card.id,
                    depthSlot: reduceMotion ? card.depth : 0
                )
            )
        }
    }

    private var stackAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.25)
            : .spring(response: 0.35, dampingFraction: 0.8)
    }

    /// Entry is brisk (a small scale-up with the surface spring). A capture
    /// card exits with a plain fade into its transcription card; a dictation
    /// or held card uses the delivery slide only when the model published a
    /// verified terminal receipt. Overflow folding, timeout, and the held
    /// marker's two-second expiry are presentation changes and therefore
    /// crossfade.
    private func transition(for card: MacHUDStack.Card) -> AnyTransition {
        if reduceMotion { return .opacity }
        switch card.content {
        case .sourceNudge, .resting:
            return .asymmetric(
                insertion: .scale(scale: 0.86).combined(with: .opacity),
                removal: .opacity
            )
        case .capture:
            return .asymmetric(
                insertion: .scale(scale: 0.86).combined(with: .opacity),
                removal: .opacity
            )
        case .transcription, .held:
            if model.recentlyDeliveredHUDCardIDs.contains(card.id) {
                return .asymmetric(
                    insertion: .scale(scale: 0.86).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                )
            }
            return .opacity
        }
    }

    private var exitAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.28, dampingFraction: 0.92)
    }

    /// Only ever the microphone that is actually live. A resting dictation has
    /// no source, so it must not inherit the last one's name.
    private var sourceName: String? {
        model.activeSource?.title
    }
}

/// One card surface: fixed-height capsule whose width and contents track the
/// card content, with the "+N" overflow badge riding the rearmost card.
private struct MacHUDStackCardView: View {
    let card: MacHUDStack.Card
    let inputLevel: Double
    let heldClipboardBacked: Bool
    let reduceMotion: Bool

    var body: some View {
        content
            .frame(height: MacHUDMetrics.capsuleHeight)
            .frame(
                width: MacHUDMetrics.capsuleWidth(
                    for: card.content,
                    reduceMotion: reduceMotion
                )
            )
            .modifier(MacHUDSurface())
            // The panel's AppKit shadow is off so it cannot lag behind the
            // morph; these per-card shadows are the stack's sense of depth.
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .overlay(alignment: .topTrailing) {
                if card.hiddenDeeperCount > 0 {
                    MacHUDOverflowBadge(count: card.hiddenDeeperCount)
                        .offset(x: 8, y: -8)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch card.content {
        case let .sourceNudge(attempted, live):
            MacHUDSourceNudge(
                attempted: attempted,
                live: live,
                reduceMotion: reduceMotion
            )
        case .resting:
            MacHUDRestingMark()
        case .capture(.connecting), .capture(.inactive):
            MacHUDWakeSignal(reduceMotion: reduceMotion)
        case .capture(.listening):
            MacHUDWaveform(
                level: inputLevel,
                isCollapsing: false,
                reduceMotion: reduceMotion
            )
        case .capture(.releasing):
            MacHUDWaveform(
                level: inputLevel,
                isCollapsing: true,
                reduceMotion: reduceMotion
            )
        case .transcription(let stage, let enqueuedAt, let recordingDuration):
            MacHUDDictationProgress(
                stage: stage,
                enqueuedAt: enqueuedAt,
                recordingDuration: recordingDuration,
                reduceMotion: reduceMotion
            )
        case .held:
            MacHUDHeldBadge(clipboardBacked: heldClipboardBacked)
        }
    }
}

/// The wrong source key, pressed while the other microphone is hot. The live
/// device holds its place and the attempted one is struck through: nothing is
/// switching, because switching is pause-then-resume. A single restrained
/// shake carries the refusal without ever becoming an alert.
private struct MacHUDSourceNudge: View {
    let attempted: MacInputMode
    let live: MacInputMode?
    let reduceMotion: Bool

    @State private var shake: CGFloat = 0

    var body: some View {
        HStack(spacing: 9) {
            if let live {
                deviceGlyph(for: live, isLive: true)
            }
            Image(systemName: "pause.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            deviceGlyph(for: attempted, isLive: false)
                .overlay {
                    Capsule()
                        .fill(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 18, height: 1.5)
                        .rotationEffect(.degrees(-32))
                }
        }
        .offset(x: shake)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .spring(response: 0.14, dampingFraction: 0.28)
            ) {
                shake = 3
            }
            withAnimation(
                .spring(response: 0.32, dampingFraction: 0.55).delay(0.14)
            ) {
                shake = 0
            }
        }
        .accessibilityHidden(true)
    }

    private func deviceGlyph(
        for mode: MacInputMode,
        isLive: Bool
    ) -> some View {
        Image(systemName: mode == .mac ? "laptopcomputer" : "iphone")
            .font(.system(size: 14, weight: isLive ? .semibold : .regular))
            .foregroundStyle(
                isLive
                    ? Color(nsColor: .systemRed)
                    : Color(nsColor: .secondaryLabelColor)
            )
            .opacity(isLive ? 1 : 0.48)
    }
}

/// Resting. The card is deliberately the quietest surface in the product: two
/// still bars, dimmed, with no laptop or phone glyph — no microphone is live,
/// so there is no current source to name, and the next source key decides.
/// Nothing animates and nothing counts down; the stack is simply refusing to
/// leave until the dictation is ended or discarded.
private struct MacHUDRestingMark: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule()
                    .fill(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 3.5, height: 14)
            }
        }
        .opacity(0.5)
        .accessibilityHidden(true)
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
/// the energy forward toward the transcription card behind.
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

/// One dictation's transcription rail: a luminous line that advances from the
/// left, plus a restrained shimmer. Each card owns its own rail, so no rail
/// ever inherits another request's estimate. Progress is an honest asymptotic
/// estimate — it climbs quickly through the expected turnaround window, keeps
/// creeping forward afterwards, and never reaches the end on its own.
/// Completion is signaled by the card leaving, not by the bar filling; no
/// percentage is ever shown. The enqueue metadata is copied onto the card, so
/// the rail keeps estimating through its removal transition after the
/// workload has forgotten the attempt.
private struct MacHUDDictationProgress: View {
    let stage: MacHUDPipeline.DictationStage
    let enqueuedAt: Date
    let recordingDuration: TimeInterval
    let reduceMotion: Bool

    private static let trackWidth: CGFloat = 84
    private static let trackHeight: CGFloat = 4
    private static let shimmerWidth: CGFloat = 26
    private static let shimmerPeriod: TimeInterval = 1.5

    var body: some View {
        TimelineView(
            .animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 30)
        ) { context in
            let fraction = switch stage {
            case .transcribing:
                MacTranscriptionWorkload.estimatedFraction(
                    recordingDuration: recordingDuration,
                    elapsed: context.date.timeIntervalSince(enqueuedAt)
                )
            case .awaitingDelivery:
                0.96
            case .held:
                1.0
            }
            let fill = max(
                Self.trackHeight,
                Self.trackWidth * CGFloat(fraction)
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

/// The transient hold marker: a single wordless glyph, on screen for two
/// seconds, declaring that the just-finished chunk stayed here instead of
/// leaving. The clipboard glyph appears only when a private live claim proves
/// Command-V is backed by the newest held chunk; otherwise a neutral document says
/// "saved here." No count, hint, or control — the durable queue and every
/// release action live in the dashboard and menu bar.
private struct MacHUDHeldBadge: View {
    let clipboardBacked: Bool

    var body: some View {
        Image(
            systemName: MacHUDHeldSymbol.systemName(
                clipboardBacked: clipboardBacked,
                isAvailable: { name in
                    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
                }
            )
        )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                clipboardBacked
                    ? Color(nsColor: .systemOrange)
                    : Color(nsColor: .secondaryLabelColor)
            )
            .accessibilityHidden(true)
    }
}

/// "+N": dictations folded behind the rearmost visible card. Numeric only, so
/// the stack stays wordless while its true depth remains honest.
private struct MacHUDOverflowBadge: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .accessibilityHidden(true)
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
