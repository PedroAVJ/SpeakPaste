import AppKit
import Combine
import Foundation
import SwiftUI

private enum MacHUDExitStyle: Equatable {
    case fade
    case pop
    case fold
}

/// Keeps the final meaningful face mounted while its exit animation runs.
/// Product state remains in `MacAppModel`; this object owns only presentation
/// choreography around the AppKit panel boundary.
@MainActor
private final class MacHUDPresentationState: ObservableObject {
    @Published private(set) var stack = MacHUDStack.empty
    @Published private(set) var exitStyle: MacHUDExitStyle?

    func show(_ stack: MacHUDStack) {
        self.stack = stack
        exitStyle = nil
    }

    func beginExit(_ style: MacHUDExitStyle) {
        guard !stack.isEmpty else { return }
        exitStyle = style
    }

    func finishExit() {
        stack = .empty
        exitStyle = nil
    }
}

@MainActor
final class MacStatusHUDController: NSObject, ObservableObject, NSWindowDelegate {
    private let model: MacAppModel
    private let panel: MacStatusPanel
    private let presentation = MacHUDPresentationState()
    private var stateCancellables = Set<AnyCancellable>()
    private var currentPipeline = MacHUDPipeline()
    private var expiryTask: Task<Void, Never>?
    private var releaseBridgeTask: Task<Void, Never>?
    private var fadeOutTask: Task<Void, Never>?
    private var hideGeneration = 0
    private var isProgrammaticPositioning = false

    init(model: MacAppModel) {
        self.model = model

        let panel = MacStatusPanel(
            contentRect: NSRect(origin: .zero, size: MacHUDMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        super.init()

        panel.delegate = self
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
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

    func start() {
        guard stateCancellables.isEmpty else {
            currentPipeline = model.hudPipeline
            present()
            return
        }

        currentPipeline = model.hudPipeline
        model.$hudPipeline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pipeline in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentPipeline = pipeline
                    self.present()
                }
            }
            .store(in: &stateCancellables)

        Publishers.MergeMany(
            model.$hudEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$hudPlacement.map { _ in () }.eraseToAnyPublisher(),
            model.$hudCustomPosition.map { _ in () }.eraseToAnyPublisher(),
            model.$hudPositioningMode.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedDeviceID.map { _ in () }.eraseToAnyPublisher(),
            model.$devices.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.present() }
        }
        .store(in: &stateCancellables)
        present()
    }

