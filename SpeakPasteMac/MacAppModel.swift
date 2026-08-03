import AppKit
import AVFoundation
import Combine
import Foundation

/// A transcription that finished and is waiting its turn to be delivered, so
/// that dictations land in the order they were spoken.
private struct MacFinishedDictation {
    let text: String
    let target: MacDeliveryTarget?
    let deviceName: String
    let recordingDuration: TimeInterval
    let transcriptionDuration: TimeInterval
    let interruption: String?
}

/// A finished transcript waiting for its destination to regain focus.
struct MacHeldTranscript: Identifiable {
    let id = UUID()
    let text: String
    let target: MacDeliveryTarget
    let createdAt: Date
}

/// The microphone's state only. Transcription deliberately lives outside this
/// machine: a dictation that has been spoken no longer needs the microphone, so
/// waiting for its text must never block the next one.
enum MacCapturePhase: Equatable {
    case ready
    case connecting
    case recording
    case finalizing
    case succeeded(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .recording, .finalizing: true
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
    /// Dictations that have been spoken and are still being transcribed. The
    /// microphone is already free; these only await text.
    @Published private(set) var inFlightCount = 0

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
    /// Dictations deliver in the order they were spoken even when a later,
    /// shorter one finishes transcribing first. `nextDeliverySequence` is the
    /// ticket now being served; results that arrive early wait in `completed`.
    private var nextSpeakSequence = 0
    private var nextDeliverySequence = 0
    private var completedDictations: [Int: MacFinishedDictation] = [:]

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
        case .connecting, .finalizing:
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

        // The microphone is released and the audio is on disk, so this dictation
        // no longer needs anything the next one wants. Hand it to a background
        // job and return to ready immediately: the user can start speaking again
        // right now instead of watching a spinner.
        phase = .ready
        let target = deliveryTarget
        deliveryTarget = nil
        startTranscription(
            audioURL: segment.url,
            target: target,
            deviceName: deviceName,
            recordingDuration: recordingDuration,
            interruption: nil
        )
    }

    private func startTranscription(
        audioURL: URL,
        target: MacDeliveryTarget?,
        deviceName: String,
        recordingDuration: TimeInterval,
        interruption: String?
    ) {
        let sequence = nextSpeakSequence
        nextSpeakSequence += 1
        inFlightCount += 1
        Task { [weak self] in
            await self?.transcribe(
                sequence: sequence,
                audioURL: audioURL,
                target: target,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                interruption: interruption
            )
        }
    }

