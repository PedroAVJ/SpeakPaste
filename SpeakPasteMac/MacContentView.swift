import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var model: MacAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.heldTranscripts.isEmpty {
                        heldBanner
                    }
                    if !model.retryableFailures.isEmpty {
                        retryBanner
                    }
                    microphoneSection
                    captureSection
                    if case let .failed(message) = model.phase {
                        failureBanner(message)
                    }
                    if !model.hasAPIKey {
                        apiKeySection
                    }
                    transcriptSection
                    settingsSection
                    reliabilitySection
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.isMicrophoneConnected)
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
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .connecting: .yellow
        case .recording: .red
        case .finalizing: .orange
        case .succeeded: .green
        case .failed: .orange
        case .ready: model.hasAPIKey && model.selectedDevice != nil ? .green : .orange
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
            return "Ready"
        }
    }

    // MARK: Held transcripts

    private var heldBanner: some View {
        let count = model.heldTranscripts.count
        let destination = model.heldTranscripts.first?.target.applicationName ?? "the previous app"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 transcript is waiting" : "\(count) transcripts are waiting")
                        .font(.callout.weight(.medium))
                    Text("Nothing is lost. Click back into \(destination) and it drops in by itself, or press \(model.releaseHotKeyLabel) to put it wherever your cursor is.")
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
                Button("Copy") { model.copyHeldTranscripts() }
                    .controlSize(.small)
                Button("Discard") { model.discardHeldTranscripts() }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.blue.opacity(0.3)))
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
                    Text("The audio is still here. \(model.retryableFailures.first?.reason ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Try Again") { model.retryAllFailures() }
                    .controlSize(.small)
                Button("Discard") {
                    for failure in model.retryableFailures { model.discardFailure(failure) }
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.3)))
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("MICROPHONE")
                Spacer()
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

                Text(deviceStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    Text(isContinuity ? "iPhone microphone active" : "\(device?.name ?? "Microphone") active")
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
        return Button {
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

                Text(device.isContinuityDevice ? "iPhone" : "Mac")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(device.isContinuityDevice ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.5)))

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
            "\(device.name), \(device.isContinuityDevice ? "iPhone microphone" : "Mac microphone")"
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
        return device.isContinuityDevice
            ? "Using your iPhone's microphone over Continuity."
            : "Using a microphone on this Mac — not your iPhone."
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

            InputLevelMeter(level: model.inputLevel, isActive: model.phase == .recording)

            if model.phase == .recording || model.phase == .connecting {
                Button("Cancel", role: .destructive) { model.cancelRecording() }
                    .controlSize(.small)
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
                || model.selectedDevice == nil
        )
        .opacity(model.selectedDevice == nil ? 0.4 : 1)
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
        switch model.phase {
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

    private var elapsedAccessibilityLabel: String {
        model.phase == .recording
            ? "Recording, \(timeString(model.elapsed)) elapsed"
            : "Elapsed time \(timeString(model.elapsed))"
    }

    private var captureHint: String {
        switch model.phase {
        case .connecting:
            model.selectedDevice?.isContinuityDevice == true
                ? "WAIT — do not speak yet. Connecting to your iPhone can take several seconds."
                : "WAIT — do not speak yet. Connecting to the microphone."
        case .recording: "SPEAK NOW — press \(model.hotKeyLabel) to stop and transcribe."
        case .finalizing: "RECORDING STOPPED — releasing the iPhone microphone…"
        case .succeeded: "DONE — transcript delivered."
        case .ready, .failed:
            model.inFlightCount > 0
                ? "MIC IS FREE — \(model.inFlightCount) transcribing. Start the next one whenever you want."
                : "Click record or press \(model.hotKeyLabel) from any app."
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
        .accessibilityElement(children: .combine)
    }

    // MARK: API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ELEVENLABS API KEY")
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
            Text("Required for transcription. Stored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("LAST TRANSCRIPT")
                Spacer()
                Button {
                    model.copyTranscript()
                    flashCopied()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(model.transcript.isEmpty)
                .accessibilityHint("Puts the transcript on the clipboard.")

                Button {
                    model.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(model.transcript.isEmpty)
                .accessibilityHint("Empties the transcript field.")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.transcript)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(height: 88)
                    .accessibilityLabel("Transcript")
                    .accessibilityHint("Editable. Shows the exact ElevenLabs result.")

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

            Text("Editable — the exact ElevenLabs result lands here after each recording.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("SETTINGS")

            HStack(spacing: 12) {
                Text("Language")
                    .font(.callout)
                Picker("Language", selection: $model.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer()
            }

            Toggle("Clean up filler words and stumbles", isOn: $model.cleanSpeech)
                .font(.callout)
            Toggle("Paste into the app you were using", isOn: $model.autoPaste)
                .font(.callout)

            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global shortcut: Tap \(model.hotKeyLabel) by itself to start and stop recording from any app. The left ⌘ is left alone so ⌘C, ⌘V, and ⌘Tab are never affected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Press \(model.releaseHotKeyLabel) to drop a held transcript wherever your cursor is.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: Reliability log

    private var reliabilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("RECENT ATTEMPTS")
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }

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