    private func present() {
        expiryTask?.cancel()
        expiryTask = nil

        guard model.hudEnabled else {
            configurePanelForStatus()
            hidePanel()
            return
        }

        if model.hudPositioningMode {
            panel.ignoresMouseEvents = false
            panel.isMovableByWindowBackground = true
            showPanel(.positioning)
            return
        }
        configurePanelForStatus()

        let now = Date()
        let stack = MacHUDStack.resolve(pipeline: currentPipeline, at: now)
        guard !stack.isEmpty else {
            // Recorder teardown publishes a short releasing -> no capture ->
            // draining sequence. Preserve the waveform for one beat so the
            // direct handoff to dots never flashes an empty panel.
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

    private func scheduleNextExpiry(at now: Date) {
        guard let next = MacHUDStack.nextExpiry(in: currentPipeline, after: now) else {
            return
        }
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
        panel.orderFrontRegardless()
    }

    private func configurePanelForStatus() {
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
    }

    private func hidePanel() {
        releaseBridgeTask?.cancel()
        releaseBridgeTask = nil
        guard panel.isVisible else {
            presentation.finishExit()
            return
        }
        hideGeneration &+= 1
        let generation = hideGeneration
        let cardID = presentation.stack.cards.first?.id
        let style: MacHUDExitStyle
        if let cardID, model.recentlyDismissedHUDCardIDs.contains(cardID) {
            style = .fold
        } else if let cardID, model.recentlyDeliveredHUDCardIDs.contains(cardID) {
            style = .pop
        } else {
            style = .fade
        }
        presentation.beginExit(style)
        fadeOutTask?.cancel()
        fadeOutTask = Task { @MainActor [weak self] in
            let duration: TimeInterval = switch style {
            case .pop: 0.27
            case .fold: 0.35
            case .fade: 0.18
            }
            try? await Task.sleep(for: .seconds(duration + 0.03))
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
        let savedOrigin = model.hudCustomPosition.map {
            NSPoint(x: $0.x, y: $0.y)
        }
        let savedCenter = savedOrigin.map {
            NSPoint(
                x: $0.x + panel.frame.width / 2,
                y: $0.y + panel.frame.height / 2
            )
        }
        let screen = savedCenter.flatMap { center in
            NSScreen.screens.first(where: { $0.frame.contains(center) })
        }
            ?? (panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let inset: CGFloat = 4
        let size = panel.frame.size
        let desired = savedOrigin
            ?? Self.anchorOrigin(for: model.hudPlacement, on: screen, size: size)
        let x = min(
            max(desired.x, visibleFrame.minX + inset),
            visibleFrame.maxX - size.width - inset
        )
        let y = min(
            max(desired.y, visibleFrame.minY),
            visibleFrame.maxY - size.height
        )
        isProgrammaticPositioning = true
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        isProgrammaticPositioning = false
    }

    func windowDidMove(_ notification: Notification) {
        guard model.hudPositioningMode, !isProgrammaticPositioning else { return }
        model.saveHUDPosition(
            x: panel.frame.origin.x,
            y: panel.frame.origin.y
        )
    }

    private static func anchorOrigin(
        for placement: MacHUDPlacement,
        on screen: NSScreen,
        size: NSSize
    ) -> NSPoint {
        let visibleFrame = screen.visibleFrame
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
        case .custom:
            // A missing or no-longer-visible custom coordinate falls back to
            // the safe default until the user deliberately moves it again.
            NSPoint(x: centeredX, y: visibleFrame.maxY - size.height - inset)
        }
    }
}

private final class MacStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum MacHUDVisualState: Equatable {
    case nudge
    case source(MacInputMode, waiting: Bool)
    case waveform(frozen: Bool)
    case typing
    case held
    case positioning
}

private enum MacHUDMetrics {
    static let panelSize = NSSize(width: 190, height: 66)
    static let capsuleHeight: CGFloat = 36

    static func capsuleWidth(
        for visual: MacHUDVisualState,
        reduceMotion: Bool
    ) -> CGFloat {
        if reduceMotion { return 150 }
        return switch visual {
        case .nudge: 104
        case .source: 54
        case .waveform: 150
        case .typing: 64
        case .held: 56
        case .positioning: 56
        }
    }
}

private struct MacStatusHUDView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var presentation: MacHUDPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let card = presentation.stack.cards.first {
                MacHUDCapsuleView(
                    card: card,
                    inputLevel: model.inputLevel,
                    heldClipboardBacked: model.hasVisibleClipboardFallback
                        || model.heldClipboardOwnerID != nil,
                    reduceMotion: reduceMotion
                )
                .scaleEffect(
                    x: exitScale.width,
                    y: exitScale.height,
                    anchor: .center
                )
                .opacity(presentation.exitStyle == nil ? 1 : 0)
                .animation(exitAnimation, value: presentation.exitStyle)
            }
        }
        .frame(
            width: MacHUDMetrics.panelSize.width,
            height: MacHUDMetrics.panelSize.height
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            presentation.stack.accessibilityLabel(
                sourceName: model.activeSource?.title,
                heldClipboardBacked: model.hasVisibleClipboardFallback
                    || model.heldClipboardOwnerID != nil
            )
        )
    }

    private var exitScale: CGSize {
        guard !reduceMotion else { return CGSize(width: 1, height: 1) }
        return switch presentation.exitStyle {
        case .pop:
            CGSize(width: 1.12, height: 1.12)
        case .fold:
            CGSize(width: 0.5, height: 0.16)
        case .fade, nil:
            CGSize(width: 1, height: 1)
        }
    }

    private var exitAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.16) }
        return switch presentation.exitStyle {
        case .pop:
            .easeOut(duration: 0.26)
        case .fold:
            .timingCurve(0.6, 0, 0.9, 0.5, duration: 0.34)
        case .fade, nil:
            .easeOut(duration: 0.16)
        }
    }
}

/// One stable capsule. Every layer lives at the same center, so changing state
/// never shifts the visual address sideways and a paused waveform can preserve
/// the exact envelope that was visible when capture ended.
private struct MacHUDCapsuleView: View {
    let card: MacHUDStack.Card
    let inputLevel: Double
    let heldClipboardBacked: Bool
    let reduceMotion: Bool

    @State private var envelope = MacHUDLevelEnvelope()
    @State private var frozenAt = Date()

