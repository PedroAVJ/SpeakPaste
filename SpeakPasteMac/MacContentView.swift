import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        Group {
            if model.hasCompletedOnboarding {
                MacDashboardView()
            } else {
                MacOnboardingView()
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 580, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - File import

/// The one place the importable formats are listed, shared by the dashboard
/// card and the onboarding summary so the two can never drift apart.
enum MacAudioImportPanel {
    static let allowedExtensions = ["wav", "mp3", "m4a", "mp4", "mov", "ogg", "opus", "flac", "aac"]

    @MainActor
    static func present(onPick: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose an audio or video file to transcribe with ElevenLabs Scribe."
        panel.prompt = "Transcribe"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url)
    }
}

// MARK: - Dashboard

private struct MacDashboardView: View {
    @EnvironmentObject private var model: MacAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var destructiveAction: DashboardDestructiveAction?
    @State private var microphoneTestDeviceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let notice = model.previousSessionRecoveryNotice {
                        recoveryNoticeBanner(notice)
                    }
                    if let notice = model.recoveryNotice {
                        recoveryActionNoticeBanner(notice)
                    }
                    if !model.heldTranscripts.isEmpty {
                        heldBanner
                    }
                    if !model.retryableFailures.isEmpty {
                        retryBanner
                    }
                    if !model.hasAPIKey {
                        apiKeySection
                    }
                    captureSection
                    if case let .failed(message) = model.phase {
                        failureBanner(message)
                    }
                    microphoneSection
                    transcriptSection
                    reliabilitySection
                }
                .padding(20)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.isMicrophoneConnected)
        .onChange(of: model.selectedDeviceID) { _, selectedDeviceID in
            if microphoneTestDeviceID != selectedDeviceID {
                microphoneTestDeviceID = nil
            }
        }
        .confirmationDialog(
            destructiveConfirmationTitle,
            isPresented: destructiveConfirmationPresented,
            titleVisibility: .visible
        ) {
            destructiveConfirmationActions
        } message: {
            Text(destructiveConfirmationMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("SpeakPaste")
                    .font(.headline)
                Text("Dictate on your Mac. Paste anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(statusText)")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open Settings")
        }
    }

    private var statusColor: Color {
        return switch model.phase {
        case .connecting: .yellow
        case .recording: .red
        case .finalizing: .orange
        case .succeeded: .green
        case .failed: .orange
        case .ready:
            model.networkIsAvailable
                && model.hasAPIKey
                && model.selectedDevice != nil
                && model.permissions.granted[.microphone] == true
                ? .green
                : .orange
        }
    }

    private var statusText: String {
        switch model.phase {
        case .connecting: return "Connecting…"
        case .recording: return "Speak now"
        case .finalizing: return "Releasing microphone"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .ready:
            if model.inFlightCount > 0 { return "Transcribing \(model.inFlightCount)" }
            if model.selectedDevice == nil { return "No microphone" }
            if !model.hasAPIKey { return "Needs API key" }
            if model.permissions.granted[.microphone] != true { return "Needs microphone access" }
            if !model.networkIsAvailable { return "Offline — recordings will queue" }
            return "Ready"
        }
    }

    // MARK: Recovery notice

    private func recoveryNoticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(notice)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismissPreviousSessionRecoveryNotice() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.blue.opacity(0.3)))
        .accessibilityElement(children: .contain)
    }

    private func recoveryActionNoticeBanner(_ notice: String) -> some View {
        let isWarning = notice.localizedCaseInsensitiveContains("could not")
            || notice.localizedCaseInsensitiveContains("needs attention")
            || notice.localizedCaseInsensitiveContains("needs journal recovery")
            || notice.localizedCaseInsensitiveContains("no longer present")
        let tint: Color = isWarning ? .orange : .green
        return HStack(alignment: .top, spacing: 8) {
            Label(
                notice,
                systemImage: isWarning ? "externaldrive.badge.exclamationmark" : "checkmark.circle.fill"
            )
                .font(.callout)
                .foregroundStyle(isWarning ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Recovery status: \(notice)")
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismissRecoveryNotice() }
                .controlSize(.small)
        }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.3)))
            .accessibilityElement(children: .contain)
    }

    // MARK: Held transcripts

    private var heldBanner: some View {
        let count = model.heldTranscripts.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(
                    systemName: MacHUDHeldSymbol.systemName(
                        clipboardBacked: model.heldClipboardOwnerID != nil,
                        isAvailable: { name in
                            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
                        }
                    )
                )
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 transcript is waiting" : "\(count) transcripts are waiting")
                        .font(.callout.weight(.medium))
                    Text(heldExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text(model.heldTranscripts.map(\.text).joined(separator: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))

            HStack(spacing: 8) {
                Button("Copy All") { model.copyHeldTranscripts() }
                    .controlSize(.small)
                if model.hasUncertainHeldTranscripts {
                    Button("Arm Paste Anyway…") {
                        destructiveAction = .pasteUncertainHeld
                    }
                    .controlSize(.small)
                }
                Button("Discard All…", role: .destructive) {
                    destructiveAction = .discardHeld
                }
                    .controlSize(.small)
                Spacer()
            }
            Text("To paste, switch to the intended destination field and press \(model.releaseHotKeyLabel). The dashboard itself is an app window, so it never guesses at the field that was focused before you clicked it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.blue.opacity(0.3)))
    }

    private var heldExplanation: String {
        if model.hasUncertainHeldTranscripts {
            return "At least one recovery copy may already be in its destination. SpeakPaste will not retry it automatically. Verify the destination, then copy, discard, or arm one explicit Paste Anyway attempt."
        }
        let recoveredCount = model.heldTranscripts.filter(\.isRecovered).count
        let live = model.heldTranscripts.filter { !$0.isRecovered }

        if live.isEmpty {
            return "Recovered from a previous session. Focus the field where the text belongs, then press \(model.releaseHotKeyLabel) or use the menu-bar Paste command."
        }
        if recoveredCount > 0 {
            return "\(recoveredCount) recovered transcript\(recoveredCount == 1 ? "" : "s") and \(live.count) same-session transcript\(live.count == 1 ? "" : "s") need manual placement at the current writable cursor."
        }
        return "Focus the writable editor where this text belongs, then press \(model.releaseHotKeyLabel). Waiting text is never replayed automatically."
    }

    private var retryBanner: some View {
        let count = model.retryableFailures.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 dictation did not transcribe" : "\(count) dictations did not transcribe")
                        .font(.callout.weight(.medium))
                    Text("The audio is saved. Connection failures resume after a real reconnect; every other failure waits for Retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            ForEach(model.retryableFailures) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(failure.deviceName) · \(timeString(failure.recordingDuration)) · \(failure.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Retry") { model.retry(failure) }
                            .controlSize(.small)
                        Button {
                            destructiveAction = .discardFailure(failure)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Discard this recording")
                    }
                    Label(
                        failure.retriesOnReconnect
                            ? "Retries after the next connection recovery; output will wait for manual placement"
                            : "Manual retry required",
                        systemImage: failure.retriesOnReconnect ? "wifi" : "hand.tap"
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(failure.retriesOnReconnect ? .blue : .secondary)
                    Text(failure.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if count > 1 {
                HStack(spacing: 8) {
                    Button("Retry All") { model.retryAllFailures() }
                        .controlSize(.small)
                    Button("Discard All…", role: .destructive) {
                        destructiveAction = .discardAllFailures
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.3)))
    }

    // MARK: Capture

    private var captureSection: some View {
        VStack(spacing: 10) {
            recordButton

            Text(timeString(model.elapsed))
                .font(.system(size: 28, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.phase == .recording ? .primary : .tertiary)
                .contentTransition(.numericText())
                .accessibilityLabel(elapsedAccessibilityLabel)

            InputLevelMeter(
                level: model.inputLevel,
                isActive: model.phase == .recording || model.microphoneTestState == .listening
            )

            if !model.networkIsAvailable {
                Label(
                    "Offline — new recordings stay saved on this Mac, retry once when the connection returns, and then wait for manual placement.",
                    systemImage: "wifi.slash"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let warning = model.recordingWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.phase == .recording || model.phase == .finalizing,
               model.capturedContextTermCount > 0 {
                Label(
                    "\(model.capturedContextTermCount) context spelling hint\(model.capturedContextTermCount == 1 ? "" : "s") prepared for this transcription",
                    systemImage: "text.viewfinder"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if model.phase == .recording || model.phase == .connecting {
                Button("Cancel  \(model.cancelHotKeyLabel)", role: .destructive) {
                    model.requestRecordingCancellation()
                }
                    .controlSize(.small)
                    .accessibilityHint("Immediately discards this recording without transcribing it.")
            }

            Text(captureHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            captureControlLabel
                .frame(height: 72)
        }
        .buttonStyle(.plain)
        .disabled(
            model.phase == .finalizing
                || model.phase == .connecting
                || (model.phase != .recording && !capturePrerequisitesMet)
                || model.microphoneTestState.isRunning
        )
        .opacity(model.phase == .recording || capturePrerequisitesMet ? 1 : 0.4)
        .accessibilityLabel(recordButtonLabel)
        .accessibilityHint(recordButtonHint)
    }

    @ViewBuilder
    private var captureControlLabel: some View {
        switch model.phase {
        case .recording:
            // The completion action is labeled, not just a stop glyph, so it is
            // unambiguous that finishing sends the audio to transcription.
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Stop & Transcribe  \(model.hotKeyLabel)")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color.red))
        case .connecting, .finalizing:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.06))
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(Color.red.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                ProgressView()
                    .controlSize(.regular)
            }
        case .succeeded:
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
            }
        case .ready, .failed:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(Color.red.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Color.red)
                    .frame(width: 30, height: 30)
            }
        }
    }

    private var recordButtonLabel: String {
        if model.phase == .recording { return "Stop and transcribe" }
        if !model.hasAPIKey { return "API key required before recording" }
        if model.selectedDevice == nil { return "Microphone selection required before recording" }
        if model.permissions.granted[.microphone] != true {
            return "Microphone access required before recording"
        }
        return switch model.phase {
        case .connecting: "Connecting to microphone"
        case .recording: "Stop and transcribe"
        case .finalizing: "Releasing microphone"
        case .succeeded: "Done"
        case .ready, .failed: "Start recording"
        }
    }

    private var recordButtonHint: String {
        switch model.phase {
        case .connecting: "Please wait. The first connection can take several seconds."
        case .recording: "Stops recording and sends the audio to ElevenLabs for transcription."
        case .finalizing: "The recording has stopped and SpeakPaste is releasing the microphone."
        case .succeeded: "The transcript is ready."
        case .ready, .failed: "Starts recording from the selected microphone."
        }
    }

    private var capturePrerequisitesMet: Bool {
        model.hasAPIKey
            && model.selectedDevice != nil
            && model.permissions.granted[.microphone] == true
    }

    private var elapsedAccessibilityLabel: String {
        model.phase == .recording
            ? "Recording, \(timeString(model.elapsed)) elapsed"
            : "Elapsed time \(timeString(model.elapsed))"
    }

    private var captureHint: String {
        if !model.phase.isBusy {
            if !model.hasAPIKey {
                return "Save an ElevenLabs API key above before recording."
            }
            if model.selectedDevice == nil {
                return "Choose a microphone below before recording."
            }
            if model.permissions.granted[.microphone] != true {
                return "Grant microphone access below before recording."
            }
        }
        return switch model.phase {
        case .connecting:
            model.selectedDevice?.isContinuityDevice == true
                ? "WAIT — do not speak yet. Connecting to your iPhone can take several seconds."
                : "WAIT — do not speak yet. Connecting to the microphone."
        case .recording: "SPEAK NOW — tap \(model.hotKeyLabel) to stop and transcribe; \(model.cancelHotKeyLabel) cancels immediately."
        case .finalizing:
            model.selectedDevice?.isContinuityDevice == true
                ? "RECORDING STOPPED — releasing the iPhone microphone…"
                : "RECORDING STOPPED — releasing the microphone…"
        case let .succeeded(detail): "DONE — \(detail)"
        case .ready, .failed:
            model.inFlightCount > 0
                ? "MIC IS FREE — \(model.inFlightCount) transcribing. Start the next one whenever you want."
                : "Use \(model.hotKeyLabel) in the destination app for automatic paste. Recording here leaves the result ready to copy."
        }
    }

    // MARK: Failure

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") {
                model.clearFailure()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.3)))
        .accessibilityElement(children: .contain)
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MacSectionHeader("MICROPHONE")
                Spacer()
                Button {
                    microphoneTestDeviceID = model.selectedDeviceID
                    model.testSelectedMicrophone()
                } label: {
                    Label("Test (3 s)", systemImage: "waveform.badge.mic")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(
                    model.selectedDevice == nil
                        || model.phase.isBusy
                        || model.microphoneTestState.isRunning
                )
                .help("Records three seconds from the selected microphone, plays it back, and reports the levels heard.")
                .accessibilityLabel("Test the selected microphone for three seconds")

                Button {
                    model.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh microphone list")
                .disabled(model.phase.isBusy || model.isMicrophoneConnected)
            }

            if model.permissions.granted[.microphone] != true {
                HStack(alignment: .center, spacing: 8) {
                    Label("Microphone access is required to record.", systemImage: "mic.badge.xmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Grant Access") { model.permissions.request(.microphone) }
                        .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))
                .accessibilityElement(children: .contain)
            }

            if model.isMicrophoneConnected {
                activeMicrophoneRow
            } else if model.devices.isEmpty {
                Text(model.deviceSelectionNotice
                    ?? "No microphones found. Connect one or bring your iPhone nearby, then refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                if let notice = model.deviceSelectionNotice {
                    noticeBanner(notice)
                }

                VStack(spacing: 2) {
                    ForEach(model.devices) { device in
                        deviceRow(device)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Microphone selector")

                if let gain = model.selectedDevice?.inputVolume {
                    inputGainRow(gain)
                }

                if !model.preferredDeviceIDs.isEmpty {
                    preferredOrderBlock
                }

                Text(deviceStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            microphoneTestStatusLine
        }
    }

    @ViewBuilder
    private var microphoneTestStatusLine: some View {
        if microphoneTestDeviceID == nil,
           model.microphoneTestState != .idle {
            Label("Test this selected microphone to see its result.", systemImage: "waveform.badge.mic")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            microphoneTestStateLine
        }
    }

    @ViewBuilder
    private var microphoneTestStateLine: some View {
        switch model.microphoneTestState {
        case .idle:
            EmptyView()
        case .connecting:
            Label("Connecting to the microphone…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .listening:
            Label("Listening — speak normally for three seconds…", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.red)
        case let .succeeded(summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inputGainRow(_ gain: Float) -> some View {
        HStack(spacing: 8) {
            Text("Input gain")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(gain))
                .frame(maxWidth: 140)
            Text("\(Int((gain * 100).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input gain \(Int((gain * 100).rounded())) percent")
    }

    private var preferredOrderBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FALLBACK ORDER")
                .font(.caption2.weight(.semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
            ForEach(Array(model.preferredDeviceIDs.enumerated()), id: \.element) { index, deviceID in
                preferredRow(rank: index + 1, deviceID: deviceID)
            }
            Text("SpeakPaste uses the first microphone in this list that is available. It never adds one on its own.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
    }

    private func preferredRow(rank: Int, deviceID: String) -> some View {
        let name = model.devices.first { $0.id == deviceID }?.name
        return HStack(spacing: 6) {
            Text("\(rank).")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(name ?? "Not connected")
                .font(.caption)
                .foregroundStyle(name == nil ? .tertiary : .primary)
                .lineLimit(1)
            Spacer()
            Button {
                model.movePreferredDevice(deviceID, by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(rank == 1)
            .accessibilityLabel("Move \(name ?? "saved microphone") up in the fallback order")
            Button {
                model.movePreferredDevice(deviceID, by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(rank == model.preferredDeviceIDs.count)
            .accessibilityLabel("Move \(name ?? "saved microphone") down in the fallback order")
            Button {
                model.removePreferredDevice(deviceID)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(name ?? "saved microphone") from the fallback order")
        }
    }

    private var activeMicrophoneRow: some View {
        let device = model.selectedDevice
        let isContinuity = device?.isContinuityDevice == true
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isContinuity ? "iphone" : "laptopcomputer")
                .font(.system(size: 15))
                .foregroundStyle(.green)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(
                        device.map { "\($0.name) · \($0.sourceLabel) active" }
                            ?? "Microphone active"
                    )
                        .font(.callout.weight(.medium))
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                Text(activeMicrophoneDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let latency = model.connectionLatency {
                    Text(String(format: "First connection took %.1f s.", latency))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.green.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    private var activeMicrophoneDetailText: String {
        model.selectedDevice?.isContinuityDevice == true
            ? "SpeakPaste releases the Continuity session—and your iPhone—as soon as you stop."
            : "SpeakPaste releases the microphone as soon as you stop."
    }

    private func deviceRow(_ device: MacAudioInputDevice) -> some View {
        let isSelected = device.id == model.selectedDeviceID
        let rank = model.preferredDeviceIDs.firstIndex(of: device.id).map { $0 + 1 }
        return Button {
            microphoneTestDeviceID = nil
            model.selectDevice(device.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.isContinuityDevice ? "iphone" : "laptopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)

                Text(device.sourceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(device.isContinuityDevice ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.5)))

                if let rank, model.preferredDeviceIDs.count > 1 {
                    Text("#\(rank)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Fallback rank \(rank)")
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.phase.isBusy)
        .accessibilityLabel(
            "\(device.name), \(device.sourceLabel) microphone"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "iphone.slash")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }

    private var deviceStatusLine: String {
        guard let device = model.selectedDevice else {
            return "Nothing selected — SpeakPaste will not pick a microphone for you."
        }
        return "Using \(device.name) · \(device.sourceLabel)."
    }

    // MARK: API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacSectionHeader("ELEVENLABS API KEY")
            HStack(spacing: 8) {
                SecureField("Paste your API key", text: $model.apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveAPIKey() }
                    .accessibilityLabel("ElevenLabs API key")
                Button("Save") { model.saveAPIKey() }
                    .disabled(
                        model.apiKeyDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
            }
            if let notice = model.apiKeyNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Required for transcription. Stored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MacSectionHeader("LAST TRANSCRIPT")
                Spacer()
                Button {
                    MacAudioImportPanel.present { model.transcribeFile($0) }
                } label: {
                    Label("Import Audio…", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(!model.hasAPIKey || model.phase.isBusy)
                .help(
                    model.phase.isBusy
                        ? "Stop or cancel the active recording before importing audio."
                        : "Transcribes an existing recording (\(MacAudioImportPanel.allowedExtensions.joined(separator: ", ")))."
                )
                .accessibilityHint("Opens a file picker and sends the chosen audio to ElevenLabs.")
            }

            ZStack(alignment: .topLeading) {
                if model.lastTranscriptOutputIsResolved {
                    TextEditor(text: $model.transcript)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(height: 88)
                        .accessibilityLabel("Transcript")
                        .accessibilityHint("Editable. Shows SpeakPaste's finalized transcript after local formatting and corrections.")
                } else {
                    ScrollView {
                        Text(model.transcript)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .textSelection(.disabled)
                    }
                    .frame(height: 88)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Transcript awaiting recovery resolution")
                    .accessibilityValue(model.transcript)
                    .accessibilityHint("Read only until Copy, Discard, or the waiting-text recovery flow resolves this transcript.")
                }

                if model.transcript.isEmpty {
                    Text("Nothing transcribed yet. Your latest transcript appears here.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))

            HStack(spacing: 8) {
                Button {
                    if model.copyTranscript() { flashCopied() }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(model.transcript.isEmpty)
                .accessibilityHint("Puts the transcript on the clipboard.")

                Button {
                    model.learnTranscriptEdits()
                } label: {
                    Label("Learn Edits", systemImage: "graduationcap")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(!transcriptIsEdited || !model.lastTranscriptOutputIsResolved)
                .help("Turns word-for-word spelling fixes into permanent corrections.")
                .accessibilityHint("Saves your spelling corrections as replacement rules for future dictations.")

                Spacer()

                Button {
                    model.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(model.transcript.isEmpty || !model.lastTranscriptOutputIsResolved)
                .accessibilityHint("Empties the transcript field.")
            }

            if let notice = model.transcriptLearningNotice {
                Label(notice, systemImage: "graduationcap.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.fileImportNotice {
                Label(notice, systemImage: "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                model.lastTranscriptOutputIsResolved
                    ? "Editable — this is the finalized transcript after your replacements, spoken formatting commands, and cursor-aware spacing are applied."
                    : "Read-only while recovery owns this output. Use Copy or the waiting-text review flow before editing or clearing it."
            )
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var transcriptIsEdited: Bool {
        !model.originalTranscript.isEmpty && model.transcript != model.originalTranscript
    }

    // MARK: Reliability log

    private var reliabilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MacSectionHeader("RECENT ATTEMPTS")
                Spacer()
                if let rate = model.successRate {
                    Text("\(Int((rate * 100).rounded()))% success · \(model.attempts.count) total")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "\(Int((rate * 100).rounded())) percent success across \(model.attempts.count) attempts"
                        )
                }
            }

            if model.attempts.isEmpty {
                Text("No attempts yet. Each recording is logged here with its outcome and timings.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.attempts.enumerated()), id: \.element.id) { index, attempt in
                        attemptRow(attempt)
                        if index < model.attempts.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func attemptRow(_ attempt: MacReliabilityAttempt) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: attempt.outcome == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(attempt.outcome == .success ? .green : .red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(attempt.detail)
                    .font(.caption)
                    .lineLimit(2)
                Text(attempt.deviceName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(attemptTimings(attempt))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(attempt.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attemptAccessibilityLabel(attempt))
    }

    private func attemptTimings(_ attempt: MacReliabilityAttempt) -> String {
        var parts = ["rec \(timeString(attempt.recordingDuration))"]
        if attempt.transcriptionDuration > 0 {
            parts.append(String(format: "stt %.1fs", attempt.transcriptionDuration))
        }
        return parts.joined(separator: " · ")
    }

    private func attemptAccessibilityLabel(_ attempt: MacReliabilityAttempt) -> String {
        let outcome = attempt.outcome == .success ? "Success" : "Failure"
        var label =
            "\(outcome). \(attempt.detail). \(attempt.deviceName). "
            + "Recording \(timeString(attempt.recordingDuration))"
        if attempt.transcriptionDuration > 0 {
            label += String(format: ", transcription %.1f seconds", attempt.transcriptionDuration)
        }
        return label
    }

    // MARK: Helpers

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @State private var copied = false

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var destructiveConfirmationPresented: Binding<Bool> {
        Binding(
            get: { destructiveAction != nil },
            set: { isPresented in
                if !isPresented { destructiveAction = nil }
            }
        )
    }

    private var destructiveConfirmationTitle: String {
        switch destructiveAction {
        case .pasteUncertainHeld:
            "Arm one paste that may duplicate text?"
        case .discardHeld:
            "Discard every waiting transcript?"
        case .discardFailure:
            "Discard this saved recording?"
        case .discardAllFailures:
            "Discard every saved recording?"
        case nil:
            "Discard saved content?"
        }
    }

    private var destructiveConfirmationMessage: String {
        switch destructiveAction {
        case .pasteUncertainHeld:
            "A previous paste may have succeeded without confirmation, or its recovery copy could not be cleared. After arming, return to the intended destination and press \(model.releaseHotKeyLabel). The authorization applies once to exactly the waiting text shown here."
        case .discardHeld:
            "This deletes \(model.heldTranscripts.count) waiting transcript\(model.heldTranscripts.count == 1 ? "" : "s") from the recovery queue. The queued text cannot be restored."
        case let .discardFailure(failure):
            "The \(timeString(failure.recordingDuration)) recording from \(failure.deviceName) has not been transcribed. Its saved audio will be deleted and cannot be recovered."
        case .discardAllFailures:
            "The saved audio for \(model.retryableFailures.count) failed dictation\(model.retryableFailures.count == 1 ? "" : "s") will be deleted and cannot be recovered."
        case nil:
            "This cannot be undone."
        }
    }

    @ViewBuilder
    private var destructiveConfirmationActions: some View {
        switch destructiveAction {
        case .pasteUncertainHeld:
            Button("Arm One Paste") {
                destructiveAction = nil
                model.armUncertainHeldPaste()
            }
        case .discardHeld:
            Button("Discard Waiting Transcripts", role: .destructive) {
                model.discardHeldTranscripts()
                destructiveAction = nil
            }
        case let .discardFailure(failure):
            Button("Discard Recording", role: .destructive) {
                model.discardFailure(failure)
                destructiveAction = nil
            }
        case .discardAllFailures:
            Button("Discard All Recordings", role: .destructive) {
                for failure in model.retryableFailures { model.discardFailure(failure) }
                destructiveAction = nil
            }
        case nil:
            EmptyView()
        }
        Button("Cancel", role: .cancel) {
            destructiveAction = nil
        }
    }
}

private enum DashboardDestructiveAction: Identifiable {
    case pasteUncertainHeld
    case discardHeld
    case discardFailure(MacRetryableDictation)
    case discardAllFailures

    var id: String {
        switch self {
        case .pasteUncertainHeld: "paste-uncertain-held"
        case .discardHeld: "discard-held"
        case let .discardFailure(failure): "discard-failure-\(failure.id.uuidString)"
        case .discardAllFailures: "discard-all-failures"
        }
    }
}

// MARK: - Shared bits

struct MacSectionHeader: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct InputLevelMeter: View {
    let level: Double
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 26

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(barColor(index))
                    .frame(width: 4, height: 14)
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func barColor(_ index: Int) -> Color {
        guard isActive, Double(index) / Double(barCount) < level else {
            return .primary.opacity(0.1)
        }
        return .red
    }
}

// MARK: - Onboarding

private enum MacOnboardingStep: Int, CaseIterable {
    case welcome
    case apiKey
    case permissions
    case microphone
    case shortcuts
    case language
    case ready

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .apiKey: "API Key"
        case .permissions: "Permissions"
        case .microphone: "Microphone"
        case .shortcuts: "Shortcuts"
        case .language: "Language"
        case .ready: "Ready"
        }
    }
}

private struct MacOnboardingView: View {
    @EnvironmentObject private var model: MacAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: MacOnboardingStep = .welcome
    @State private var microphoneTestDeviceID: String?

    var body: some View {
        VStack(spacing: 0) {
            onboardingHeader
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                stepContent
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            onboardingFooter
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: step)
        .onAppear { model.permissions.refresh() }
        .onChange(of: model.selectedDeviceID) { _, selectedDeviceID in
            if microphoneTestDeviceID != selectedDeviceID {
                microphoneTestDeviceID = nil
            }
        }
    }

    private var onboardingHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Set up SpeakPaste")
                    .font(.headline)
                Text("Step \(step.rawValue + 1) of \(MacOnboardingStep.allCases.count) · \(step.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            HStack(spacing: 5) {
                ForEach(MacOnboardingStep.allCases, id: \.rawValue) { candidate in
                    Circle()
                        .fill(candidate.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)

            Button("Skip") { model.completeOnboarding() }
                .controlSize(.small)
                .accessibilityHint("Closes setup. You can replay it any time from Settings.")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .apiKey: apiKeyStep
        case .permissions: permissionsStep
        case .microphone: microphoneStep
        case .shortcuts: shortcutsStep
        case .language: languageStep
        case .ready: readyStep
        }
    }

    private var onboardingFooter: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    if let previous = MacOnboardingStep(rawValue: step.rawValue - 1) { step = previous }
                }
            }
            Spacer()
            if step == .ready {
                Button("Finish") { model.completeOnboarding() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    if let next = MacOnboardingStep(rawValue: step.rawValue + 1) { step = next }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Dictate in any app. Delivery follows your current writable cursor.")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Tap \(model.hotKeyLabel) once in any app to start or stop. Tap it twice to switch the sticky input mode between this Mac and your iPhone — even while speaking. SpeakPaste transcribes with ElevenLabs Scribe and delivers to the writable, non-secure editor focused when the text is ready. If none is focused, the newest transcript becomes the clipboard fallback.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                onboardingBullet("mic", "Your iPhone's microphone is released as soon as recording stops, before transcription begins.")
                onboardingBullet("checkmark.seal", "Every finished recording stays journaled until its final text, temporary delivery escrow, and linked consumption receipt are durable; unresolved text waits safely.")
                onboardingBullet("waveform.badge.plus", "By default, successful audio stays private on this Mac with History for playback and Process Again. History retention — including Never store — is under your control in Settings.")
                onboardingBullet("lock", "Transcription uses ElevenLabs Scribe; optional context hints are controlled in Settings.")
            }
        }
    }

    private func onboardingBullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect ElevenLabs")
                .font(.title3.weight(.semibold))
            Text("Transcription runs on ElevenLabs Scribe and needs your API key. Create one at elevenlabs.io under your profile's API Keys, then paste it below. It is stored only in this Mac's Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.hasSavedAPIKey {
                Label("A key is saved in the Keychain — you're set.", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else if model.hasAPIKey {
                Label("A key was found in the ELEVENLABS_API_KEY environment variable.", systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            HStack(spacing: 8) {
                SecureField(
                    model.hasSavedAPIKey ? "Replace the saved key" : "Paste your API key",
                    text: $model.apiKeyDraft
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.saveAPIKey() }
                .accessibilityLabel("ElevenLabs API key")
                Button("Save") { model.saveAPIKey() }
                    .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let notice = model.apiKeyNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("You can also add or replace the key later in Settings → General.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grant the two permissions for the core flow")
                .font(.title3.weight(.semibold))
            Text("Nothing is requested until you click a button here — no surprise prompts. Microphone lets SpeakPaste record; Accessibility powers the global shortcut and pasting into other apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            onboardingPermissionRow(.microphone)
            onboardingPermissionRow(.accessibility)

            Text("Input Monitoring is an optional shortcut fallback. Keyboard Output is needed only in apps where the normal Paste menu cannot be used. Both, plus Open at Login, live in Settings → Permissions & Privacy.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func onboardingPermissionRow(_ permission: MacPermission) -> some View {
        let isGranted = model.permissions.granted[permission] ?? false
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isGranted ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.callout.weight(.medium))
                Text(permission.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isGranted {
                Button("Grant") { model.permissions.request(permission) }
                    .controlSize(.small)
                Button("Settings") { model.permissions.openSettings(for: permission) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick and test your microphone")
                .font(.title3.weight(.semibold))
            Text("SpeakPaste prefers your iPhone over Continuity and never silently falls back to a Mac microphone you didn't approve.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button {
                    model.refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(model.phase.isBusy || model.isMicrophoneConnected)
            }

            if model.devices.isEmpty {
                Text(model.deviceSelectionNotice
                    ?? "No microphones found. Connect one or bring your iPhone nearby, then refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if let notice = model.deviceSelectionNotice {
                    Label(notice, systemImage: "iphone.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 2) {
                    ForEach(model.devices) { device in
                        onboardingDeviceRow(device)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    microphoneTestDeviceID = model.selectedDeviceID
                    model.testSelectedMicrophone()
                } label: {
                    Label("Test (3 s)", systemImage: "waveform.badge.mic")
                }
                .disabled(
                    model.selectedDevice == nil
                        || model.phase.isBusy
                        || model.microphoneTestState.isRunning
                )
                .accessibilityHint("Records three seconds, plays it back, and reports the levels heard.")
                onboardingTestStatus
                Spacer()
            }
        }
    }

    private func onboardingDeviceRow(_ device: MacAudioInputDevice) -> some View {
        let isSelected = device.id == model.selectedDeviceID
        return Button {
            microphoneTestDeviceID = nil
            model.selectDevice(device.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.isContinuityDevice ? "iphone" : "laptopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(device.sourceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(device.isContinuityDevice ? Color.accentColor : .secondary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.phase.isBusy)
        .accessibilityLabel(
            "\(device.name), \(device.sourceLabel) microphone"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var onboardingTestStatus: some View {
        switch microphoneTestStateForSelectedDevice {
        case .idle:
            Text("Test this selected microphone before continuing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .listening:
            Text("Listening — speak now…")
                .font(.caption)
                .foregroundStyle(.red)
        case let .succeeded(summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var microphoneTestStateForSelectedDevice: MacMicrophoneTestState {
        guard microphoneTestDeviceID == model.selectedDeviceID else { return .idle }
        return model.microphoneTestState
    }

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The shortcuts")
                .font(.title3.weight(.semibold))
            Text("The bare right ⌘ tap is reserved for dictation. Ordinary shortcuts that use the left ⌘ key remain available.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                shortcutRow(model.hotKeyLabel, spokenKey: "Right Command key", purpose: "Start or stop a dictation")
                shortcutRow(model.switchInputHotKeyLabel, spokenKey: "Right Command key twice", purpose: "Switch between Mac and iPhone input — even mid-dictation")
                shortcutRow(model.cancelHotKeyLabel, spokenKey: "Escape key", purpose: "Cancel immediately — the recording is discarded, nothing is transcribed")
                shortcutRow(model.releaseHotKeyLabel, spokenKey: "Option Command V", purpose: "Paste held or recovered text at your cursor")
                shortcutRow(model.pasteLastHotKeyLabel, spokenKey: "Control Command V", purpose: "Paste the last transcript again")
                shortcutRow(model.copyLastHotKeyLabel, spokenKey: "Control Command C", purpose: "Copy the last transcript")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))

            Text("At delivery time, SpeakPaste uses the currently focused editor. If no writable editor is focused, the newest transcript is copied to the clipboard; use \(model.releaseHotKeyLabel) to place saved recovery text manually.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcutRow(_ key: String, spokenKey: String, purpose: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.callout.weight(.semibold))
                .monospaced()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.7)))
                .frame(minWidth: 84, alignment: .leading)
            Text(purpose)
                .font(.callout)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spokenKey): \(purpose)")
    }

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Language")
                .font(.title3.weight(.semibold))
            Text("Auto lets Scribe detect the language of each dictation. Pin one if you only ever dictate in it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Language", selection: $model.language) {
                Text(TranscriptionLanguage.automatic.title)
                    .tag(TranscriptionLanguage.automatic)
                Text(TranscriptionLanguage.english.title)
                    .tag(TranscriptionLanguage.english)
                Text(TranscriptionLanguage.spanish.title)
                    .tag(TranscriptionLanguage.spanish)
                Divider()
                ForEach(TranscriptionLanguage.allCases.filter {
                    $0 != .automatic && $0 != .english && $0 != .spanish
                }) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            Toggle("Clean up filler words and stumbles", isOn: $model.cleanSpeech)
                .toggleStyle(.checkbox)

            Text("Both can be changed any time in Settings → General.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(onboardingReady ? "You're set" : "Almost there")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                readyRow("ElevenLabs API key", ok: model.hasAPIKey)
                readyRow("Microphone selected", ok: model.selectedDevice != nil)
                readyRow("Microphone permission", ok: model.permissions.granted[.microphone] ?? false)
                readyRow("Accessibility permission", ok: model.permissions.granted[.accessibility] ?? false)
                readyRow("Keyboard Output fallback", ok: model.permissions.granted[.postEvents] ?? false)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))

            Text("Try it now: click into any text field, tap \(model.hotKeyLabel), speak a sentence, and tap \(model.hotKeyLabel) again. Double-tap at any point to switch between Mac and iPhone input.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !onboardingReady {
                Text("Anything unchecked above can be finished later from the main window or Settings — nothing here is locked.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.permissions.granted[.postEvents] != true {
                Text("Core dictation is ready. Grant Keyboard Output later only if an app cannot accept SpeakPaste through its normal Paste menu.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var onboardingReady: Bool {
        model.hasAPIKey
            && model.selectedDevice != nil
            && model.permissions.granted[.microphone] == true
            && model.permissions.granted[.accessibility] == true
    }

    private func readyRow(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout)
            Spacer()
            if !ok {
                Text("Later is fine")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(ok ? "done" : "not yet")")
    }
}
