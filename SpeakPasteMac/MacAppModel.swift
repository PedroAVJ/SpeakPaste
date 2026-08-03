import AppKit
import AVFoundation
import Combine
import Foundation

enum MacCapturePhase: Equatable {
    case ready
    case connecting
    case recording
    case finalizing
    case transcribing
    case succeeded(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .recording, .finalizing, .transcribing: true
        case .ready, .succeeded, .failed: false
        }
    }
}

@MainActor
final class MacAppModel: ObservableObject {
    @Published private(set) var phase: MacCapturePhase = .ready {
        didSet {
            guard phase != oldValue else { return }
            phaseStartedAt = Date()
        }
    }
    @Published private(set) var phaseStartedAt = Date()
    @Published private(set) var devices: [MacAudioInputDevice] = []
    @Published var selectedDeviceID = "" {
        didSet {
            guard !selectedDeviceID.isEmpty else { return }
            UserDefaults.standard.set(selectedDeviceID, forKey: "mac-selected-device-id")
        }
    }
    @Published var language: TranscriptionLanguage = .automatic
    @Published var cleanSpeech = true
    @Published var autoPaste = true
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var inputLevel: Double = 0
    @Published var transcript = ""
    @Published private(set) var attempts: [MacReliabilityAttempt] = []
    @Published var apiKeyDraft = ""
    @Published private(set) var hasSavedAPIKey = false
    @Published private(set) var isMicrophoneConnected = false
    @Published private(set) var connectionLatency: TimeInterval?

    private let recorder: MacAudioRecorder
    private let client: ElevenLabsClientProtocol
    private let keychain: KeychainStore
    private let pasteController: MacPasteController
    private let reliabilityStore: MacReliabilityStore
    private let globalHotKey: MacGlobalHotKey
    private var meterTimer: Timer?
    private var recordingStartedAt: Date?
    private var destinationProcessIdentifier: pid_t?
    private var connectedDeviceID: String?

