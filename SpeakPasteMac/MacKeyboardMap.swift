import AppKit
import SwiftUI

/// The menu-bar surface: a live map of the user's own keyboard with the four
/// bound keys lit and every other key drawn blank. The point is to show at a
/// glance which four keys mean anything right now — not to offer a second way
/// to press them, so nothing on the board is clickable.
struct MacKeyboardMapPanel: View {
    @EnvironmentObject private var model: MacAppModel
    @EnvironmentObject private var presence: MacApplicationPresenceCoordinator
    @Environment(\.openSettings) private var openSettings

    private static let keyUnit: CGFloat = 21

    private var shape: MacPhysicalKeyboardShape { MacPhysicalKeyboardShape.current }

    private var indications: [MacDictationKey: MacKeyIndication] {
        MacKeyboardMapState.indications(
            phase: model.phase,
            activeSource: model.activeSource,
            hasBankedSegments: model.hasBankedSegments,
            canStartRecording: model.canStartRecording
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            board
            legend
            Divider()
            footer
        }
        .padding(14)
        .frame(width: MacKeyboardMapLayout.unitsWide * Self.keyUnit + 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SpeakPaste key map")
    }

    private var board: some View {
        ZStack(alignment: .topLeading) {
            ForEach(MacKeyboardMapLayout.keys(for: shape)) { key in
                keyCap(key)
            }
        }
        .frame(
            width: MacKeyboardMapLayout.unitsWide * Self.keyUnit,
            height: MacKeyboardMapLayout.unitsTall * Self.keyUnit,
            alignment: .topLeading
        )
        .animation(.easeInOut(duration: 0.18), value: model.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boardAccessibilityLabel)
    }

    private func keyCap(_ key: MacKeyboardMapKey) -> some View {
        let indication = key.binding.flatMap { indications[$0] } ?? .blank
        let inset: CGFloat = 1.5
        return RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(fill(for: indication))
            .overlay {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(stroke(for: indication), lineWidth: 1)
            }
            .overlay {
                if let symbol = indication.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(foreground(for: indication))
                }
            }
            .frame(
                width: CGFloat(key.width) * Self.keyUnit - inset * 2,
                height: CGFloat(key.height) * Self.keyUnit - inset * 2
            )
            .offset(
                x: CGFloat(key.x) * Self.keyUnit + inset,
                y: CGFloat(key.y) * Self.keyUnit + inset
            )
    }

    private func fill(for indication: MacKeyIndication) -> AnyShapeStyle {
        switch indication {
        case .blank, .inert, .refused:
            AnyShapeStyle(Color.primary.opacity(0.05))
        case let .active(_, tint):
            AnyShapeStyle(color(for: tint).opacity(0.20))
        }
    }

    private func stroke(for indication: MacKeyIndication) -> AnyShapeStyle {
        switch indication {
        case .blank:
            AnyShapeStyle(Color.primary.opacity(0.10))
        case .inert, .refused:
            AnyShapeStyle(Color.primary.opacity(0.18))
        case let .active(_, tint):
            AnyShapeStyle(color(for: tint).opacity(0.85))
        }
    }

    private func foreground(for indication: MacKeyIndication) -> AnyShapeStyle {
        switch indication {
        case .blank:
            AnyShapeStyle(Color.clear)
        case .inert, .refused:
            AnyShapeStyle(Color.secondary.opacity(0.45))
        case let .active(_, tint):
            AnyShapeStyle(color(for: tint))
        }
    }

    private func color(for tint: MacKeyTint) -> Color {
        switch tint {
        case .source: model.phase == .recording ? .red : .accentColor
        case .deliver: .green
        case .discard: .orange
        }
    }

    /// One clause per lit key, so VoiceOver gets the same reading the picture
    /// gives at a glance instead of an unlabeled grid of rectangles.
    private var boardAccessibilityLabel: String {
        let live = MacDictationKey.allCases.compactMap { key -> String? in
            guard indications[key]?.isActive == true else { return nil }
            return "\(key.spokenLabel): \(verb(for: key))"
        }
        guard !live.isEmpty else { return "No dictation key is active." }
        return live.joined(separator: ". ")
    }

    private func verb(for key: MacDictationKey) -> String {
        switch key {
        case .macSource, .iPhoneSource:
            switch model.phase {
            case .recording: "pause"
            case .paused: "resume"
            case .connecting: "record here instead"
            default: "start"
            }
        case .end: "end and deliver"
        case .cancel: model.phase == .paused ? "discard this dictation" : "discard"
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(MacDictationKey.allCases) { key in
                if indications[key]?.isActive == true {
                    Text("\(key.shortcutLabel)  \(verb(for: key))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Label(notice, systemImage: noticeSymbol)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Open SpeakPaste") { presence.openDashboard() }
                Button("Settings…") {
                    presence.openSettings { openSettings() }
                }
                Spacer(minLength: 0)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }

    private var notice: String? {
        if !model.hasAPIKey { return "Setup needed: add an ElevenLabs API key" }
        if model.selectedDevice == nil { return "Setup needed: choose a microphone" }
        if model.permissions.granted[.microphone] != true {
            return "Setup needed: grant microphone access"
        }
        if !model.isShortcutGlobal {
            return "The dictation keys work only inside SpeakPaste until Accessibility is granted"
        }
        if !model.networkIsAvailable {
            return "Offline — recordings stay saved and retry on reconnect"
        }
        return nil
    }

    private var noticeSymbol: String {
        model.networkIsAvailable ? "exclamationmark.triangle.fill" : "wifi.slash"
    }
}
