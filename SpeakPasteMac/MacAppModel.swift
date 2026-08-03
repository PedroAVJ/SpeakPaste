import AppKit
import AVFoundation
import Combine
import Foundation

/// A finished transcript waiting for its destination to regain focus.
struct MacHeldTranscript: Identifiable {
    let id = UUID()
    let text: String
    let target: MacDeliveryTarget
    let createdAt: Date
}

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
    /// Set only by `selectDevice(_:)` or by `refreshDevices()` choosing a
    /// Continuity microphone. Never by an unrequested fallback.
    @Published private(set) var selectedDeviceID = ""
    /// Explains why no microphone is selected. Non-nil means SpeakPaste
    /// declined to guess rather than quietly dictating through the wrong mic.
    @Published private(set) var deviceSelectionNotice: String?
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
    /// Transcripts that finished while their destination was not focused. They
    /// are never dropped and never guessed at: each waits for its own field to
    /// come back, or for the release shortcut.
    @Published private(set) var heldTranscripts: [MacHeldTranscript] = []

    private let recorder: MacAudioRecorder
    private let client: ElevenLabsClientProtocol
    private let keychain: KeychainStore
    private let pasteController: MacPasteController
    private let reliabilityStore: MacReliabilityStore
    private let globalHotKey: MacGlobalHotKey
    private var meterTimer: Timer?
    private var recordingStartedAt: Date?
    private var deliveryTarget: MacDeliveryTarget?
    private var connectedDeviceID: String?
    private var pendingWatchTimer: Timer?

    private static let chosenDeviceKey = "mac-chosen-device-id"
    /// Earlier builds auto-persisted whatever microphone they fell back to, so
    /// a single iPhone-absent launch pinned the built-in mic permanently.
    private static let autoPersistedDeviceKey = "mac-selected-device-id"

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
        UserDefaults.standard.removeObject(forKey: Self.autoPersistedDeviceKey)
        refreshDevices()
        observeDeviceChanges()
        recorder.setRecordingFailureHandler { [weak self] error, salvagedAudioURL in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedRecordingFailure(error, salvagedAudioURL: salvagedAudioURL)
            }
        }
        globalHotKey.install(
            toggle: { [weak self] in self?.toggleRecording() },
            release: { [weak self] in self?.releaseHeldTranscripts() }
        )
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

    var hotKeyLabel: String { MacGlobalHotKey.toggleLabel }
    var releaseHotKeyLabel: String { MacGlobalHotKey.releaseLabel }

    /// Records the microphone the user picked in the UI. Only a deliberate
    /// choice is persisted, so an unavailable-iPhone moment can never write
    /// itself in as a lasting preference.
    func selectDevice(_ deviceID: String) {
        guard devices.contains(where: { $0.id == deviceID }) else { return }
        selectedDeviceID = deviceID
        deviceSelectionNotice = nil
        UserDefaults.standard.set(deviceID, forKey: Self.chosenDeviceKey)
    }

    func refreshDevices() {
        devices = MacAudioDeviceCatalog.availableInputs()
        // Re-resolving mid-dictation could swap the device out from under an
        // in-flight recording, so only the device list is refreshed there.
        guard !phase.isBusy, !isMicrophoneConnected else { return }
        resolveSelection()
    }

    private func resolveSelection() {
        let chosen = UserDefaults.standard.string(forKey: Self.chosenDeviceKey)

        if let chosen, devices.contains(where: { $0.id == chosen }) {
            selectedDeviceID = chosen
            deviceSelectionNotice = nil
            return
        }
        if let continuityDevice = devices.first(where: \.isContinuityDevice) {
            selectedDeviceID = continuityDevice.id
            deviceSelectionNotice = nil
            return
        }

        // No iPhone, and no microphone this user actually asked for. Silently
        // substituting a Mac microphone here is what made every dictation run
        // through the built-in mic while appearing to work, so leave the
        // choice unmade and say so.
        selectedDeviceID = ""
        if chosen != nil {
            deviceSelectionNotice = devices.isEmpty
                ? "The microphone you chose is no longer available, and no others were found."
                : "The microphone you chose is no longer available. Bring your iPhone nearby and refresh, or pick another microphone."
        } else {
            deviceSelectionNotice = devices.isEmpty
                ? "No microphones found. Connect one or bring your iPhone nearby, then refresh."
                : "No iPhone microphone is available. Bring your iPhone nearby and refresh, or pick a microphone below — SpeakPaste will not choose one for you."
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
            phase = .failed(
                deviceSelectionNotice
                    ?? "No microphone is selected. Open SpeakPaste and choose one."
            )
            return
        }
        guard hasAPIKey else {
            phase = .failed("Add your ElevenLabs API key before recording.")
            return
        }

        deliveryTarget = MacDeliveryTarget.captureCurrent()

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
            let target = deliveryTarget
            let delivery = await pasteController.deliver(
                result.text,
                to: target,
                autoPaste: autoPaste
            )
            var detail = delivery.detail
            if delivery == .held, let target {
                hold(result.text, for: target)
                detail = "Held for \(target.applicationName)"
            } else if let target {
                // Naming the destination and the route makes the attempt log
                // the record of which apps accept a precise insert and which
                // fall back to a keystroke.
                detail = "\(delivery.detail) → \(target.applicationName)"
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

    // MARK: Held transcripts

    private func hold(_ text: String, for target: MacDeliveryTarget) {
        heldTranscripts.append(
            MacHeldTranscript(text: text, target: target, createdAt: Date())
        )
        startPendingWatcher()
    }

    /// Polls for the destination regaining focus rather than installing an
    /// AXObserver. Observers behave inconsistently across toolkits — Electron
    /// especially — and a 0.4 s poll that only runs while something is held is
    /// both cheaper to reason about and uniform across every app.
    private func startPendingWatcher() {
        guard pendingWatchTimer == nil else { return }
        pendingWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.deliverHeldTranscriptsIfTargetFocused()
            }
        }
    }

    private func stopPendingWatcher() {
        pendingWatchTimer?.invalidate()
        pendingWatchTimer = nil
    }

    private func deliverHeldTranscriptsIfTargetFocused() {
        guard !heldTranscripts.isEmpty else {
            stopPendingWatcher()
            return
        }
        let ready = heldTranscripts.filter { $0.target.holdsFocus }
        guard !ready.isEmpty else { return }

        // Everything spoken for this field, in the order it was spoken, as one
        // insert. Two dictations while away should read as two sentences, not
        // arrive as a race.
        let text = ready.map(\.text).joined(separator: " ")
        guard let target = ready.first?.target else { return }

        let readyIdentifiers = Set(ready.map(\.id))
        var delivered = target.insertWithoutFocusing(text)
        if !delivered {
            // The captured field holds focus, so a plain paste lands in exactly
            // the right place even when the element refuses a direct write.
            guard pasteController.insertAtCurrentFocus(text) != .copiedNeedsAccessibility else { return }
            delivered = false
        }
        heldTranscripts.removeAll { readyIdentifiers.contains($0.id) }
        if heldTranscripts.isEmpty { stopPendingWatcher() }
        phase = .succeeded(delivered ? "Inserted where you left off" : "Pasted where you left off")
        scheduleReadyReset()
    }

    /// Drops everything held at the caret's current location, wherever that is.
    /// The user is explicitly asking for this destination, so no target match is
    /// required.
    func releaseHeldTranscripts() {
        guard !heldTranscripts.isEmpty else { return }
        let text = heldTranscripts.map(\.text).joined(separator: " ")
        let result = pasteController.insertAtCurrentFocus(text)
        guard result != .copiedNeedsAccessibility else {
            phase = .failed("Enable Accessibility for SpeakPaste to insert held text.")
            return
        }
        heldTranscripts.removeAll()
        stopPendingWatcher()
        phase = .succeeded(result == .inserted ? "Inserted here" : "Pasted here")
        scheduleReadyReset()
    }

    func discardHeldTranscripts() {
        heldTranscripts.removeAll()
        stopPendingWatcher()
    }

    func copyHeldTranscripts() {
        guard !heldTranscripts.isEmpty else { return }
        pasteController.copyToPasteboard(heldTranscripts.map(\.text).joined(separator: " "))
    }

    private func scheduleReadyReset() {
        let successPhase = phase
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.phase == successPhase else { return }
            self.phase = .ready
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
                    // The earlier refresh skipped selection while the mic was
                    // still marked connected; re-resolve now that it is not.
                    self.resolveSelection()
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