    init(
        recorder: MacAudioRecorder = MacAudioRecorder(),
        client: ElevenLabsClientProtocol = ElevenLabsClient(),
        keychain: KeychainStore = KeychainStore(),
        pasteController: MacPasteController = MacPasteController(),
        reliabilityStore: MacReliabilityStore = MacReliabilityStore(),
        globalHotKey: MacGlobalHotKey = MacGlobalHotKey()
    ) {
        self.recorder = recorder
        self.client = client
        self.keychain = keychain
        self.pasteController = pasteController
        self.reliabilityStore = reliabilityStore
        self.globalHotKey = globalHotKey
        attempts = reliabilityStore.load()
        hasSavedAPIKey = keychain.load()?.isEmpty == false
        refreshDevices()
        observeDeviceChanges()
        recorder.setRecordingFailureHandler { [weak self] error, salvagedAudioURL in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedRecordingFailure(error, salvagedAudioURL: salvagedAudioURL)
            }
        }
        globalHotKey.install { [weak self] in
            self?.toggleRecording()
        }
    }

    var selectedDevice: MacAudioInputDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var successRate: Double? {
        guard !attempts.isEmpty else { return nil }
        let successes = attempts.filter { $0.outcome == .success }.count
        return Double(successes) / Double(attempts.count)
    }

    var hasAPIKey: Bool {
        hasSavedAPIKey || environmentAPIKey?.isEmpty == false
    }

    var hotKeyLabel: String { "⌘" }

    func refreshDevices() {
        let previous = selectedDeviceID.isEmpty
            ? UserDefaults.standard.string(forKey: "mac-selected-device-id")
            : selectedDeviceID
        devices = MacAudioDeviceCatalog.availableInputs()

        if let previous, devices.contains(where: { $0.id == previous }) {
            selectedDeviceID = previous
        } else if let continuityDevice = devices.first(where: \.isContinuityDevice) {
            selectedDeviceID = continuityDevice.id
        } else {
            selectedDeviceID = devices.first?.id ?? ""
        }
    }

    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.save(trimmed)
            apiKeyDraft = ""
            hasSavedAPIKey = true
            if case .failed = phase { phase = .ready }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func deleteAPIKey() {
        keychain.delete()
        hasSavedAPIKey = false
    }

    func toggleRecording() {
        switch phase {
        case .recording:
            stopMeter()
            phase = .finalizing
            Task { await stopAndTranscribe() }
        case .ready, .succeeded, .failed:
            phase = .connecting
            Task { await startRecording() }
        case .connecting, .finalizing, .transcribing:
            break
        }
    }

    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    func clearTranscript() {
        transcript = ""
    }

    func clearFailure() {
        if case .failed = phase { phase = .ready }
    }

    private func startRecording() async {
        guard let device = selectedDevice else {
            phase = .failed("No microphone is available.")
            return
        }
        guard hasAPIKey else {
            phase = .failed("Add your ElevenLabs API key before recording.")
            return
        }

        destinationProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if destinationProcessIdentifier == ProcessInfo.processInfo.processIdentifier {
            destinationProcessIdentifier = nil
        }

        do {
            let connectionStartedAt = Date()
            let createdConnection = try await recorder.connect(deviceID: device.id)
            if createdConnection {
                connectionLatency = Date().timeIntervalSince(connectionStartedAt)
            }
            isMicrophoneConnected = true
            connectedDeviceID = device.id
            _ = try await recorder.startSegment()
            recordingStartedAt = Date()
            elapsed = 0
            inputLevel = 0
            phase = .recording
            startMeter()
        } catch {
            isMicrophoneConnected = false
            connectedDeviceID = nil
            connectionLatency = nil
            recordFailure(diagnosticMessage(for: error), deviceName: device.name, recordingDuration: 0, transcriptionDuration: 0)
        }
    }

    private func stopAndTranscribe() async {
        let deviceName = selectedDevice?.name ?? "Unknown microphone"
        let recordingDuration = Date().timeIntervalSince(recordingStartedAt ?? Date())

        let segment: MacRecordedSegment
        do {
            segment = try await recorder.stop()
        } catch {
            isMicrophoneConnected = false
            connectedDeviceID = nil
            connectionLatency = nil
            recordFailure(
                diagnosticMessage(for: error),
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: 0
            )
            return
        }
        isMicrophoneConnected = false
        connectedDeviceID = nil
        connectionLatency = nil
        await transcribeAndDeliver(
            audioURL: segment.url,
            deviceName: deviceName,
            recordingDuration: recordingDuration,
            interruption: nil
        )
    }

    /// Transcribes a finished recording and delivers the text. When
    /// `interruption` is set, the audio is a partial dictation salvaged from a
    /// stream that died mid-recording; the attempt is logged as a failure but
    /// the text the user already spoke is still delivered.
    private func transcribeAndDeliver(
        audioURL: URL,
        deviceName: String,
        recordingDuration: TimeInterval,
        interruption: String?
    ) async {
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            guard let apiKey = resolvedAPIKey else {
                throw ElevenLabsClientError.api(statusCode: 401, message: "ElevenLabs API key is missing.")
            }

            phase = .transcribing
            let transcriptionStartedAt = Date()
            let result = try await client.transcribe(
                audioURL: audioURL,
                apiKey: apiKey,
                language: language,
                cleanSpeech: cleanSpeech
            )
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStartedAt)
            transcript = result.text
            let delivery = await pasteController.deliver(
                result.text,
                pasteInto: destinationProcessIdentifier,
                autoPaste: autoPaste
            )
            let detail: String
            switch delivery {
            case .pasted: detail = "Transcribed and pasted"
            case .copied: detail = "Transcribed and copied"
            case .copiedNeedsAccessibility: detail = "Copied; enable Accessibility for automatic paste"
            }
            if let interruption {
                attempts = reliabilityStore.prepend(
                    MacReliabilityAttempt(
                        deviceName: deviceName,
                        recordingDuration: recordingDuration,
                        transcriptionDuration: transcriptionDuration,
                        outcome: .failure,
                        detail: "Stream dropped mid-dictation; partial audio recovered. \(detail). \(interruption)"
                    )
                )
                phase = .failed("Recording stopped early — the dictation captured so far was still transcribed. \(detail).")
                return
            }
            attempts = reliabilityStore.prepend(
                MacReliabilityAttempt(
                    deviceName: deviceName,
                    recordingDuration: recordingDuration,
                    transcriptionDuration: transcriptionDuration,
                    outcome: .success,
                    detail: detail
                )
            )
            let successPhase = MacCapturePhase.succeeded(detail)
            phase = successPhase
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.phase == successPhase else { return }
                self.phase = .ready
            }
        } catch {
            recordFailure(
                diagnosticMessage(for: error),
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: 0
            )
        }
    }

    private func recordFailure(
        _ message: String,
        deviceName: String,
        recordingDuration: TimeInterval,
        transcriptionDuration: TimeInterval
    ) {
        stopMeter()
        attempts = reliabilityStore.prepend(
            MacReliabilityAttempt(
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: transcriptionDuration,
                outcome: .failure,
                detail: message
            )
        )
        phase = .failed(message)
    }

    private func handleUnexpectedRecordingFailure(_ error: Error, salvagedAudioURL: URL?) {
        // Once Command has moved the phase to finalizing, stopAndTranscribe
        // owns this same failure. This callback handles failures while the UI
        // would otherwise continue to claim that it is safe to speak.
        guard phase == .recording else {
            if let salvagedAudioURL {
                try? FileManager.default.removeItem(at: salvagedAudioURL)
            }
            return
        }
        let deviceName = selectedDevice?.name ?? "Unknown microphone"
        let recordingDuration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        stopMeter()
        isMicrophoneConnected = false
        connectedDeviceID = nil
        connectionLatency = nil
        guard let salvagedAudioURL else {
            recordFailure(
                diagnosticMessage(for: error),
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: 0
            )
            return
        }
        // AVFoundation finalized the file before the stream died, so the words
        // already spoken are recoverable instead of lost.
        let interruption = diagnosticMessage(for: error)
        phase = .transcribing
        Task {
            await transcribeAndDeliver(
                audioURL: salvagedAudioURL,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                interruption: interruption
            )
        }
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.recordingStartedAt ?? Date())
                self.inputLevel = self.recorder.normalizedLevel
            }
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        inputLevel = 0
    }

    private func observeDeviceChanges() {
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDevices() }
        }
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDevices()
                if
                    let connectedDeviceID = self.connectedDeviceID,
                    !self.devices.contains(where: { $0.id == connectedDeviceID })
                {
                    let wasRecording = self.phase == .recording
                    let deviceName = self.selectedDevice?.name ?? "Selected microphone"
                    let recordingDuration = Date().timeIntervalSince(self.recordingStartedAt ?? Date())
                    self.recorder.disconnect()
                    self.isMicrophoneConnected = false
                    self.connectedDeviceID = nil
                    self.connectionLatency = nil
                    if wasRecording {
                        self.recordFailure(
                            "The microphone disconnected while recording.",
                            deviceName: deviceName,
                            recordingDuration: recordingDuration,
                            transcriptionDuration: 0
                        )
                    }
                }
            }
        }
    }

    private func diagnosticMessage(for error: Error) -> String {
        let nsError = error as NSError
        let description = error.localizedDescription
        guard nsError.domain != NSCocoaErrorDomain else { return description }
        if nsError.domain == AVFoundationErrorDomain, let hint = continuityHint(for: nsError.code) {
            return "\(hint) [\(nsError.domain) \(nsError.code)]"
        }
        return "\(description) [\(nsError.domain) \(nsError.code)]"
    }

    /// AVFoundation's localized descriptions for capture failures ("Recording
    /// Stopped") hide what actually happened. Translate the Continuity-mic
    /// failures seen in practice into actionable language.
    private func continuityHint(for code: Int) -> String? {
        switch code {
        case AVError.Code.mediaDiscontinuity.rawValue:
            "The iPhone paused its microphone stream."
        case AVError.Code.noDataCaptured.rawValue:
            "The microphone connected but sent no audio."
        case AVError.Code.deviceWasDisconnected.rawValue, AVError.Code.deviceNotConnected.rawValue:
            "The microphone disconnected."
        default:
            nil
        }
    }

    private var environmentAPIKey: String? {
        ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
    }

    private var resolvedAPIKey: String? {
        let saved = keychain.load()
        if let saved, !saved.isEmpty { return saved }
        return environmentAPIKey
    }
}