    /// Transcribes one dictation. Several of these can be in flight at once;
    /// each takes a ticket so delivery still happens in spoken order. When
    /// `interruption` is set, the audio is a partial dictation salvaged from a
    /// stream that died mid-recording; the attempt is logged as a failure but
    /// the text the user already spoke is still delivered.
    private func transcribe(
        sequence: Int,
        audioURL: URL,
        target: MacDeliveryTarget?,
        deviceName: String,
        recordingDuration: TimeInterval,
        interruption: String?
    ) async {
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            inFlightCount = max(0, inFlightCount - 1)
        }
        do {
            guard let apiKey = resolvedAPIKey else {
                throw ElevenLabsClientError.api(statusCode: 401, message: "ElevenLabs API key is missing.")
            }

            let transcriptionStartedAt = Date()
            let result = try await client.transcribe(
                audioURL: audioURL,
                apiKey: apiKey,
                language: language,
                cleanSpeech: cleanSpeech
            )
            completedDictations[sequence] = MacFinishedDictation(
                text: result.text,
                target: target,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: Date().timeIntervalSince(transcriptionStartedAt),
                interruption: interruption
            )
            await drainCompletedDictations()
        } catch {
            // A failed dictation must not stall the ones spoken after it.
            completedDictations[sequence] = MacFinishedDictation(
                text: "",
                target: target,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: 0,
                interruption: diagnosticMessage(for: error)
            )
            await drainCompletedDictations()
        }
    }

    /// Delivers finished dictations strictly in spoken order, so a short second
    /// thought cannot overtake the sentence it belongs after.
    private func drainCompletedDictations() async {
        while let finished = completedDictations[nextDeliverySequence] {
            completedDictations[nextDeliverySequence] = nil
            nextDeliverySequence += 1
            await deliver(finished)
        }
    }

    private func deliver(_ finished: MacFinishedDictation) async {
        guard !finished.text.isEmpty else {
            recordFailure(
                finished.interruption ?? "Transcription failed.",
                deviceName: finished.deviceName,
                recordingDuration: finished.recordingDuration,
                transcriptionDuration: 0
            )
            return
        }

        transcript = finished.text
        let delivery = await pasteController.deliver(
            finished.text,
            to: finished.target,
            autoPaste: autoPaste
        )
        var detail = delivery.detail
        if delivery == .held, let target = finished.target {
            hold(finished.text, for: target)
            detail = "Held for \(target.applicationName)"
        } else if let target = finished.target {
            // Naming the destination and the route makes the attempt log the
            // record of where each dictation actually went.
            detail = "\(delivery.detail) → \(target.applicationName)"
        }

        if let interruption = finished.interruption {
            attempts = reliabilityStore.prepend(
                MacReliabilityAttempt(
                    deviceName: finished.deviceName,
                    recordingDuration: finished.recordingDuration,
                    transcriptionDuration: finished.transcriptionDuration,
                    outcome: .failure,
                    detail: "Stream dropped mid-dictation; partial audio recovered. \(detail). \(interruption)"
                )
            )
            phase = .failed("Recording stopped early — the dictation captured so far was still transcribed. \(detail).")
            return
        }

        attempts = reliabilityStore.prepend(
            MacReliabilityAttempt(
                deviceName: finished.deviceName,
                recordingDuration: finished.recordingDuration,
                transcriptionDuration: finished.transcriptionDuration,
                outcome: .success,
                detail: detail
            )
        )
        // Never overwrite a live recording's state with a background job's
        // result. The microphone owns the HUD while it is running.
        guard !phase.isBusy else { return }
        phase = .succeeded(detail)
        scheduleReadyReset()
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
        let ready = heldTranscripts.filter { $0.target.canDeliverOnReturn }
        guard !ready.isEmpty else { return }

        // Everything spoken for this field, in the order it was spoken, as one
        // insert. Two dictations while away should read as two sentences, not
        // arrive as a race.
        let text = ready.map(\.text).joined(separator: " ")
        guard let target = ready.first?.target else { return }

        let readyIdentifiers = Set(ready.map(\.id))
        guard pasteController.pasteAtCurrentFocus(text) != .copiedNeedsAccessibility else { return }
        heldTranscripts.removeAll { readyIdentifiers.contains($0.id) }
        if heldTranscripts.isEmpty { stopPendingWatcher() }
        phase = .succeeded("Pasted where you left off")
        scheduleReadyReset()
    }

    /// Drops everything held at the caret's current location, wherever that is.
    /// The user is explicitly asking for this destination, so no target match is
    /// required.
    func releaseHeldTranscripts() {
        guard !heldTranscripts.isEmpty else { return }
        let text = heldTranscripts.map(\.text).joined(separator: " ")
        let result = pasteController.pasteAtCurrentFocus(text)
        guard result != .copiedNeedsAccessibility else {
            phase = .failed("Enable Accessibility for SpeakPaste to insert held text.")
            return
        }
        heldTranscripts.removeAll()
        stopPendingWatcher()
        phase = .succeeded("Pasted here")
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
        let target = deliveryTarget
        deliveryTarget = nil
        phase = .ready
        startTranscription(
            audioURL: salvagedAudioURL,
            target: target,
            deviceName: deviceName,
            recordingDuration: recordingDuration,
            interruption: interruption
        )
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
