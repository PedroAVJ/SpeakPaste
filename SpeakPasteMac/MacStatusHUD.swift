import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class MacStatusHUDController: ObservableObject {
    private static let panelSize = NSSize(width: 260, height: 44)

    /// Finalizing normally lasts well under a second while AVFoundation
    /// releases the microphone. If that release ever hangs, the indicator must
    /// not sit on screen forever — the dashboard and menu bar own long-lived
    /// problem reporting.
    private static let finalizingVisibilityCap: TimeInterval = 15
    /// Connection readiness is bounded in the recorder, but AVFoundation's
    /// synchronous session startup can still stall below that timeout. Keep the
    /// capture attempt alive while moving long-lived status out of the way.
    private static let connectingVisibilityCap: TimeInterval = 20

    private let model: MacAppModel
    private let panel: MacStatusPanel
    private var stateCancellable: AnyCancellable?
    private var delayedHideTask: Task<Void, Never>?

    init(model: MacAppModel) {
        self.model = model

        let panel = MacStatusPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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
        // Always click-through: the indicator has no controls, so it must
        // never intercept a click meant for the app underneath it.
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: MacStatusHUDView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
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

        // Only the capture phase can show the indicator; the enabled flag,
        // placement, and device identity are merged in so a settings or
        // source change applies to a HUD that is already on screen.
        stateCancellable = Publishers.MergeMany(
            model.$phase.map { _ in () }.eraseToAnyPublisher(),
            model.$phaseStartedAt.map { _ in () }.eraseToAnyPublisher(),
            model.$hudEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$hudPlacement.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedDeviceID.map { _ in () }.eraseToAnyPublisher(),
            model.$devices.map { _ in () }.eraseToAnyPublisher()
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

    /// The indicator exists only while SpeakPaste holds (or is acquiring or
    /// releasing) the microphone. Every other state — ready, background
    /// transcription, success, failure, offline, setup, held text — is hidden
    /// here and reported by the dashboard and menu bar instead.
    private func present(_ phase: MacCapturePhase) {
        delayedHideTask?.cancel()
        delayedHideTask = nil

        guard model.hudEnabled else {
            panel.orderOut(nil)
            return
        }

        switch phase {
        case .connecting:
            showPanel()
            scheduleHide(
                after: remainingVisibility(
                    within: Self.connectingVisibilityCap
                )
            )
        case .recording:
            showPanel()
        case .finalizing:
            showPanel()
            // Device-list refreshes can call `present` repeatedly. Measure the
            // cap from the phase transition so those refreshes can never keep
            // the indicator alive indefinitely.
            scheduleHide(
                after: remainingVisibility(
                    within: Self.finalizingVisibilityCap
                )
            )
        case .ready, .succeeded, .failed:
            panel.orderOut(nil)
        }
    }

    private func showPanel() {
        if panel.frame.size != Self.panelSize {
            panel.setContentSize(Self.panelSize)
        }
        positionPanelOnActiveScreen()
        // `orderFrontRegardless` works while SpeakPaste is inactive; the panel
        // is nonactivating and never becomes key, so it cannot steal focus
        // from the app receiving dictated text.
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
    /// the top of the screen instead. `visibleFrame` already excludes the menu
    /// bar, any notch, and the Dock.
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

private struct MacStatusHUDView: View {
    @ObservedObject var model: MacAppModel

    var body: some View {
        let state = displayState
        if state.showsTimer {
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
        HStack(spacing: 9) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(state.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let source = state.source {
                    Text(source)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if state.showsInputLevel {
                MacInputLevelMeter(level: model.inputLevel)
            }
            if let date {
                Text(elapsedText(at: date))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 13)
        .frame(width: 260, height: 44)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: state))
    }

    private var displayState: MacStatusHUDDisplayState {
        switch model.phase {
        case .connecting:
            MacStatusHUDDisplayState(
                title: "Connecting",
                source: sourceName,
                color: .orange
            )
        case .recording:
            MacStatusHUDDisplayState(
                title: "Listening",
                source: sourceName,
                color: .red,
                showsTimer: true,
                showsInputLevel: true
            )
        case .finalizing:
            MacStatusHUDDisplayState(
                title: "Releasing",
                source: sourceName,
                color: .orange
            )
        case .ready, .succeeded, .failed:
            // The panel controller never shows these; a neutral placeholder
            // keeps the view total if a redraw races a phase change.
            MacStatusHUDDisplayState(
                title: "SpeakPaste",
                source: nil,
                color: .secondary
            )
        }
    }

    private var sourceName: String? {
        model.inputMode?.title ?? model.selectedDevice?.name
    }

    private func accessibilityText(for state: MacStatusHUDDisplayState) -> String {
        var text = "SpeakPaste, \(state.title)"
        if let source = state.source {
            text += ", \(source)"
        }
        return text
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
        // The combined HUD label already announces the capture state; a level
        // readout that changes many times a second is VoiceOver noise.
        .accessibilityHidden(true)
    }

    private var litCount: Int {
        let clamped = min(max(level, 0), 1)
        return Int((clamped * Double(Self.barCount)).rounded())
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let position = Double(index) / Double(Self.barCount - 1)
        return 6 + CGFloat(sin(position * .pi) * 8)
    }
}

private struct MacStatusHUDDisplayState {
    let title: String
    let source: String?
    let color: Color
    var showsTimer = false
    var showsInputLevel = false
}