    var body: some View {
        TimelineView(
            .animation(minimumInterval: reduceMotion ? 1.0 / 15 : 1.0 / 60)
        ) { context in
            let visual = visualState(at: context.date)
            let nudge = nudgeValues
            let source = sourceValues(for: visual)
            let waveform = waveformValues(for: visual)
            ZStack {
                MacHUDSourceNudge(attempted: nudge.attempted, live: nudge.live)
                    .opacity(visual == .nudge ? 1 : 0)
                    .scaleEffect(visual == .nudge ? 1 : 0.82)

                MacHUDSourceIdentity(
                    source: source.mode,
                    showsWaitDot: source.waiting,
                    pulseDate: context.date,
                    reduceMotion: reduceMotion
                )
                .opacity(source.visible ? 1 : 0)
                .scaleEffect(source.visible ? 1 : 0.7)

                MacHUDWaveform(
                    level: inputLevel,
                    date: waveform.frozen ? frozenAt : context.date,
                    frozen: waveform.frozen,
                    isActive: waveform.visible,
                    reduceMotion: reduceMotion,
                    envelope: envelope
                )
                .opacity(waveform.visible ? 1 : 0)
                .scaleEffect(x: 1, y: waveform.visible ? 1 : 0.08)

                MacHUDTypingDots(date: context.date, reduceMotion: reduceMotion)
                    .opacity(visual == .typing ? 1 : 0)
                    .scaleEffect(visual == .typing ? 1 : 0.72)

                MacHUDHeldBadge(clipboardBacked: heldClipboardBacked)
                    .opacity(visual == .held ? 1 : 0)
                    .scaleEffect(visual == .held ? 1 : 0.72)

                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .accessibilityHidden(true)
                    .opacity(visual == .positioning ? 1 : 0)
                    .scaleEffect(visual == .positioning ? 1 : 0.72)
            }
            .frame(height: MacHUDMetrics.capsuleHeight)
            .frame(
                width: MacHUDMetrics.capsuleWidth(
                    for: visual,
                    reduceMotion: reduceMotion
                )
            )
            .modifier(MacHUDSurface())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .opacity(card.content == .resting ? 0.78 : 1)
            // The courtesy beat changes `visual` without changing the model's
            // listening state. Keying choreography to the visual state makes
            // the pill expansion, icon fade, and bar rise one continuous
            // morph instead of two unrelated updates.
            .animation(stateAnimation, value: visual)
        }
        .help(card.content == .positioning ? "Drag to move the SpeakPaste HUD" : "")
        .onChange(of: card.content) { _, content in
            if content == .resting { frozenAt = Date() }
        }
    }

    private var nudgeValues: (attempted: MacInputMode, live: MacInputMode?) {
        guard case let .sourceNudge(attempted, live) = card.content else {
            return (.mac, nil)
        }
        return (attempted, live)
    }

    private func sourceValues(
        for visual: MacHUDVisualState
    ) -> (mode: MacInputMode, waiting: Bool, visible: Bool) {
        let mode: MacInputMode = if case let .capture(source, _, _) = card.content {
            source
        } else if case let .source(source, _) = visual {
            source
        } else {
            .mac
        }
        guard case let .source(_, waiting) = visual else {
            // Keep the outgoing identity stable while it fades. Switching an
            // iPhone symbol back to the default Mac symbol during that fade is
            // still a replacement, even when the layer is almost transparent.
            return (mode, false, false)
        }
        return (mode, waiting, true)
    }

    private func waveformValues(
        for visual: MacHUDVisualState
    ) -> (frozen: Bool, visible: Bool) {
        guard case let .waveform(frozen) = visual else {
            return (false, false)
        }
        return (frozen, true)
    }

    private func visualState(at date: Date) -> MacHUDVisualState {
        switch card.content {
        case .sourceNudge:
            return .nudge
        case let .capture(source, activity, stageStartedAt):
            switch activity {
            case .connecting, .inactive:
                return .source(source, waiting: source == .iPhone)
            case .listening:
                // Mac capture is already live during this courtesy beat. The
                // first real voice sample cuts it short; otherwise it lasts no
                // more than half a second. Continuity's glyph/dot disappear on
                // capture-live, so its waveform starts immediately here.
                if source == .mac,
                   date.timeIntervalSince(stageStartedAt) < 0.5,
                   inputLevel < 0.006 {
                    return .source(.mac, waiting: false)
                }
                return .waveform(frozen: false)
            case .releasing:
                return .waveform(frozen: false)
            }
        case .resting:
            return .waveform(frozen: true)
        case .draining:
            return .typing
        case .held:
            return .held
        case .positioning:
            return .positioning
        }
    }

    private var stateAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.22)
            : .spring(response: 0.35, dampingFraction: 0.8)
    }
}

