import AppKit
import Combine
import SwiftUI

/// Owns a tiny microphone affordance next to the active insertion point while
/// realtime dictation temporarily owns that text range. Transcript text stays
/// in the destination field itself; this panel is deliberately only a status
/// marker and never becomes an alternate transcript surface.
@MainActor
final class MacRealtimeCaretIndicatorController {
    private let model: MacAppModel
    private let panel: MacRealtimeCaretPanel
    private var frameObservation: AnyCancellable?

    init(model: MacAppModel) {
        self.model = model

        let size = MacRealtimeCaretIndicatorMetrics.panelSize
        let panel = MacRealtimeCaretPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: MacRealtimeCaretIndicatorView())
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    /// Starts observing the model. Safe to call repeatedly from SwiftUI scene
    /// lifecycle callbacks used by both the main window and the menu bar item.
    func start() {
        guard frameObservation == nil else {
            present(model.realtimeCaretFrame)
            return
        }

        frameObservation = model.$realtimeCaretFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                MainActor.assumeIsolated {
                    self?.present(frame)
                }
            }
        present(model.realtimeCaretFrame)
    }

    private func present(_ accessibilityFrame: CGRect?) {
        guard let accessibilityFrame,
              accessibilityFrame.origin.x.isFinite,
              accessibilityFrame.origin.y.isFinite,
              accessibilityFrame.width.isFinite,
              accessibilityFrame.height.isFinite,
              !accessibilityFrame.isNull,
              !accessibilityFrame.isInfinite else {
            panel.orderOut(nil)
            return
        }

        let appKitFrame = Self.appKitFrame(fromAccessibilityFrame: accessibilityFrame)
        let size = panel.frame.size
        let desiredOrigin = NSPoint(
            x: appKitFrame.maxX + MacRealtimeCaretIndicatorMetrics.caretGap,
            y: appKitFrame.midY - size.height / 2
        )
        guard let screen = Self.screen(containing: appKitFrame, near: desiredOrigin) else {
            panel.orderOut(nil)
            return
        }

        let visibleFrame = screen.visibleFrame
        let inset = MacRealtimeCaretIndicatorMetrics.screenInset
        let x = min(
            max(desiredOrigin.x, visibleFrame.minX + inset),
            visibleFrame.maxX - size.width - inset
        )
        let y = min(
            max(desiredOrigin.y, visibleFrame.minY + inset),
            visibleFrame.maxY - size.height - inset
        )
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))

        // This displays above the receiving app without activating SpeakPaste
        // or disturbing the text focus whose range is being updated.
        panel.orderFrontRegardless()
    }

    /// Accessibility uses a global top-left origin while AppKit windows use a
    /// global bottom-left origin. The first NSScreen is the macOS menu-bar
    /// (coordinate-primary) display and therefore supplies the shared axis.
    private static func appKitFrame(fromAccessibilityFrame frame: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return frame }
        return CGRect(
            x: frame.minX,
            y: primaryScreen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func screen(containing caretFrame: CGRect, near point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.intersects(caretFrame) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

private final class MacRealtimeCaretPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum MacRealtimeCaretIndicatorMetrics {
    static let panelSize = NSSize(width: 22, height: 22)
    static let caretGap: CGFloat = 5
    static let screenInset: CGFloat = 3
}

private struct MacRealtimeCaretIndicatorView: View {
    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(
                width: MacRealtimeCaretIndicatorMetrics.panelSize.width,
                height: MacRealtimeCaretIndicatorMetrics.panelSize.height
            )
            .background {
                Circle()
                    .fill(Color.accentColor)
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
                    }
                    .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
            }
            .accessibilityHidden(true)
    }
}
