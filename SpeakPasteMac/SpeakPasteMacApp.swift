import SwiftUI

@main
struct SpeakPasteMacApp: App {
    @StateObject private var model: MacAppModel
    @StateObject private var statusHUD: MacStatusHUDController

    init() {
        let model = MacAppModel()
        _model = StateObject(wrappedValue: model)
        _statusHUD = StateObject(wrappedValue: MacStatusHUDController(model: model))
    }

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(model)
                .onAppear { statusHUD.start() }
        }
        .defaultSize(width: 500, height: 620)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MacMenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel(menuBarAccessibilityLabel)
        }
    }

    private var menuBarSymbol: String {
        switch model.phase {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .recording: "record.circle.fill"
        case .finalizing: "stop.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .ready: "waveform"
        }
    }

    private var menuBarAccessibilityLabel: String {
        switch model.phase {
        case .connecting: "SpeakPaste, connecting to microphone"
        case .recording: "SpeakPaste, recording. Speak now. Press Command to stop and transcribe"
        case .finalizing: "SpeakPaste, recording stopped. Releasing microphone"
        case .succeeded: "SpeakPaste, done"
        case .failed: "SpeakPaste, error"
        case .ready: "SpeakPaste, ready. Press Command to start"
        }
    }
}

struct MacMenuBarView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        switch model.phase {
        case .connecting:
            Button("WAIT — connecting; do not speak yet") {}
                .disabled(true)
        case .recording:
            Button("SPEAK NOW — Stop & Transcribe  \(model.hotKeyLabel)") {
                model.toggleRecording()
            }
        case .finalizing:
            Button("RELEASING MICROPHONE…") {}
                .disabled(true)
        case let .succeeded(detail):
            Button("DONE — \(detail)") {}
                .disabled(true)
        case let .failed(message):
            Text("ERROR — \(message)")
            Button("Try Again  \(model.hotKeyLabel)") { model.toggleRecording() }
                .disabled(model.selectedDevice == nil)
        case .ready:
            if model.inFlightCount > 0 {
                Text("TRANSCRIBING \(model.inFlightCount) — microphone is free")
            }
            Button("Start Recording  \(model.hotKeyLabel)") { model.toggleRecording() }
                .disabled(model.selectedDevice == nil)
        }

        if !model.heldTranscripts.isEmpty {
            Button("Paste \(model.heldTranscripts.count) Held Here  \(model.releaseHotKeyLabel)") {
                model.releaseHeldTranscripts()
            }
        }

        Button("Copy Last Transcript") { model.copyTranscript() }
            .disabled(model.transcript.isEmpty)

        Divider()

        if model.isMicrophoneConnected, let device = model.selectedDevice {
            Text(
                device.isContinuityDevice
                    ? "iPhone microphone active — released on stop"
                    : "\(device.name) active — released on stop"
            )
        } else if let device = model.selectedDevice {
            Text("Microphone: \(device.name)")
        } else {
            Text("No microphone available")
        }
    }
}