private struct MacHUDSourceIdentity: View {
    let source: MacInputMode
    let showsWaitDot: Bool
    let pulseDate: Date
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: source == .mac ? "laptopcomputer" : "iphone")
                .font(.system(size: 15, weight: .regular))
                // Identity is deliberately neutral. Status belongs to the
                // separate amber wait dot and the red live waveform.
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            if showsWaitDot {
                let pulse = reduceMotion
                    ? 0.5
                    : (sin(pulseDate.timeIntervalSinceReferenceDate * 6.6) + 1) / 2
                Circle()
                    .fill(Color(nsColor: .systemOrange))
                    .frame(width: 7, height: 7)
                    .scaleEffect(reduceMotion ? 1 : 0.85 + 0.3 * pulse)
                    .opacity(0.48 + 0.47 * pulse)
                    .shadow(
                        color: Color(nsColor: .systemOrange).opacity(
                            reduceMotion ? 0 : 0.14 + 0.26 * pulse
                        ),
                        radius: reduceMotion ? 0 : 2 + 3 * pulse
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MacHUDSourceNudge: View {
    let attempted: MacInputMode
    let live: MacInputMode?

    var body: some View {
        HStack(spacing: 9) {
            if let live { deviceGlyph(for: live).opacity(0.9) }
            Image(systemName: "pause.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            deviceGlyph(for: attempted)
                .opacity(0.48)
                .overlay {
                    Capsule()
                        .fill(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 18, height: 1.5)
                        .rotationEffect(.degrees(-32))
                }
        }
        .accessibilityHidden(true)
    }

    private func deviceGlyph(for mode: MacInputMode) -> some View {
        Image(systemName: mode == .mac ? "laptopcomputer" : "iphone")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }
}

private struct MacHUDWaveform: View {
    let level: Double
    let date: Date
    let frozen: Bool
    let isActive: Bool
    let reduceMotion: Bool
    let envelope: MacHUDLevelEnvelope

    private static let barCount = 13
    private static let barWidth: CGFloat = 3.5
    private static let barSpacing: CGFloat = 3
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(
                        frozen
                            ? Color(nsColor: .secondaryLabelColor)
                            : Color(nsColor: .systemRed)
                    )
                    .frame(width: Self.barWidth, height: height(for: index))
            }
        }
        .opacity(frozen ? 0.72 : 1)
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        let display = envelope.step(
            toward: min(max(level, 0), 1),
            at: date,
            frozen: frozen || !isActive
        )
        let perceptualInput = min(max((display - 0.004) * 10, 0), 1)
        let shaped = pow(perceptualInput, 0.60)
        let fraction = Double(index) / Double(Self.barCount - 1)
        let arch = 0.30 + 0.70 * sin(fraction * .pi)
        let wobble: Double
        if frozen || reduceMotion {
            // A deterministic non-flat silhouette stays frozen across every
            // frame, preserving the impression of the voice that just stopped.
            wobble = 0.78 + 0.22 * sin(
                frozenAtPhase * (6.5 + Double(index % 4) * 1.4)
                    + Double(index) * 1.7
            )
        } else {
            wobble = 0.78 + 0.22 * sin(
                date.timeIntervalSinceReferenceDate
                    * (6.5 + Double(index % 4) * 1.4)
                    + Double(index) * 1.7
            )
        }
        return Self.minBarHeight
            + (Self.maxBarHeight - Self.minBarHeight)
                * CGFloat(arch * wobble * shaped)
    }

    private var frozenAtPhase: TimeInterval {
        date.timeIntervalSinceReferenceDate
    }
}

private final class MacHUDLevelEnvelope {
    private var displayLevel: Double = 0.12
    private var lastStepAt: Date?

    func step(toward target: Double, at date: Date, frozen: Bool) -> Double {
        if frozen { return displayLevel }
        let dt: TimeInterval
        if let lastStepAt {
            dt = min(max(date.timeIntervalSince(lastStepAt), 0), 0.25)
        } else {
            dt = 1.0 / 60
        }
        self.lastStepAt = date
        let rising = target > displayLevel
        let timeConstant = rising ? 0.045 : 0.32
        let alpha = 1 - exp(-dt / timeConstant)
        displayLevel += (target - displayLevel) * alpha
        if displayLevel < 0.0005 { displayLevel = 0 }
        return displayLevel
    }
}

private struct MacHUDTypingDots: View {
    let date: Date
    let reduceMotion: Bool

    private static let period: TimeInterval = 1.25
    private static let stagger: TimeInterval = 0.15
    private static let hopShare = 0.4

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                let hop = reduceMotion ? 0 : Self.hop(at: date, index: index)
                Circle()
                    .fill(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 7, height: 7)
                    .opacity(0.45 + 0.55 * hop)
                    .offset(y: -5 * hop)
            }
        }
        .accessibilityHidden(true)
    }

    private static func hop(at date: Date, index: Int) -> Double {
        let shifted = date.timeIntervalSinceReferenceDate - Double(index) * stagger
        let phase = shifted.truncatingRemainder(dividingBy: period)
        let normalized = (phase < 0 ? phase + period : phase) / period
        guard normalized < hopShare else { return 0 }
        return sin(normalized / hopShare * .pi)
    }
}

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
