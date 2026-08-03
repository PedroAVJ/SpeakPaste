import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class MacStatusHUDController: ObservableObject {
    private static let panelSize = NSSize(width: 330, height: 58)

    private let model: MacAppModel
    private let panel: MacStatusPanel
    private var phaseCancellable: AnyCancellable?
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
        guard phaseCancellable == nil else {
            present(model.phase)
            return
        }

        // A held transcript or an in-flight transcription keeps the HUD up on
        // its own, so the panel reacts to all three. Otherwise "your text is
        // waiting" would vanish the moment the phase settled back to ready.
        phaseCancellable = Publishers.Merge3(
            model.$phase.map { _ in () },
            model.$heldTranscripts.map { _ in () },
            model.$inFlightCount.map { _ in () }
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

        switch phase {
        case .ready:
            if model.heldTranscripts.isEmpty, model.inFlightCount == 0 {
                panel.orderOut(nil)
            } else {
                showPanel()
            }
        case .connecting, .recording, .finalizing:
            showPanel()
        case .succeeded:
            showPanel()
            if model.heldTranscripts.isEmpty, model.inFlightCount == 0 { scheduleHide(after: 1.5) }
        case .failed:
            showPanel()
            if model.heldTranscripts.isEmpty, model.inFlightCount == 0 { scheduleHide(after: 4) }
        }
    }

    private func showPanel() {
        positionPanelOnActiveScreen()
        // `orderFrontRegardless` works while SpeakPaste is inactive. Combined
        // with a nonactivating, click-through panel, it does not steal focus
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

    private func positionPanelOnActiveScreen() {
        let screen = NSScreen.main
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let horizontalInset: CGFloat = 12
        let desiredX = visibleFrame.midX - Self.panelSize.width / 2
        let x = min(
            max(desiredX, visibleFrame.minX + horizontalInset),
            visibleFrame.maxX - Self.panelSize.width - horizontalInset
        )
        // Directly under the menu bar. The apps SpeakPaste dictates into put
        // their text field at the bottom center of the window, which is exactly
        // where a bottom-anchored HUD lands, so it covered the insertion point
        // it was reporting on. The top edge also stays clear of notification
        // banners on the right and the Dock below. `visibleFrame` already
        // excludes the menu bar and any notch.
        let topInset: CGFloat = 12
        let desiredY = visibleFrame.maxY - Self.panelSize.height - topInset
        let y = max(desiredY, visibleFrame.minY)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
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
                Text(state.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Text(state.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if let date {
                Text(elapsedText(at: date))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 13)
        .frame(width: 330, height: 58)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SpeakPaste, \(state.title), \(state.detail)")
    }

    private var displayState: MacStatusHUDDisplayState {
        switch model.phase {
        case .ready:
            if model.heldTranscripts.isEmpty, model.inFlightCount > 0 {
                // The microphone is already free. Say so, so the wait never
                // reads as "you have to stand still until this finishes".
                MacStatusHUDDisplayState(
                    symbol: "waveform.badge.magnifyingglass",
                    title: model.inFlightCount == 1
                        ? "TRANSCRIBING"
                        : "TRANSCRIBING ×\(model.inFlightCount)",
                    detail: "Mic is free — tap \(model.hotKeyLabel) to keep going",
                    color: .blue,
                    showsElapsedTime: false
                )
            } else if model.heldTranscripts.isEmpty {
                MacStatusHUDDisplayState(
                    symbol: "waveform",
                    title: "READY",
                    detail: "Tap \(model.hotKeyLabel) to start",
                    color: .secondary,
                    showsElapsedTime: false
                )
            } else {
                MacStatusHUDDisplayState(
                    symbol: "tray.full.fill",
                    title: heldTitle,
                    detail: "Click back into \(heldDestination), or \(model.releaseHotKeyLabel) to place it here",
                    color: .blue,
                    showsElapsedTime: false
                )
            }
        case .connecting:
            MacStatusHUDDisplayState(
                symbol: "antenna.radiowaves.left.and.right",
                title: "WAIT",
                detail: "Connecting — do not speak yet",
                color: .orange,
                showsElapsedTime: true
            )
        case .recording:
            MacStatusHUDDisplayState(
                symbol: "mic.fill",
                title: "SPEAK NOW",
                detail: "\(model.hotKeyLabel) to stop and transcribe",
                color: .red,
                showsElapsedTime: true
            )
        case .finalizing:
            MacStatusHUDDisplayState(
                symbol: "stop.fill",
                title: "RECORDING STOPPED",
                detail: "Releasing microphone",
                color: .orange,
                showsElapsedTime: true
            )
        case let .succeeded(detail):
            MacStatusHUDDisplayState(
                symbol: "checkmark",
                title: "DONE",
                detail: detail,
                color: .green,
                showsElapsedTime: false
            )
        case let .failed(message):
            MacStatusHUDDisplayState(
                symbol: "exclamationmark",
                title: "ERROR",
                detail: message,
                color: .red,
                showsElapsedTime: false
            )
        }
    }

    private var heldTitle: String {
        model.heldTranscripts.count == 1
            ? "TEXT WAITING"
            : "\(model.heldTranscripts.count) WAITING"
    }

    private var heldDestination: String {
        model.heldTranscripts.first?.target.applicationName ?? "the app you started in"
    }

    private func elapsedText(at date: Date) -> String {
        let totalSeconds = max(0, Int(date.timeIntervalSince(model.phaseStartedAt)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct MacStatusHUDDisplayState {
    let symbol: String
    let title: String
    let detail: String
    let color: Color
    let showsElapsedTime: Bool
}
