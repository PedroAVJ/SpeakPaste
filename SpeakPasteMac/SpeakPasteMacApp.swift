import SwiftUI

@main
struct SpeakPasteMacApp: App {
    @StateObject private var model = MacAppModel()

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(model)
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
        case .transcribing: "waveform.badge.magnifyingglass"
        case .ready, .failed: "waveform"
        }
    }

    private var menuBarAccessibilityLabel: String {
        switch model.phase {
        case .connecting: "SpeakPaste, connecting to microphone"
        case .recording: "SpeakPaste, recording"
        case .transcribing: "SpeakPaste, transcribing"
        case .ready, .failed: "SpeakPaste"
        }
    }
}

struct MacMenuBarView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        switch model.phase {
        case .connecting:
            Button("Connecting… (can take several seconds)") {}
                .disabled(true)
        case .recording:
            Button("Transcribe  \(model.hotKeyLabel)") { model.toggleRecording() }
        case .transcribing:
            Button("Transcribing…") {}
                .disabled(true)
        case .ready, .failed:
            Button("Start Recording  \(model.hotKeyLabel)") { model.toggleRecording() }
                .disabled(model.selectedDevice == nil)
        }

        Button("Copy Last Transcript") { model.copyTranscript() }
            .disabled(model.transcript.isEmpty)

        Divider()

        if model.isMicrophoneConnected, let device = model.selectedDevice {
            Text(
                device.isContinuityDevice
                    ? "iPhone linked — session stays warm"
                    : "\(device.name) linked — session stays warm"
            )
            Button("Disconnect Microphone") { model.disconnectMicrophone() }
                .disabled(model.phase.isBusy)
        } else if let device = model.selectedDevice {
            Text("Microphone: \(device.name)")
        } else {
            Text("No microphone available")
        }
    }
}
