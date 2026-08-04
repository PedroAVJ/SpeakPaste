import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import Network

/// A transcription that finished and is waiting its turn to be delivered, so
/// that dictations land in the order they were spoken.
private struct MacFinishedDictation {
    let text: String
    /// Set only after the exact text below has been atomically committed to
    /// retained transcript history.
    let historyRecordID: UUID?
    /// Temporary pending-delivery ownership. Never Store removes History only
    /// after this is durable; ordinary retention also uses it to protect old
    /// retries and every external side-effect boundary.
    let deliveryEscrowID: UUID?
    /// Capture/import time, not the later instant when the network finished.
    let createdAt: Date
    let target: MacDeliveryTarget?
    let deviceName: String
    let recordingDuration: TimeInterval
    let transcriptionDuration: TimeInterval
    let interruption: String?
    /// Scribe reports this only for automatic language detection. A low score
    /// does not make the text disposable, but it should not pass silently in a
    /// quality-first product either.
    let languageConfidenceNotice: String?
}

/// A finalized segment whose first recovery-journal attempt failed. Retaining
/// the exact URL and stable journal ID lets a later normal Quit retry instead
/// of trapping the app forever or forcing the user to lose speech.
private struct MacTerminationRecording {
    let id: UUID
    let audioURL: URL
    let deviceName: String
    let recordingDuration: TimeInterval
}

private enum MacImportedAudioError: Error, Sendable {
    case fileTooLarge
}

/// A dictation whose transcription failed, with its audio kept so the user can
/// try again. Deleting the recording on any failure meant a rate limit, an
/// expired key, or a dropped connection destroyed speech that was perfectly
/// good.
struct MacRetryableDictation: Identifiable {
    let id: UUID
    let audioURL: URL
    let target: MacDeliveryTarget?
    /// AX targets cannot survive a relaunch. A retry reconstructed from the
    /// durable journal must therefore finish in the held/manual lane instead
    /// of treating `target == nil` as permission to overwrite the clipboard.
    let requiresManualOutput: Bool
    /// True only for a concrete connectivity failure. Authentication, service,
    /// content, and unknown transport errors always remain user-driven.
    let retriesOnReconnect: Bool
    /// Preserves the fact that this audio is a salvaged prefix rather than a
    /// complete recording, including through a relaunch.
    let interruptionReason: String?
    let deviceName: String
    let recordingDuration: TimeInterval
    let reason: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        audioURL: URL,
        target: MacDeliveryTarget?,
        requiresManualOutput: Bool = false,
        retriesOnReconnect: Bool = false,
        interruptionReason: String? = nil,
        deviceName: String,
        recordingDuration: TimeInterval,
        reason: String,
        createdAt: Date
    ) {
        self.id = id
        self.audioURL = audioURL
        self.target = target
        self.requiresManualOutput = requiresManualOutput
        self.retriesOnReconnect = retriesOnReconnect
        self.interruptionReason = interruptionReason
        self.deviceName = deviceName
        self.recordingDuration = recordingDuration
        self.reason = reason
        self.createdAt = createdAt
    }
}

private struct MacStoredRetryableDictation: Codable {
    let id: UUID
    let audioPath: String
    let deviceName: String
    let recordingDuration: TimeInterval
    let reason: String
    let createdAt: Date
}

/// A finished transcript waiting for its destination to regain focus.
struct MacHeldTranscript: Identifiable {
    let id: UUID
    let text: String
    /// Nil after a relaunch. AX handles cannot be reconstructed safely, so a
    /// recovered transcript is manual-release only.
    let target: MacDeliveryTarget?
    let destinationApplicationName: String
    let destinationBundleIdentifier: String?
    let createdAt: Date
    var deliveryState: MacPendingTranscriptDeliveryState

    var isRecovered: Bool { target == nil }
    var deliveryIsUncertain: Bool { deliveryState == .deliveryUncertain }
}

enum MacMicrophoneTestState: Equatable {
    case idle
    case connecting
    case listening
    case succeeded(String)
    case failed(String)

    var isRunning: Bool {
        self == .connecting || self == .listening
    }
}

enum MacHUDPlacement: String, CaseIterable, Identifiable {
    case top
    case bottom
    case left
    case right

    var id: String { rawValue }
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
            announceCapturePhase(phase)
        }
    }
    @Published private(set) var phaseStartedAt = Date()
    @Published private(set) var devices: [MacAudioInputDevice] = []
    /// Semantic source selected by the Command double-tap. Unlike a hardware
    /// UID, this survives the iPhone disappearing between launches and forbids
    /// a silent cross-mode fallback.
    @Published private(set) var inputMode: MacInputMode? = nil
    /// Set only by `selectDevice(_:)` or by `refreshDevices()` choosing a
    /// Continuity microphone. Never by an unrequested fallback.
    @Published private(set) var selectedDeviceID = ""
    /// Explicitly approved microphones, in fallback order. SpeakPaste may use
    /// the first one that is currently available; it never inserts an
    /// unapproved Mac microphone into this chain on its own.
    @Published private(set) var preferredDeviceIDs: [String] = []
    /// Explains why no microphone is selected. Non-nil means SpeakPaste
    /// declined to guess rather than quietly dictating through the wrong mic.
    @Published private(set) var deviceSelectionNotice: String?
    @Published var language: TranscriptionLanguage = .automatic {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }
    @Published var cleanSpeech = true {
        didSet { UserDefaults.standard.set(cleanSpeech, forKey: Self.cleanSpeechKey) }
    }
    @Published var autoPaste = true {
        didSet { UserDefaults.standard.set(autoPaste, forKey: Self.autoPasteKey) }
    }
    /// Off until the user opts in: context terms are sent to ElevenLabs as
    /// recognition hints, so this cannot be an undisclosed first-run default.
    @Published var contextAwareness = false {
        didSet { UserDefaults.standard.set(contextAwareness, forKey: Self.contextAwarenessKey) }
    }
    @Published var spokenFormattingCommands = true {
        didSet {
            UserDefaults.standard.set(spokenFormattingCommands, forKey: Self.spokenFormattingCommandsKey)
        }
    }
    @Published var hudEnabled = true {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: Self.hudEnabledKey) }
    }
    @Published var hudPlacement: MacHUDPlacement = .top {
        didSet { UserDefaults.standard.set(hudPlacement.rawValue, forKey: Self.hudPlacementKey) }
    }
    @Published var showInDock = true {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: Self.showInDockKey)
            applyActivationPolicy()
        }
    }
    @Published private(set) var hasCompletedOnboarding = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var recordingWarning: String?
    @Published private(set) var microphoneTestState: MacMicrophoneTestState = .idle
    @Published private(set) var capturedContextTermCount = 0
    @Published var transcript = ""
    @Published private(set) var originalTranscript = ""
    @Published private(set) var transcriptLearningNotice: String?
    @Published private(set) var fileImportNotice: String?
    @Published private(set) var previousSessionRecoveryNotice: String?
    @Published private(set) var diagnosticsExportNotice: String?
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var historyActionError: String?
    /// Successful recordings are kept locally so History can replay and
    /// reprocess them. Never-store History overrides this preference.
    @Published var retainSuccessfulAudio = true {
        didSet {
            guard retainSuccessfulAudio != oldValue else { return }
            successfulAudioRetentionGeneration &+= 1
            UserDefaults.standard.set(
                retainSuccessfulAudio,
                forKey: Self.retainSuccessfulAudioKey
            )
            historyActionError = nil
            if !retainSuccessfulAudio { removeAllRetainedHistoryAudio() }
        }
    }
    @Published private(set) var reprocessingHistoryRecordIDs = Set<UUID>()
    @Published private(set) var playingHistoryRecordID: UUID?
    @Published private(set) var attempts: [MacReliabilityAttempt] = []
    @Published var apiKeyDraft = ""
    @Published private(set) var hasSavedAPIKey = false
    @Published private(set) var apiKeyNotice: String?
    @Published private(set) var isMicrophoneConnected = false
    @Published private(set) var connectionLatency: TimeInterval?
    /// Transcripts that finished while their destination was not focused. They
    /// are never dropped and never guessed at: each waits for its own field to
    /// come back, or for the release shortcut.
    @Published private(set) var heldTranscripts: [MacHeldTranscript] = []
    /// Exact queue snapshot authorized by the dashboard's duplicate-risk
    /// confirmation. The actual paste must happen later, while an external
    /// destination owns focus, through the global release shortcut/menu item.
    private var armedUncertainPasteIDs = Set<UUID>()
    /// Dictations that have been spoken and are still being transcribed. The
    /// microphone is already free; these only await text.
    @Published private(set) var inFlightCount = 0
    /// Failed dictations whose audio is still on disk and can be resent.
    @Published private(set) var retryableFailures: [MacRetryableDictation] = []
    @Published private(set) var networkIsAvailable = true

    private let recorder: MacAudioRecorder
    private let client: ElevenLabsClientProtocol
    private let keychain: KeychainStore
    private let pasteController: MacPasteController
    private let reliabilityStore: MacReliabilityStore
    private let globalHotKey: MacGlobalHotKey
    private let sessionHealthMarker: MacSessionHealthMarker
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(
        label: "com.speakpaste.network-monitor",
        qos: .utility
    )
    let vocabulary = MacVocabularyStore()
    let replacements = MacReplacementStore()
    let history = MacHistoryStore()
    let sounds = MacSoundEffects()
    let permissions = MacPermissionsModel()
    let deliveryPolicies = MacDeliveryPolicyStore()
    private let pendingTranscriptStore = MacPendingTranscriptStore()
    private let pendingAudioStore = MacPendingAudioStore()
    private let historyAudioStore = MacHistoryAudioStore()
    private var meterTimer: Timer?
    /// Long hands-free dictations must count as active work even when the user
    /// does not touch the keyboard or trackpad. The assertion covers only the
    /// live microphone window and is balanced across every exit path.
    private var recordingActivity: NSObjectProtocol?
    private var recordingStartedAt: Date?
    private var lastDeliveredSampleCount: UInt64 = 0
    private var lastDeliveredSampleAt = Date()
    private var lastAudibleSampleAt = Date()
    private var automaticStopInProgress = false
    private var microphoneTestSound: NSSound?
    private var microphoneTestTask: Task<Void, Never>?
    private var historyPlaybackSound: NSSound?
    private var historyPlaybackResetTask: Task<Void, Never>?
    private var historyReprocessTasks: [UUID: Task<Void, Never>] = [:]
    /// An import is not crash-safe until its security-scoped source has been
    /// copied and synchronously staged in PendingAudio. Normal Quit waits for
    /// these short-lived staging tasks; network transcription is already
    /// journaled and does not need to hold termination open.
    private var fileImportTasks: [UUID: Task<Void, Never>] = [:]
    /// Only connectivity-caused failures are retried without another click.
    /// Authentication, validation, and no-speech failures stay explicit even
    /// if they happen to coexist with a network transition.
    private var reconnectRetryIDs = Set<UUID>()
    /// Counts only initial/changed path states, not every callback. A request
    /// remembers the generation at which it began so a reconnect that races
    /// ahead of its eventual error still produces exactly one wakeup.
    private var networkPathGeneration: UInt64 = 0
    private var hasReceivedNetworkPath = false
    /// Invalidates a detached successful-audio copy across an intervening
    /// privacy toggle, including a quick off/on or Never-store/restore cycle.
    private var successfulAudioRetentionGeneration: UInt64 = 0
    private var deliveryTarget: MacDeliveryTarget?
    /// Generation guard for the asynchronous Continuity connection. Escape can
    /// arrive while `connect` is still waiting for steady audio; a stale task
    /// must never turn the app back to Recording (or overwrite a newer start).
    private var captureRequestID: UUID?
    private var captureStartTask: Task<Void, Never>?
    /// A double tap during capture finishes the current segment first. The
    /// pending mode is applied only after AVFoundation has released that input,
    /// so recording metadata and the active hardware can never disagree.
    private var pendingInputModeAfterFinalization: MacInputMode?
    private var lastHistoryRecordID: UUID?
    /// Tracks whether the editable "last transcript" is still backed by a
    /// pending delivery entry. If that entry is possibly delivered, the global
    /// Paste Last shortcut must not bypass the explicit duplicate-risk flow.
    private var lastTranscriptPendingID: UUID?
    /// A newly finalized transcript is not reusable through the generic
    /// Copy/Paste Last actions until its first output has either completed or
    /// been explicitly resolved. In particular, nil escrow means persistence
    /// failed closed; it never means the text is free to output and retry later.
    @Published private(set) var lastTranscriptOutputIsResolved = true
    /// Explicit Copy can resolve an escrow before its ordered delivery turn is
    /// reached. The durable absence is intentional; this in-process receipt
    /// tells the waiting delivery job not to report that user action as loss.
    private var explicitlyResolvedDeliveryEscrowIDs = Set<UUID>()
    /// Old affected builds could leave several History rows for one source
    /// recording. Noncanonical same-source escrows are hidden until startup can
    /// retire them atomically; joining them into one release would paste the
    /// same dictation more than once.
    private var suppressedDuplicateDeliveryEscrowIDs = Set<UUID>()
    private var connectedDeviceID: String?
    private var pendingWatchTimer: Timer?
    /// Delivery is asynchronous now, so the 0.4 s watcher must not start a
    /// second paste on top of one already in progress.
    private var isDeliveringHeldTranscripts = false
    /// A normal ordered delivery has already crossed into its serialized paste
    /// transaction. History/last-transcript Copy must not remove that escrow
    /// underneath an in-flight side effect.
    private var activeDeliveryEscrowIDs = Set<UUID>()
    /// An opaque accessibility field can accept a paste without exposing a
    /// readable value. Once that side effect happened, automatic retries are
    /// suspended so the same dictation cannot be inserted every 0.4 seconds.
    /// The transcript stays queued for an explicit copy, paste, or discard.
    private var suspendedAutomaticHeldIDs = Set<UUID>()
    /// Dictations deliver in the order they were spoken even when a later,
    /// shorter one finishes transcribing first. `nextDeliverySequence` is the
    /// ticket now being served; results that arrive early wait in `completed`.
    private var nextSpeakSequence = 0
    private var nextDeliverySequence = 0
    private var completedDictations: [Int: MacFinishedDictation] = [:]
    private var isDrainingCompletedDictations = false
    private var childStoreSubscriptions: [AnyCancellable] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var sessionHeartbeatTimer: Timer?
    private var hasStartedSessionTracking = false
    private var terminationPreparationInProgress = false
    /// A normal second Quit must not bypass a failed attempt to journal an
    /// active recording. The user can still force-quit at the OS level, but
    /// SpeakPaste will never silently turn a filesystem error into consent to
    /// discard speech.
    private var terminationBlockedByUnjournaledRecording = false
    private var pendingTerminationRecording: MacTerminationRecording?

    private static let chosenDeviceKey = "mac-chosen-device-id"
    private static let preferredDeviceIDsKey = "mac-preferred-device-ids"
    private static let inputModeKey = "mac-input-mode"
    private static let languageKey = "mac-language"
    private static let cleanSpeechKey = "mac-clean-speech"
    private static let autoPasteKey = "mac-auto-paste"
    private static let contextAwarenessKey = "mac-context-awareness"
    private static let spokenFormattingCommandsKey = "mac-spoken-formatting-commands"
    private static let hudEnabledKey = "mac-hud-enabled"
    private static let hudPlacementKey = "mac-hud-placement"
    private static let showInDockKey = "mac-show-in-dock"
    private static let retainSuccessfulAudioKey = "mac-retain-successful-audio"
    private static let completedOnboardingKey = "mac-completed-onboarding"
    private static let retryableFailuresKey = "mac-retryable-failures"
    /// Earlier builds auto-persisted whatever microphone they fell back to, so
    /// a single iPhone-absent launch pinned the built-in mic permanently.
    private static let autoPersistedDeviceKey = "mac-selected-device-id"
    private static let silenceWarningDelay: TimeInterval = 4
    private static let streamStallTimeout: TimeInterval = 1.5
    private static let durationWarning: TimeInterval = 19 * 60
    private static let maximumRecordingDuration: TimeInterval = 20 * 60
    private static let maximumImportBytes: Int64 = 1_000_000_000
    private static let offlineRetryReason = "Waiting for an internet connection before sending this recording to ElevenLabs."
    private static let connectivityRetryReason = "A connectivity problem prevented this recording from reaching ElevenLabs."
    init(
        recorder: MacAudioRecorder = MacAudioRecorder(),
        client: ElevenLabsClientProtocol = ElevenLabsClient(),
        keychain: KeychainStore = KeychainStore(),
        pasteController: MacPasteController = MacPasteController(),
        reliabilityStore: MacReliabilityStore = MacReliabilityStore(),
        globalHotKey: MacGlobalHotKey = MacGlobalHotKey(),
        sessionHealthMarker: MacSessionHealthMarker = MacSessionHealthMarker()
    ) {
        self.recorder = recorder
        self.client = client
        self.keychain = keychain
        self.pasteController = pasteController
        self.reliabilityStore = reliabilityStore
        self.globalHotKey = globalHotKey
        self.sessionHealthMarker = sessionHealthMarker
        attempts = reliabilityStore.load()
        var completedHistoryByPendingAudioID = history.records.reduce(
            into: [UUID: UUID]()
        ) { links, record in
            guard let pendingAudioID = record.sourcePendingAudioID else { return }
            // History is newest-first. Keep the first link if a build affected
            // by the old duplicate-retry bug happened to append more than one.
            if links[pendingAudioID] == nil {
                links[pendingAudioID] = record.id
            }
        }
        for pendingAudioID in Array(completedHistoryByPendingAudioID.keys) {
            guard
                let markedHistoryID = pendingAudioStore.completedHistoryRecordID(
                    forPendingAudioID: pendingAudioID
                ),
                history.records.contains(where: { record in
                    record.id == markedHistoryID
                        && record.sourcePendingAudioID == pendingAudioID
                })
            else {
                continue
            }
            completedHistoryByPendingAudioID[pendingAudioID] = markedHistoryID
        }
        let sourceLinkedPendingAudioIDsAtLaunch = Set(
            completedHistoryByPendingAudioID.keys
        )
        let canonicalSourceLinkedHistoryRecords = history.records.filter { record in
            guard let pendingAudioID = record.sourcePendingAudioID else { return false }
            return completedHistoryByPendingAudioID[pendingAudioID] == record.id
        }
        let noncanonicalSourceLinkedHistoryRecords = history.records.filter { record in
            guard let pendingAudioID = record.sourcePendingAudioID else { return false }
            return completedHistoryByPendingAudioID[pendingAudioID] != record.id
        }
        suppressedDuplicateDeliveryEscrowIDs = Set(
            noncanonicalSourceLinkedHistoryRecords.map(\.id)
        )
        var deliveryEscrowsAreDurable = true
        if history.isPendingAudioRecoveryAuthorityTrusted {
            do {
                // A source-linked row is still recovery proof and has not
                // reached the completed cleanup boundary. Before launch can
                // unlink or expire it, make the exact text independently
                // durable for manual delivery under every retention mode. Old
                // affected builds could leave multiple rows for one recording;
                // only the newest canonical row becomes deliverable. The whole
                // launch set commits atomically, so a later failure cannot leave
                // early rows queued while their audio still appears retryable.
                // Canonical creation, uncertainty transfer, and retirement of
                // old same-source siblings are one pending-document transition.
                _ = try MacHistoryDeliveryEscrow.canonicalize(
                    canonicalSourceLinkedHistoryRecords,
                    removing: noncanonicalSourceLinkedHistoryRecords,
                    in: pendingTranscriptStore
                )
            } catch {
                deliveryEscrowsAreDurable = false
                suppressedDuplicateDeliveryEscrowIDs.formUnion(
                    canonicalSourceLinkedHistoryRecords.map(\.id)
                )
                recoveryNotice = "Recovery cleanup paused because a transcript delivery handoff could not be saved. History and recovery audio remain preserved: \(error.localizedDescription)"
            }
        }
        if history.isPendingAudioRecoveryAuthorityTrusted,
           deliveryEscrowsAreDurable {
            do {
                try pendingAudioStore.reconcileCompletedHistory(
                    completedHistoryByPendingAudioID
                )
                let acknowledgedIDs = Set(completedHistoryByPendingAudioID.keys)
                let presentUnlinkedHistoryIDs = Set(
                    history.records.compactMap { record in
                        record.sourcePendingAudioID == nil ? record.id : nil
                    }
                )
                let cleanupIDs = acknowledgedIDs.union(
                    pendingAudioStore.completedPendingAudioIDs(
                        linkedToHistoryRecordIDs: presentUnlinkedHistoryIDs
                    )
                )
                if history.clearSourcePendingAudioLinks(acknowledgedIDs) {
                    suppressedDuplicateDeliveryEscrowIDs.removeAll()
                    try pendingAudioStore.finishCompletedCleanup(
                        authorizedPendingAudioIDs: cleanupIDs
                    )
                    if !history.applyAutomaticLimits() {
                        recoveryNotice = "Saved transcript audio is safe, but History retention could not finish: \(history.lastPersistenceError ?? "the History file could not be written")"
                    }
                    if pendingAudioStore.hasPendingCompletionCleanup {
                        let preservedNotice = "Some private recovery audio remains preserved because its matching History record is unavailable. Restore the original History file to finish that cleanup."
                        recoveryNotice = recoveryNotice.map {
                            "\($0) \(preservedNotice)"
                        } ?? preservedNotice
                    }
                } else {
                    recoveryNotice = "Saved transcript audio is acknowledged, but History could not finish its cleanup transaction: \(history.lastPersistenceError ?? "the History file could not be written")"
                }
            } catch {
                recoveryNotice = "Saved transcript audio is still awaiting private cleanup: \(error.localizedDescription)"
            }
        } else if !history.isPendingAudioRecoveryAuthorityTrusted,
                  pendingAudioStore.hasPendingCompletionCleanup {
            recoveryNotice = "Saved transcript recovery is paused because History could not be loaded safely. Completion-marked audio remains private and untouched until History is available again."
        }
        let legacyFailures = Self.loadLegacyRetryableFailures()
        var migratedEveryLegacyFailure = true
        for failure in legacyFailures {
            do {
                if let recovered = pendingAudioStore.records.first(where: { record in
                    (try? pendingAudioStore.audioURL(for: record))?.standardizedFileURL
                        == failure.audioURL.standardizedFileURL
                }) {
                    _ = try pendingAudioStore.updateMetadata(
                        recovered.id,
                        deviceName: failure.deviceName,
                        recordingDuration: failure.recordingDuration,
                        reason: failure.reason,
                        createdAt: failure.createdAt
                    )
                } else {
                    let record = try pendingAudioStore.stage(
                        sourceURL: failure.audioURL,
                        id: failure.id,
                        deviceName: failure.deviceName,
                        recordingDuration: failure.recordingDuration,
                        reason: failure.reason,
                        createdAt: failure.createdAt
                    )
                    _ = try pendingAudioStore.markWaiting(record.id, reason: failure.reason)
                }
            } catch {
                migratedEveryLegacyFailure = false
            }
        }
        if migratedEveryLegacyFailure {
            UserDefaults.standard.removeObject(forKey: Self.retryableFailuresKey)
        }
        retryableFailures = pendingAudioStore.records.compactMap { record in
            guard
                record.status == .waiting,
                !sourceLinkedPendingAudioIDsAtLaunch.contains(record.id),
                let audioURL = try? pendingAudioStore.audioURL(for: record)
            else {
                return nil
            }
            return MacRetryableDictation(
                id: record.id,
                audioURL: audioURL,
                target: nil,
                requiresManualOutput: true,
                retriesOnReconnect: record.retryOnReconnect == true,
                interruptionReason: record.interruptionReason,
                deviceName: record.deviceName,
                recordingDuration: record.recordingDuration,
                reason: record.reason,
                createdAt: record.createdAt
            )
        }
        reconnectRetryIDs = Set(
            retryableFailures.compactMap { $0.retriesOnReconnect ? $0.id : nil }
        )
        if let error = pendingAudioStore.lastPersistenceError {
            recoveryNotice = "Audio recovery needed attention: \(error)"
        }
        heldTranscripts = pendingTranscriptStore.transcripts
            .filter { !suppressedDuplicateDeliveryEscrowIDs.contains($0.id) }
            .map { pending in
            MacHeldTranscript(
                id: pending.id,
                text: pending.text,
                target: nil,
                destinationApplicationName: pending.destinationApplicationName,
                destinationBundleIdentifier: pending.destinationBundleIdentifier,
                createdAt: pending.createdAt,
                deliveryState: pending.deliveryState
            )
            }
        // An explicit process environment key is the local-development and UI
        // test boundary. Do not query the user's real Keychain in that mode:
        // CFFIXED_USER_HOME isolates defaults and files, but macOS Keychain
        // access is still global to the signed identity.
        if hasEnvironmentAPIKey {
            hasSavedAPIKey = false
        } else {
            hasSavedAPIKey = keychain.load()?.isEmpty == false
        }
        // Settings were rebuilt at their defaults on every launch, so a chosen
        // language or a disabled auto-paste never survived a restart.
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.inputModeKey) {
            inputMode = MacInputMode(rawValue: stored)
        }
        preferredDeviceIDs = defaults.stringArray(forKey: Self.preferredDeviceIDsKey) ?? []
        if preferredDeviceIDs.isEmpty,
           let legacyChoice = defaults.string(forKey: Self.chosenDeviceKey),
           !legacyChoice.isEmpty {
            preferredDeviceIDs = [legacyChoice]
            defaults.set(preferredDeviceIDs, forKey: Self.preferredDeviceIDsKey)
        }
        if let stored = defaults.string(forKey: Self.languageKey),
           let restored = TranscriptionLanguage(rawValue: stored) {
            language = restored
        }
        if defaults.object(forKey: Self.cleanSpeechKey) != nil {
            cleanSpeech = defaults.bool(forKey: Self.cleanSpeechKey)
        }
        if defaults.object(forKey: Self.autoPasteKey) != nil {
            autoPaste = defaults.bool(forKey: Self.autoPasteKey)
        }
        if defaults.object(forKey: Self.contextAwarenessKey) != nil {
            contextAwareness = defaults.bool(forKey: Self.contextAwarenessKey)
        }
        if defaults.object(forKey: Self.spokenFormattingCommandsKey) != nil {
            spokenFormattingCommands = defaults.bool(forKey: Self.spokenFormattingCommandsKey)
        }
        if defaults.object(forKey: Self.hudEnabledKey) != nil {
            hudEnabled = defaults.bool(forKey: Self.hudEnabledKey)
        }
        if let storedPlacement = defaults.string(forKey: Self.hudPlacementKey),
           let placement = MacHUDPlacement(rawValue: storedPlacement) {
            hudPlacement = placement
        }
        if defaults.object(forKey: Self.showInDockKey) != nil {
            showInDock = defaults.bool(forKey: Self.showInDockKey)
        }
        if defaults.object(forKey: Self.retainSuccessfulAudioKey) != nil {
            retainSuccessfulAudio = defaults.bool(forKey: Self.retainSuccessfulAudioKey)
        }
        if history.isPendingAudioRecoveryAuthorityTrusted {
            if retainSuccessfulAudio {
                reconcileRetainedHistoryAudio(
                    referencedFileNames: history.referencedAudioFileNames
                )
            } else {
                removeAllRetainedHistoryAudio()
            }
        }
        hasCompletedOnboarding = defaults.bool(forKey: Self.completedOnboardingKey)
        applyActivationPolicy()
        MacKeyboardLayout.startObservingLayoutChanges()
        // A grant can be given or revoked in System Settings while the user
        // never returns to SpeakPaste, which used to leave the shortcut dead
        // with no explanation.
        // The stores are separate observable objects, so SwiftUI views bound to
        // this model would otherwise never redraw when their contents change.
        for publisher in [
            vocabulary.objectWillChange.eraseToAnyPublisher(),
            replacements.objectWillChange.eraseToAnyPublisher(),
            history.objectWillChange.eraseToAnyPublisher(),
            sounds.objectWillChange.eraseToAnyPublisher(),
            permissions.objectWillChange.eraseToAnyPublisher(),
            deliveryPolicies.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &childStoreSubscriptions)
        }
        // Retention can remove several records in one atomic History write.
        // Mirror the published prospective list into the audio store so every
        // now-orphaned successful recording is removed as part of the same UI
        // action and not deferred until a future launch.
        history.$records
            .dropFirst()
            .sink { [weak self] records in
                self?.reconcileRetainedHistoryAudio(
                    referencedFileNames: Set(records.compactMap(\.retainedAudioFileName))
                )
            }
            .store(in: &childStoreSubscriptions)
        permissions.startObserving { [weak self] in
            self?.globalHotKey.refreshMonitor()
            self?.objectWillChange.send()
        }
        UserDefaults.standard.removeObject(forKey: Self.autoPersistedDeviceKey)
        refreshDevices()
        observeDeviceChanges()
        observeLifecycleChanges()
        startNetworkMonitoring()
        recorder.setRecordingFailureHandler { [weak self] error, salvagedAudioURL in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedRecordingFailure(error, salvagedAudioURL: salvagedAudioURL)
            }
        }
        globalHotKey.install(
            toggle: { [weak self] in self?.toggleRecording() },
            switchInput: { [weak self] in self?.switchInputMode() },
            isRecordingActive: { [weak self] in
                guard let self else { return false }
                return self.phase == .recording || self.phase == .connecting
            },
            cancel: { [weak self] in self?.requestRecordingCancellation() },
            release: { [weak self] in self?.releaseHeldTranscripts() },
            pasteLast: { [weak self] in self?.pasteLastTranscript() },
            copyLast: { [weak self] in self?.copyTranscript() }
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
#if SPEAKPASTE_UI_TEST_INSTANCE
        if ProcessInfo.processInfo.environment["SPEAKPASTE_UI_TEST_FORCE_MISSING_API_KEY"] == "1" {
            return false
        }
#endif
        return hasSavedAPIKey || environmentAPIKey?.isEmpty == false
    }

    var canStartRecording: Bool {
        hasAPIKey
            && selectedDevice != nil
            && permissions.granted[.microphone] == true
    }

    var isShortcutGlobal: Bool { globalHotKey.isGlobal }

    var hotKeyLabel: String { MacGlobalHotKey.toggleLabel }
    var switchInputHotKeyLabel: String { MacGlobalHotKey.switchInputLabel }
    var cancelHotKeyLabel: String { MacGlobalHotKey.cancelLabel }
    var releaseHotKeyLabel: String { MacGlobalHotKey.releaseLabel }
    var pasteLastHotKeyLabel: String { MacGlobalHotKey.pasteLastLabel }
    var copyLastHotKeyLabel: String { MacGlobalHotKey.copyLastLabel }

    var hasUncertainHeldTranscripts: Bool {
        heldTranscripts.contains(where: \.deliveryIsUncertain)
    }

    /// Records the microphone the user picked in the UI. Only a deliberate
    /// choice is persisted, so an unavailable-iPhone moment can never write
    /// itself in as a lasting preference.
    func selectDevice(_ deviceID: String) {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        if selectedDeviceID != deviceID {
            microphoneTestSound?.stop()
            microphoneTestState = .idle
            inputLevel = 0
        }
        selectDevice(device, semanticMode: semanticMode(for: device))
    }

    func removePreferredDevice(_ deviceID: String) {
        preferredDeviceIDs.removeAll { $0 == deviceID }
        UserDefaults.standard.set(preferredDeviceIDs, forKey: Self.preferredDeviceIDsKey)
        if selectedDeviceID == deviceID, !phase.isBusy, !isMicrophoneConnected {
            selectedDeviceID = ""
            resolveSelection()
        }
    }

    func movePreferredDevice(_ deviceID: String, by offset: Int) {
        guard
            let index = preferredDeviceIDs.firstIndex(of: deviceID),
            preferredDeviceIDs.indices.contains(index + offset)
        else {
            return
        }
        preferredDeviceIDs.swapAt(index, index + offset)
        UserDefaults.standard.set(preferredDeviceIDs, forKey: Self.preferredDeviceIDsKey)
        if !phase.isBusy, !isMicrophoneConnected { resolveSelection() }
    }

    func refreshDevices() {
        devices = MacAudioDeviceCatalog.availableInputs()
        // Re-resolving mid-dictation could swap the device out from under an
        // in-flight recording, so only the device list is refreshed there.
        guard !phase.isBusy, !isMicrophoneConnected else { return }
        resolveSelection()
    }

    private func resolveSelection() {
        if let inputMode {
            guard let modeDevice = availableDevice(for: inputMode) else {
                selectedDeviceID = ""
                deviceSelectionNotice = unavailableMessage(for: inputMode)
                return
            }
            selectedDeviceID = modeDevice.id
            deviceSelectionNotice = nil
            return
        }

        if let preferred = preferredDeviceIDs.first(where: { preferredID in
            devices.contains(where: { $0.id == preferredID })
        }), let device = devices.first(where: { $0.id == preferred }) {
            selectDevice(device, semanticMode: semanticMode(for: device))
            deviceSelectionNotice = nil
            return
        }
        if let continuityDevice = devices.first(where: \.isContinuityDevice) {
            selectDevice(continuityDevice, semanticMode: .iPhone)
            return
        }

        // No iPhone, and no microphone this user actually asked for. Silently
        // substituting a Mac microphone here is what made every dictation run
        // through the built-in mic while appearing to work, so leave the
        // choice unmade and say so.
        selectedDeviceID = ""
        if !preferredDeviceIDs.isEmpty {
            deviceSelectionNotice = devices.isEmpty
                ? "The microphone you chose is no longer available, and no others were found."
                : "The microphone you chose is no longer available. Bring your iPhone nearby and refresh, or pick another microphone."
        } else {
            deviceSelectionNotice = devices.isEmpty
                ? "No microphones found. Connect one or bring your iPhone nearby, then refresh."
                : "No iPhone microphone is available. Bring your iPhone nearby and refresh, or pick a microphone below — SpeakPaste will not choose one for you."
        }
    }

    private func semanticMode(for device: MacAudioInputDevice) -> MacInputMode? {
        if device.isContinuityDevice { return .iPhone }
        if device.isBuiltInDevice { return .mac }
        return nil
    }

    private func availableDevice(for mode: MacInputMode) -> MacAudioInputDevice? {
        if let selected = selectedDevice,
           mode.matches(
               isContinuityDevice: selected.isContinuityDevice,
               isBuiltInDevice: selected.isBuiltInDevice
           ) {
            return selected
        }
        if let preferred = preferredDeviceIDs.lazy.compactMap({ [self] preferredID in
            devices.first(where: { $0.id == preferredID })
        }).first(where: { device in
            mode.matches(
                isContinuityDevice: device.isContinuityDevice,
                isBuiltInDevice: device.isBuiltInDevice
            )
        }) {
            return preferred
        }
        return devices.first { device in
            mode.matches(
                isContinuityDevice: device.isContinuityDevice,
                isBuiltInDevice: device.isBuiltInDevice
            )
        }
    }

    private func selectDevice(
        _ device: MacAudioInputDevice,
        semanticMode: MacInputMode?
    ) {
        selectedDeviceID = device.id
        deviceSelectionNotice = nil
        preferredDeviceIDs.removeAll { $0 == device.id }
        preferredDeviceIDs.insert(device.id, at: 0)
        let defaults = UserDefaults.standard
        defaults.set(preferredDeviceIDs, forKey: Self.preferredDeviceIDsKey)
        defaults.set(device.id, forKey: Self.chosenDeviceKey)
        inputMode = semanticMode
        if let semanticMode {
            defaults.set(semanticMode.rawValue, forKey: Self.inputModeKey)
        } else {
            defaults.removeObject(forKey: Self.inputModeKey)
        }
    }

    private func unavailableMessage(for mode: MacInputMode) -> String {
        switch mode {
        case .mac:
            "Mac input mode is selected, but the built-in microphone is unavailable."
        case .iPhone:
            "iPhone input mode is selected, but no Continuity microphone is available. Keep the iPhone nearby and locked, then refresh."
        }
    }

    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.save(trimmed)
            apiKeyDraft = ""
            hasSavedAPIKey = true
            apiKeyNotice = "API key saved in Keychain."
            if case .failed = phase { phase = .ready }
        } catch {
            apiKeyNotice = "Could not save the API key: \(error.localizedDescription)"
            if !phase.isBusy { phase = .failed(error.localizedDescription) }
        }
    }

    func deleteAPIKey() {
        do {
            try keychain.delete()
            hasSavedAPIKey = false
            apiKeyNotice = "Saved API key removed."
        } catch {
            // Deletion deliberately tries every compatible Keychain backend.
            // An ad-hoc build can remove its usable traditional entry and then
            // fail to inspect a Data Protection entry owned by another code
            // identity. Re-read what this process can actually use instead of
            // leaving capture enabled from stale in-memory state.
            hasSavedAPIKey = keychain.load() != nil
            let message = "Could not remove the saved API key: \(error.localizedDescription)"
            apiKeyNotice = message
            if !phase.isBusy { phase = .failed(message) }
        }
    }

    func toggleRecording() {
        guard !microphoneTestState.isRunning else { return }
        switch phase {
        case .recording:
            stopMeter()
            sounds.playRecordingStopped()
            phase = .finalizing
            Task { await stopAndTranscribe() }
        case .ready, .succeeded, .failed:
            beginRecordingRequest()
        case .connecting, .finalizing:
            break
        }
    }

    /// Switches the semantic capture source without letting the first half of
    /// the Command double-tap also stop dictation. During a live recording the
    /// existing WAV is finalized and queued first, then capture resumes on the
    /// other source as the next ordered segment.
    func switchInputMode() {
        guard !microphoneTestState.isRunning else { return }
        let baseMode = pendingInputModeAfterFinalization
            ?? inputMode
            ?? selectedDevice.flatMap { semanticMode(for: $0) }
            ?? .mac
        let targetMode = baseMode.opposite
        guard let targetDevice = availableDevice(for: targetMode) else {
            deviceSelectionNotice = unavailableMessage(for: targetMode)
            return
        }

        switch phase {
        case .recording:
            pendingInputModeAfterFinalization = targetMode
            stopMeter()
            sounds.playRecordingStopped()
            phase = .finalizing
            Task { await stopAndTranscribe() }
        case .connecting:
            pendingInputModeAfterFinalization = nil
            captureRequestID = nil
            captureStartTask?.cancel()
            captureStartTask = nil
            recorder.disconnect()
            isMicrophoneConnected = false
            connectedDeviceID = nil
            connectionLatency = nil
            deliveryTarget = nil
            selectDevice(targetDevice, semanticMode: targetMode)
            beginRecordingRequest()
        case .finalizing:
            // The stop path reads this only after AVFoundation has released the
            // active device. Another double-tap before then reverses the pending
            // target without mutating current recording metadata.
            pendingInputModeAfterFinalization = targetMode
        case .ready, .succeeded, .failed:
            pendingInputModeAfterFinalization = nil
            selectDevice(targetDevice, semanticMode: targetMode)
        }
    }

    private func beginRecordingRequest() {
        captureStartTask?.cancel()
        let requestID = UUID()
        captureRequestID = requestID
        if phase == .connecting {
            // Switching sources while an earlier connection is still pending
            // begins a new bounded attempt even though the enum case is the
            // same. Reset the indicator lifetime for the target source.
            phaseStartedAt = Date()
        } else {
            phase = .connecting
        }
        captureStartTask = Task { [weak self] in
            await self?.startRecording(requestID: requestID)
        }
    }

    @discardableResult
    func copyTranscript() -> Bool {
        guard !transcript.isEmpty else { return false }
        let resolutionID = lastTranscriptPendingID
            ?? (lastTranscriptOutputIsResolved ? nil : lastHistoryRecordID)
        guard lastTranscriptOutputIsResolved || resolutionID != nil else {
            recoveryNotice = "Copy is paused because this transcript has no durable delivery handoff yet. Its recovery audio remains available for retry."
            if !phase.isBusy {
                phase = .failed("Could not copy until transcript recovery is durable.")
            }
            return false
        }
        return copyText(
            transcript,
            resolvingPendingID: resolutionID,
            requiresDurableResolution: !lastTranscriptOutputIsResolved
        )
    }

    func pasteLastTranscript() {
        guard !transcript.isEmpty else { return }
        guard lastTranscriptOutputIsResolved else {
            phase = .failed(
                "The last transcript still owns unresolved recovery data. Use Copy or the waiting-text review flow before Paste Last."
            )
            return
        }
        if let lastTranscriptPendingID,
           pendingTranscriptStore.transcript(withID: lastTranscriptPendingID) != nil {
            phase = .failed(
                "The last transcript is still owned by the waiting-text recovery queue. Use its release shortcut—or the duplicate-risk flow when warned—instead of Paste Last."
            )
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.pasteController.pasteAtCurrentFocus(self.transcript)
            guard !self.phase.isBusy, !result.isDelivered else { return }
            self.phase = .failed("Could not paste the last transcript — \(result.detail).")
        }
    }

    func clearTranscript() {
        transcript = ""
        originalTranscript = ""
        lastHistoryRecordID = nil
        lastTranscriptPendingID = nil
        lastTranscriptOutputIsResolved = true
        transcriptLearningNotice = nil
    }

    /// Deletes one History row only after its pending audio is durably marked
    /// consumed. A marker failure leaves the linked row intact as the launch-
    /// recovery proof that prevents a duplicate transcription and delivery.
    @discardableResult
    func deleteHistoryRecord(_ id: UUID) -> Bool {
        guard var record = history.records.first(where: { $0.id == id }) else { return false }
        historyActionError = nil
        guard !reprocessingHistoryRecordIDs.contains(id) else {
            historyActionError = "Cancel Process Again before deleting this transcript."
            return false
        }
        guard history.isPendingAudioRecoveryAuthorityTrusted else {
            historyActionError = "The transcript was not deleted because History is not currently safe to rewrite."
            return false
        }

        if record.sourcePendingAudioID != nil {
            let requestedIDs = Set([record.id])
            guard
                let durableIDs = prepareDeliveryEscrows(for: requestedIDs),
                durableIDs == requestedIDs,
                ensureSourceRecoveryIsUnlinked(for: durableIDs)
            else {
                historyActionError = recoveryNotice
                    ?? "The transcript was not deleted because its delivery handoff is not yet durable."
                return false
            }
            for escrowID in durableIDs {
                if let pending = pendingTranscriptStore.transcript(withID: escrowID) {
                    presentPendingTranscript(pending, target: nil)
                }
            }
            // Never-store retention may have removed the temporary row as soon
            // as its source link closed. In that case the requested deletion is
            // already complete and the delivery escrow still owns the text.
            guard let refreshed = history.records.first(where: { $0.id == id }) else {
                if playingHistoryRecordID == id { stopHistoryAudioPlayback() }
                return true
            }
            record = refreshed
        }

        var cleanupIDs = Set<UUID>()
        if let pendingAudioID = record.sourcePendingAudioID {
            do {
                try pendingAudioStore.reconcileCompletedHistory([pendingAudioID: record.id])
            } catch {
                historyActionError = "The transcript was not deleted because its recovery audio could not be safely acknowledged: \(error.localizedDescription)"
                return false
            }
            guard history.clearSourcePendingAudioLinks([pendingAudioID]) else {
                historyActionError = history.lastPersistenceError
                    ?? "The transcript could not finish its recovery transaction."
                return false
            }
            cleanupIDs.insert(pendingAudioID)
        } else {
            cleanupIDs = pendingAudioStore.completedPendingAudioIDs(
                linkedToHistoryRecordIDs: [record.id]
            )
        }
        do {
            try pendingAudioStore.finishCompletedCleanup(
                authorizedPendingAudioIDs: cleanupIDs
            )
        } catch {
            historyActionError = "The transcript was not deleted because its private recovery audio could not be cleaned up safely: \(error.localizedDescription)"
            return false
        }
        let deleted = history.delete(id)
        if !deleted {
            historyActionError = history.lastPersistenceError
                ?? "The transcript could not be deleted from disk."
        } else if playingHistoryRecordID == id {
            stopHistoryAudioPlayback()
        }
        return deleted
    }

    /// The purge is the same two-store transaction, batched so every required
    /// completion marker lands before a single linked History row disappears.
    @discardableResult
    func deleteAllHistory() -> Bool {
        historyActionError = nil
        guard reprocessingHistoryRecordIDs.isEmpty else {
            historyActionError = "Cancel Process Again before deleting History."
            return false
        }
        guard history.isPendingAudioRecoveryAuthorityTrusted else {
            historyActionError = "History was not purged because its on-disk document is not currently safe to rewrite."
            return false
        }
        let sourceLinkedHistoryIDs = Set(
            history.records.compactMap { record in
                record.sourcePendingAudioID == nil ? nil : record.id
            }
        )
        if !sourceLinkedHistoryIDs.isEmpty {
            guard
                let durableIDs = prepareDeliveryEscrows(for: sourceLinkedHistoryIDs),
                durableIDs == sourceLinkedHistoryIDs,
                ensureSourceRecoveryIsUnlinked(for: durableIDs)
            else {
                historyActionError = recoveryNotice
                    ?? "History was not purged because every delivery handoff is not yet durable."
                return false
            }
            for escrowID in durableIDs {
                if let pending = pendingTranscriptStore.transcript(withID: escrowID) {
                    presentPendingTranscript(pending, target: nil)
                }
            }
        }
        let links = history.records.reduce(into: [UUID: UUID]()) { result, record in
            guard let pendingAudioID = record.sourcePendingAudioID else { return }
            if result[pendingAudioID] == nil { result[pendingAudioID] = record.id }
        }
        let unlinkedHistoryRecordIDs = Set(
            history.records.compactMap { record in
                record.sourcePendingAudioID == nil ? record.id : nil
            }
        )
        var cleanupIDs = pendingAudioStore.completedPendingAudioIDs(
            linkedToHistoryRecordIDs: unlinkedHistoryRecordIDs
        )
        do {
            try pendingAudioStore.reconcileCompletedHistory(links)
        } catch {
            historyActionError = "History was not purged because recovery audio could not be safely acknowledged: \(error.localizedDescription)"
            return false
        }
        let linkedPendingAudioIDs = Set(links.keys)
        guard history.clearSourcePendingAudioLinks(linkedPendingAudioIDs) else {
            historyActionError = history.lastPersistenceError
                ?? "History could not finish its recovery transaction."
            return false
        }
        cleanupIDs.formUnion(linkedPendingAudioIDs)
        do {
            try pendingAudioStore.finishCompletedCleanup(
                authorizedPendingAudioIDs: cleanupIDs
            )
        } catch {
            historyActionError = "History was not purged because private recovery audio could not be cleaned up safely: \(error.localizedDescription)"
            return false
        }
        let deleted = history.deleteAll()
        if !deleted {
            historyActionError = history.lastPersistenceError
                ?? "History could not be purged from disk."
        } else {
            stopHistoryAudioPlayback()
        }
        return deleted
    }

    var keepsSuccessfulHistoryAudio: Bool {
        retainSuccessfulAudio && history.retentionDays != -1
    }

    func setHistoryRetentionDays(_ days: Int) {
        historyActionError = nil
        history.retentionDays = days
        // Never-store is an immediate privacy action, including recordings
        // retained under the previous mode.
        if days == -1 {
            successfulAudioRetentionGeneration &+= 1
            removeAllRetainedHistoryAudio()
        }
    }

    func hasRetainedAudio(for record: MacTranscriptRecord) -> Bool {
        guard let fileName = record.retainedAudioFileName else { return false }
        return (try? historyAudioStore.audioURL(for: fileName)) != nil
    }

    func toggleHistoryAudioPlayback(_ record: MacTranscriptRecord) {
        if playingHistoryRecordID == record.id {
            stopHistoryAudioPlayback()
            return
        }
        stopHistoryAudioPlayback()
        guard let fileName = record.retainedAudioFileName else {
            historyActionError = "That transcript does not have retained audio."
            return
        }
        do {
            let url = try historyAudioStore.audioURL(for: fileName)
            guard let sound = NSSound(contentsOf: url, byReference: false), sound.play() else {
                historyActionError = "The retained recording could not be played."
                return
            }
            historyPlaybackSound = sound
            playingHistoryRecordID = record.id
            historyActionError = nil
            let expectedID = record.id
            let delay = max(0.25, sound.duration + 0.15)
            historyPlaybackResetTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard self?.playingHistoryRecordID == expectedID else { return }
                self?.stopHistoryAudioPlayback()
            }
        } catch {
            historyActionError = "The retained recording is unavailable: \(error.localizedDescription)"
        }
    }

    func stopHistoryAudioPlayback() {
        historyPlaybackResetTask?.cancel()
        historyPlaybackResetTask = nil
        historyPlaybackSound?.stop()
        historyPlaybackSound = nil
        playingHistoryRecordID = nil
    }

    /// History text and a same-ID delivery escrow must always describe the same
    /// completed output. Editing while either source-audio completion or pending
    /// delivery is open would split those two proofs and make launch recovery
    /// collide or deliver stale text.
    func historyRecordCanBeModified(_ record: MacTranscriptRecord) -> Bool {
        guard let current = history.records.first(where: { $0.id == record.id }) else {
            return false
        }
        return current.sourcePendingAudioID == nil
            && pendingTranscriptStore.transcript(withID: current.id) == nil
    }

    @discardableResult
    func updateHistoryRecordText(_ id: UUID, to text: String) -> Bool {
        guard let record = history.records.first(where: { $0.id == id }) else {
            historyActionError = "That transcript is no longer in History."
            return false
        }
        guard historyRecordCanBeModified(record) else {
            historyActionError = "Resolve this transcript's waiting delivery before editing its saved History text."
            return false
        }
        guard history.updateText(id, to: text) else {
            historyActionError = history.lastPersistenceError
                ?? "The edited transcript could not be saved to History."
            return false
        }
        historyActionError = nil
        return true
    }

    /// Runs the original audio through current Scribe, language, vocabulary,
    /// cleanup, and replacement settings. It updates the History row only; a
    /// reprocess never pastes into an app or triggers auto-send as a side
    /// effect.
    func reprocessHistoryRecord(_ record: MacTranscriptRecord) {
        guard !reprocessingHistoryRecordIDs.contains(record.id) else { return }
        guard historyRecordCanBeModified(record) else {
            historyActionError = "Resolve this transcript's waiting delivery before processing its recording again."
            return
        }
        guard let fileName = record.retainedAudioFileName else {
            historyActionError = "That transcript does not have retained audio to process again."
            return
        }
        let audioURL: URL
        do {
            audioURL = try historyAudioStore.audioURL(for: fileName)
        } catch {
            historyActionError = "The retained recording is unavailable: \(error.localizedDescription)"
            return
        }
        guard let apiKey = resolvedAPIKey else {
            historyActionError = "Add your ElevenLabs API key before processing this recording again."
            return
        }
        reprocessingHistoryRecordIDs.insert(record.id)
        historyActionError = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.reprocessingHistoryRecordIDs.remove(record.id)
                self.historyReprocessTasks[record.id] = nil
            }
            do {
                let result = try await self.client.transcribe(
                    audioURL: audioURL,
                    apiKey: apiKey,
                    language: self.language,
                    cleanSpeech: self.cleanSpeech,
                    keyterms: self.requestKeyterms(for: nil)
                )
                try Task.checkCancellation()
                let processed = MacTranscriptPostProcessor.apply(
                    result.text,
                    replacements: self.replacements.replacements,
                    precedingText: nil,
                    spokenFormattingCommands: self.spokenFormattingCommands
                )
                guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ElevenLabsClientError.emptyTranscript
                }
                guard self.updateHistoryRecordText(record.id, to: processed) else {
                    return
                }
                self.originalTranscript = processed
                self.transcript = processed
                self.lastHistoryRecordID = record.id
                self.lastTranscriptPendingID = nil
                self.lastTranscriptOutputIsResolved = true
                self.historyActionError = nil
            } catch {
                if Task.isCancelled || error is CancellationError {
                    self.historyActionError = nil
                } else {
                    self.historyActionError = "Could not process that recording again: \(self.diagnosticMessage(for: error))"
                }
            }
        }
        historyReprocessTasks[record.id] = task
    }

    func cancelHistoryReprocessing(_ id: UUID) {
        historyReprocessTasks[id]?.cancel()
    }

    private func removeAllRetainedHistoryAudio() {
        guard history.establishDurableDocumentForExplicitPrivacyAction() else {
            historyActionError = history.lastPersistenceError
                ?? "Retained audio was preserved because History is not currently safe to rewrite."
            return
        }
        guard historyAudioStore.reconcile(referencedFileNames: []) else {
            historyActionError = "Some retained audio could not be removed: \(historyAudioStore.lastPersistenceError ?? "the audio folder could not be updated")"
            return
        }
        guard history.clearRetainedAudioReferences() else {
            historyActionError = history.lastPersistenceError
                ?? "History could not remove its local-audio references."
            return
        }
        historyActionError = nil
    }

    private func reconcileRetainedHistoryAudio(referencedFileNames: Set<String>) {
        guard history.isPendingAudioRecoveryAuthorityTrusted else { return }
        guard historyAudioStore.reconcile(referencedFileNames: referencedFileNames) else {
            historyActionError = "Retained History audio needs cleanup: \(historyAudioStore.lastPersistenceError ?? "the audio folder could not be updated")"
            return
        }
    }

    private func retainedAudioPublicationFailure(
        repairedHistory: Bool,
        detail: String?
    ) {
        if repairedHistory {
            recoveryNotice = "The transcript is safe, but its optional audio copy disappeared before History could publish it: \(detail ?? "the retained file was unavailable")"
        } else {
            recoveryNotice = "The transcript is safe, but History could not repair a missing optional-audio reference: \(history.lastPersistenceError ?? detail ?? "the History file could not be updated")"
        }
    }

    /// Turns simple one-word edits into deterministic correction rules. It is
    /// explicit rather than automatic: a rewrite of the sentence's meaning is
    /// not evidence that Scribe misheard a word.
    func learnTranscriptEdits() {
        let before = correctionTokens(in: originalTranscript)
        let after = correctionTokens(in: transcript)
        guard !before.isEmpty, before.count == after.count else {
            transcriptLearningNotice = "Edit word-for-word to teach a correction; larger rewrites stay local to this transcript."
            return
        }

        let corrections = zip(before, after)
            .filter { heard, written in
                heard.caseInsensitiveCompare(written) != .orderedSame
            }
            .prefix(8)
            .map { (spoken: $0.0, written: $0.1) }
        guard !corrections.isEmpty else {
            transcriptLearningNotice = "No spelling changes to learn."
            return
        }
        let learned = replacements.addAll(corrections)
        guard learned == corrections.count else {
            let detail = replacements.lastPersistenceError
                ?? "the replacement list is full or unavailable"
            transcriptLearningNotice = "Corrections were not learned: \(detail)."
            return
        }

        var followUpFailures: [String] = []
        var seenVocabularyKeys = Set(
            vocabulary.terms.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        let newVocabularyHints = corrections.compactMap { correction -> String? in
            guard correction.written.first?.isUppercase == true else { return nil }
            let key = correction.written
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return seenVocabularyKeys.insert(key).inserted ? correction.written : nil
        }
        if !newVocabularyHints.isEmpty {
            let added = vocabulary.importDelimited(newVocabularyHints.joined(separator: "\n"))
            if added != newVocabularyHints.count {
                let detail = vocabulary.lastPersistenceError ?? "the vocabulary is full"
                followUpFailures.append("some recognition hints were not saved: \(detail)")
            }
        }
        if let lastHistoryRecordID,
           !updateHistoryRecordText(lastHistoryRecordID, to: transcript) {
            let detail = historyActionError
                ?? history.lastPersistenceError
                ?? "the history file could not be written"
            followUpFailures.append("edited History could not be saved: \(detail)")
        }
        originalTranscript = transcript
        if followUpFailures.isEmpty {
            transcriptLearningNotice = "Learned \(learned) correction\(learned == 1 ? "" : "s")."
        } else {
            transcriptLearningNotice = "Learned \(learned) correction\(learned == 1 ? "" : "s"), but \(followUpFailures.joined(separator: "; "))."
        }
    }

    func clearFailure() {
        if case .failed = phase { phase = .ready }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.completedOnboardingKey)
    }

    func showOnboardingAgain() {
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: Self.completedOnboardingKey)
    }

    /// Starts only after the first real app surface appears. A second instance
    /// exits from the application delegate before then, so it cannot overwrite
    /// the primary process's health marker and make a later crash look clean.
    func startSessionTracking() {
        guard !hasStartedSessionTracking else { return }
        hasStartedSessionTracking = true

        do {
            let previous = try sessionHealthMarker.beginSession()
            if previous.endedWithoutCleanTermination == true {
                previousSessionRecoveryNotice = retryableFailures.isEmpty && heldTranscripts.isEmpty
                    ? "SpeakPaste did not shut down cleanly last time. No recoverable dictations were found."
                    : "SpeakPaste recovered work left by the previous session. Review the waiting and retry queues below."
            }
        } catch {
            // Health tracking is support evidence, never a reason dictation
            // itself should stop working.
        }

        // Never scan from init: a second process constructs its model before
        // the application delegate terminates it, and could otherwise move the
        // primary process's live recording out from under AVFoundation. Reaching
        // this guarded lifecycle point identifies the surviving primary.
        let activeCaptureRecovery = MacActiveCaptureRecovery.recover(
            from: FileManager.default.temporaryDirectory,
            into: pendingAudioStore
        )
        if !activeCaptureRecovery.recoveredRecords.isEmpty {
            refreshRetryableFailuresFromJournal()
            let count = activeCaptureRecovery.recoveredRecords.count
            previousSessionRecoveryNotice = "SpeakPaste recovered \(count) recording\(count == 1 ? "" : "s") interrupted during capture. The audio is waiting below and will not be sent until you retry it."
        }
        if !activeCaptureRecovery.failureDescriptions.isEmpty {
            let count = activeCaptureRecovery.failureDescriptions.count
            recoveryNotice = "SpeakPaste found \(count) interrupted recording\(count == 1 ? "" : "s") but could not make all of them immediately retryable. The audio remains on disk for recovery."
        }

        let privateTempCleanup = MacActiveCaptureRecovery.cleanupDisposableSpeechArtifacts(
            in: FileManager.default.temporaryDirectory
        )
        if !privateTempCleanup.failureDescriptions.isEmpty {
            let cleanupMessage = "SpeakPaste could not remove every private upload artifact left by the previous process. No unrelated temp files were touched."
            recoveryNotice = recoveryNotice.map { "\($0) \(cleanupMessage)" } ?? cleanupMessage
        }

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? self.sessionHealthMarker.recordHeartbeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionHeartbeatTimer = timer

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // `willTerminate` is the last reliable synchronous lifecycle
                // point. Scheduling a Task here can lose the clean marker when
                // AppKit exits before the task gets a turn.
                MainActor.assumeIsolated {
                    self?.finishSessionTracking()
                }
            }
        )
    }

    func dismissPreviousSessionRecoveryNotice() {
        previousSessionRecoveryNotice = nil
    }

    func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    private func refreshRetryableFailuresFromJournal() {
        retryableFailures = pendingAudioStore.records.compactMap { record in
            guard
                record.status == .waiting,
                !hasSourceLinkedHistory(forPendingAudioID: record.id),
                let audioURL = try? pendingAudioStore.audioURL(for: record)
            else {
                return nil
            }
            return MacRetryableDictation(
                id: record.id,
                audioURL: audioURL,
                target: nil,
                requiresManualOutput: true,
                retriesOnReconnect: record.retryOnReconnect == true,
                interruptionReason: record.interruptionReason,
                deviceName: record.deviceName,
                recordingDuration: record.recordingDuration,
                reason: record.reason,
                createdAt: record.createdAt
            )
        }
        reconnectRetryIDs = Set(
            retryableFailures.compactMap { $0.retriesOnReconnect ? $0.id : nil }
        )
    }

    /// A source-linked History row proves this audio already produced text.
    /// Until that row has a durable delivery handoff and its completion
    /// transaction finishes, exposing Retry would transcribe and deliver the
    /// same recording a second time.
    private func hasSourceLinkedHistory(forPendingAudioID id: UUID) -> Bool {
        history.records.contains { $0.sourcePendingAudioID == id }
    }

    func exportDiagnostics(to destinationURL: URL) {
        do {
            try MacDiagnosticsExporter.writeAtomically(diagnosticsSnapshot(), to: destinationURL)
            diagnosticsExportNotice = "Saved privacy-safe diagnostics to \(destinationURL.lastPathComponent)."
        } catch {
            diagnosticsExportNotice = "Could not save diagnostics: \(error.localizedDescription)"
        }
    }

    private func diagnosticsSnapshot() -> MacDiagnosticsSnapshot {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let permissionState = permissions.granted
        return MacDiagnosticsSnapshot(
            generatedAt: Date(),
            app: .init(name: "SpeakPaste", version: version, build: build),
            macOS: .init(
                version: ProcessInfo.processInfo.operatingSystemVersionString,
                build: nil
            ),
            permissions: .init(
                microphone: permissionState[.microphone] ?? false,
                accessibility: permissionState[.accessibility] ?? false,
                inputMonitoring: permissionState[.inputMonitoring] ?? false,
                keyboardOutput: permissionState[.postEvents] ?? false,
                launchAtLogin: permissionState[.launchAtLogin] ?? false
            ),
            microphones: devices.map { device in
                .init(
                    transport: diagnosticTransport(for: device),
                    gain: device.inputVolume.map(Double.init)
                )
            },
            reliabilityAttempts: attempts.map { attempt in
                .init(
                    occurredAt: attempt.createdAt,
                    source: diagnosticSource(for: attempt.deviceName),
                    recordingDurationSeconds: attempt.recordingDuration,
                    transcriptionDurationSeconds: attempt.transcriptionDuration,
                    outcome: attempt.outcome == .success ? .success : .failure
                )
            },
            queueCounts: .init(
                transcribingCount: inFlightCount,
                heldTranscriptCount: heldTranscripts.count,
                retryCount: retryableFailures.count
            )
        )
    }

    private func diagnosticTransport(
        for device: MacAudioInputDevice
    ) -> MacDiagnosticsSnapshot.Microphone.Transport {
        switch device.transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            .builtIn
        case kAudioDeviceTransportTypeContinuityCaptureWired:
            .continuityWired
        case kAudioDeviceTransportTypeContinuityCaptureWireless:
            .continuityWireless
        case kAudioDeviceTransportTypeUSB:
            .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            .bluetooth
        case kAudioDeviceTransportTypeVirtual:
            .virtual
        case kAudioDeviceTransportTypeAggregate:
            .aggregate
        case .some(_):
            .other
        case .none:
            .unknown
        }
    }

    private func diagnosticSource(
        for storedDeviceName: String
    ) -> MacDiagnosticsSnapshot.ReliabilityAttempt.Source {
        if storedDeviceName == "Imported audio" { return .imported }
        guard let device = devices.first(where: { $0.name == storedDeviceName }) else {
            return .unknown
        }
        return device.isContinuityDevice ? .continuity : .microphone
    }

    private func finishSessionTracking() {
        captureRequestID = nil
        captureStartTask?.cancel()
        captureStartTask = nil
        microphoneTestTask?.cancel()
        microphoneTestTask = nil
        recorder.disconnectSynchronously()
        endRecordingActivity()
        networkMonitor.cancel()
        sessionHeartbeatTimer?.invalidate()
        sessionHeartbeatTimer = nil
        guard hasStartedSessionTracking else { return }
        try? sessionHealthMarker.markCleanTermination()
        hasStartedSessionTracking = false
    }

    /// Gives AppKit an asynchronous termination barrier. A normal Cmd-Q while
    /// recording stops and finalizes the WAV, fully releases Continuity, and
    /// journals the audio as waiting before the process may exit. In-flight
    /// transcriptions are already journaled and recover as waiting on launch.
    func prepareForTermination() async -> Bool {
        guard !terminationPreparationInProgress else { return false }
        if let pendingTerminationRecording {
            guard journalTerminationRecording(pendingTerminationRecording) else {
                recoveryNotice = "Quit is still blocked because the finalized recording could not be added to the recovery journal. Its private file is retained and SpeakPaste will retry on the next normal Quit."
                return false
            }
            return await waitForFileImportStagingBeforeTermination()
        }
        guard !terminationBlockedByUnjournaledRecording else {
            recoveryNotice = "Quit is blocked because the active recording could not be saved to the recovery journal. Free disk space or fix Application Support access, then try again."
            return false
        }

        terminationPreparationInProgress = true
        defer { terminationPreparationInProgress = false }

        if phase == .connecting {
            cancelRecording()
            return await waitForFileImportStagingBeforeTermination()
        }

        if phase == .finalizing {
            // The ordinary stop path owns the recorder. Wait until it has
            // synchronously staged the resulting WAV (or surfaced a failure)
            // rather than racing it with lifecycle teardown.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            while phase == .finalizing, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard phase != .finalizing else {
                recoveryNotice = "SpeakPaste is still finalizing the active recording, so Quit was cancelled. Try again when the microphone has been released."
                return false
            }
            if case .failed = phase {
                // A failed stop path may still own a partial segment that was
                // not safe enough for the recorder's automatic salvage test.
                // Do not let a second normal Quit bypass that uncertainty.
                terminationBlockedByUnjournaledRecording = true
                recoveryNotice = "Quit remains blocked because finalizing the active recording failed before recovery ownership was confirmed."
                return false
            }
            return await waitForFileImportStagingBeforeTermination()
        }

        guard phase == .recording else {
            return await waitForFileImportStagingBeforeTermination()
        }

        defer { endRecordingActivity() }

        phase = .finalizing
        stopMeter()
        recordingWarning = nil
        automaticStopInProgress = false
        captureRequestID = nil
        captureStartTask?.cancel()
        captureStartTask = nil

        let deviceName = selectedDevice?.name ?? "Unknown microphone"
        let recordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt ?? Date()))
        let audioURL: URL
        do {
            audioURL = try await recorder.stop().url
        } catch let salvaged as MacAudioRecorderSalvagedFailure {
            audioURL = salvaged.audioURL
        } catch {
            terminationBlockedByUnjournaledRecording = true
            isMicrophoneConnected = false
            connectedDeviceID = nil
            connectionLatency = nil
            phase = .failed("Quit was cancelled because the active recording could not be finalized safely: \(diagnosticMessage(for: error))")
            recoveryNotice = "The active recording has not been discarded. Resolve the recorder error before quitting normally."
            return false
        }

        // `stop()` has already synchronously released the capture session.
        isMicrophoneConnected = false
        connectedDeviceID = nil
        connectionLatency = nil
        deliveryTarget = nil
        recordingStartedAt = nil

        let pending = MacTerminationRecording(
            id: MacActiveCaptureRecovery.captureID(forFileName: audioURL.lastPathComponent)
                ?? UUID(),
            audioURL: audioURL,
            deviceName: deviceName,
            recordingDuration: recordingDuration
        )
        pendingTerminationRecording = pending
        if journalTerminationRecording(pending) {
            phase = .ready
            return await waitForFileImportStagingBeforeTermination()
        } else {
            terminationBlockedByUnjournaledRecording = true
            phase = .failed("Quit was cancelled because the active recording could not be journaled safely.")
            recoveryNotice = "The finalized recording remains on disk. SpeakPaste retained its exact location and will retry the private recovery journal on the next normal Quit."
            return false
        }
    }

    /// A normal Quit must not strand a half-copied security-scoped import in
    /// the temporary directory. Once the staging task returns, startTranscription
    /// has already moved the complete private copy into the crash-safe journal.
    /// A very large/slow copy blocks ordinary termination rather than silently
    /// abandoning user-selected audio; Force Quit remains the OS escape hatch.
    private func waitForFileImportStagingBeforeTermination() async -> Bool {
        guard !fileImportTasks.isEmpty else { return true }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while !fileImportTasks.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard fileImportTasks.isEmpty else {
            let message = "SpeakPaste is still securing an imported audio file, so Quit was cancelled. Try again after the import is queued."
            fileImportNotice = message
            recoveryNotice = message
            return false
        }
        return true
    }

    private func journalTerminationRecording(_ pending: MacTerminationRecording) -> Bool {
        let reason = "Saved when SpeakPaste quit before transcription."
        do {
            let record: MacPendingAudioRecord
            if let existing = pendingAudioStore.record(withID: pending.id) {
                record = existing
            } else {
                record = try pendingAudioStore.stage(
                    sourceURL: pending.audioURL,
                    id: pending.id,
                    deviceName: pending.deviceName,
                    recordingDuration: pending.recordingDuration,
                    reason: reason
                )
            }
            // If this second commit fails, the first durable `transcribing`
            // record is still recoverable and launch recovery will make it
            // waiting. Do not turn that harmless metadata failure into loss.
            if record.status == .transcribing {
                _ = try? pendingAudioStore.markWaiting(record.id, reason: reason)
            }
            pendingTerminationRecording = nil
            terminationBlockedByUnjournaledRecording = false
            return true
        } catch {
            // `stage` moves the file before committing its index. If that
            // commit fails, the exact UUID-named file in the private journal
            // is still durable and orphan recovery will register it at launch.
            // Treat only that precise regular, non-symlink destination as safe.
            let extensionName = pending.audioURL.pathExtension.lowercased().isEmpty
                ? "wav"
                : pending.audioURL.pathExtension.lowercased()
            let orphanURL = pendingAudioStore.directoryURL
                .appendingPathComponent(pending.id.uuidString)
                .appendingPathExtension(extensionName)
            if isRegularNonSymbolicFile(orphanURL) {
                pendingTerminationRecording = nil
                terminationBlockedByUnjournaledRecording = false
                return true
            }
            return false
        }
    }

    private func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func transcribeFile(_ sourceURL: URL) {
        guard hasAPIKey else {
            fileImportNotice = "Add your ElevenLabs API key before importing a file."
            return
        }
        guard !phase.isBusy else {
            fileImportNotice = "Finish or cancel the active recording before importing a file."
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fileImportTasks[taskID] = nil }
            await self.queueImportedFile(sourceURL)
        }
        fileImportTasks[taskID] = task
    }

    private func queueImportedFile(_ sourceURL: URL) async {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            let fileManager = FileManager.default
            let asset = AVURLAsset(url: sourceURL)
            guard
                let loaded = try? await asset.load(.duration),
                loaded.isNumeric,
                loaded.seconds.isFinite,
                loaded.seconds > 0
            else {
                fileImportNotice = "Could not verify the duration of \(sourceURL.lastPathComponent), so it was not uploaded. Convert it to a supported audio format or split it into a file shorter than 20 minutes."
                return
            }
            let duration = loaded.seconds
            if duration > Self.maximumRecordingDuration {
                fileImportNotice = "\(sourceURL.lastPathComponent) is longer than the 20-minute quality limit. Split it into smaller files first."
                return
            }
            let temporaryURL = fileManager.temporaryDirectory
                .appendingPathComponent("SpeakPaste-import-\(UUID().uuidString)")
                .appendingPathExtension(sourceURL.pathExtension)
            let maximumImportBytes = Self.maximumImportBytes
            try await Task.detached(priority: .userInitiated) {
                let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
                if let size = attributes[.size] as? NSNumber,
                   size.int64Value > maximumImportBytes {
                    throw MacImportedAudioError.fileTooLarge
                }
                try MacPrivateStoreIO.copyRegularFile(from: sourceURL, to: temporaryURL)
                guard MacActiveCaptureRecovery.makeImportedFilePrivate(at: temporaryURL) else {
                    _ = try? MacPrivateStoreIO.removeRegularFile(at: temporaryURL)
                    throw CocoaError(.fileWriteNoPermission)
                }
            }.value
            fileImportNotice = "Queued \(sourceURL.lastPathComponent) for transcription."
            startTranscription(
                audioURL: temporaryURL,
                target: nil,
                // Diagnostics and the recovery journal must not leak the
                // original filename. The transcript history can still show
                // that this came from an import without storing document PII.
                deviceName: "Imported audio",
                recordingDuration: duration,
                interruption: nil,
                isImport: true
            )
        } catch MacImportedAudioError.fileTooLarge {
            fileImportNotice = "\(sourceURL.lastPathComponent) is larger than the 1 GB import limit."
        } catch {
            fileImportNotice = "Could not import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func testSelectedMicrophone() {
        guard
            !phase.isBusy,
            !microphoneTestState.isRunning,
            let device = selectedDevice
        else {
            return
        }
        microphoneTestTask = Task { [weak self] in
            await self?.runMicrophoneTest(device: device)
            self?.microphoneTestTask = nil
        }
    }

    private func runMicrophoneTest(device: MacAudioInputDevice) async {
        microphoneTestState = .connecting
        var testURL: URL?
        do {
            let startedAt = Date()
            _ = try await recorder.connect(deviceID: device.id)
            isMicrophoneConnected = true
            connectedDeviceID = device.id
            testURL = try await recorder.startSegment()
            microphoneTestState = .listening

            var peak: Double = 0
            var audibleSamples = 0
            let sampleCount = 40
            for _ in 0..<sampleCount {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(75))
                let level = recorder.normalizedLevel
                inputLevel = level
                peak = max(peak, level)
                if level > 0.012 { audibleSamples += 1 }
            }

            let segment = try await recorder.stop()
            isMicrophoneConnected = false
            connectedDeviceID = nil
            connectionLatency = nil
            resolveSelection()

            microphoneTestSound = NSSound(contentsOf: segment.url, byReference: false)
            try? FileManager.default.removeItem(at: segment.url)
            microphoneTestSound?.play()
            inputLevel = 0

            let audiblePercent = Int((Double(audibleSamples) / Double(sampleCount) * 100).rounded())
            let connection = Date().timeIntervalSince(startedAt) - 3
            if peak < 0.012 || audibleSamples == 0 {
                microphoneTestState = .failed("The stream worked, but it was silent. Check mute and input gain.")
            } else if peak > 0.96 {
                microphoneTestState = .succeeded(
                    "Audio works, but it is clipping. Peak 100% · sound in \(audiblePercent)% of samples."
                )
            } else {
                microphoneTestState = .succeeded(
                    String(
                        format: "Audio works · peak %.0f%% · sound in %d%% of samples · connected in %.1fs.",
                        peak * 100,
                        audiblePercent,
                        max(0, connection)
                    )
                )
            }
        } catch {
            recorder.disconnect()
            if let testURL { try? FileManager.default.removeItem(at: testURL) }
            isMicrophoneConnected = false
            connectedDeviceID = nil
            connectionLatency = nil
            inputLevel = 0
            resolveSelection()
            microphoneTestState = error is CancellationError
                ? .idle
                : .failed(diagnosticMessage(for: error))
        }
    }

    private func startRecording(requestID: UUID) async {
        guard captureRequestID == requestID, !Task.isCancelled else { return }
        guard let device = selectedDevice else {
            captureRequestID = nil
            captureStartTask = nil
            phase = .failed(
                deviceSelectionNotice
                    ?? "No microphone is selected. Open SpeakPaste and choose one."
            )
            return
        }
        guard hasAPIKey else {
            captureRequestID = nil
            captureStartTask = nil
            phase = .failed("Add your ElevenLabs API key before recording.")
            return
        }

        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        deliveryTarget = MacDeliveryTarget.captureCurrent(
            collectContext: shouldCollectDynamicContext(for: frontmostBundleIdentifier)
        )
        capturedContextTermCount = dynamicContextKeyterms(for: deliveryTarget).count

        do {
            let connectionStartedAt = Date()
            let createdConnection = try await recorder.connect(deviceID: device.id)
            guard captureRequestID == requestID, !Task.isCancelled else { return }
            if createdConnection {
                connectionLatency = Date().timeIntervalSince(connectionStartedAt)
            }
            isMicrophoneConnected = true
            connectedDeviceID = device.id
            _ = try await recorder.startSegment()
            guard captureRequestID == requestID, !Task.isCancelled else { return }
            recordingStartedAt = Date()
            elapsed = 0
            inputLevel = 0
            recordingWarning = nil
            automaticStopInProgress = false
            lastDeliveredSampleCount = recorder.deliveredSampleCount
            lastDeliveredSampleAt = Date()
            lastAudibleSampleAt = Date()
            captureRequestID = nil
            captureStartTask = nil
            phase = .recording
            beginRecordingActivity()
            sounds.playRecordingStarted()
            startMeter()
        } catch {
            guard captureRequestID == requestID else { return }
            captureRequestID = nil
            captureStartTask = nil
            isMicrophoneConnected = false
            connectedDeviceID = nil
            connectionLatency = nil
            recordFailure(diagnosticMessage(for: error), deviceName: device.name, recordingDuration: 0, transcriptionDuration: 0)
        }
    }

    private func stopAndTranscribe(interruption: String? = nil) async {
        defer { endRecordingActivity() }
        let deviceName = selectedDevice?.name ?? "Unknown microphone"
        let recordingDuration = Date().timeIntervalSince(recordingStartedAt ?? Date())

        let segment: MacRecordedSegment
        do {
            segment = try await recorder.stop()
        } catch {
            isMicrophoneConnected = false
            connectedDeviceID = nil
            connectionLatency = nil
            let resumesCapture = settleInputModeAfterFinalization()
            if let salvaged = error as? MacAudioRecorderSalvagedFailure {
                recordingWarning = nil
                automaticStopInProgress = false
                let target = deliveryTarget
                deliveryTarget = nil
                // Teardown completed before the recorder surfaced this error,
                // so the Continuity microphone is already free. Preserve and
                // transcribe the finalized portion instead of discarding all
                // speech because the tail of the file failed.
                phase = .ready
                let handoffIsDurable = startTranscription(
                    audioURL: salvaged.audioURL,
                    target: target,
                    deviceName: deviceName,
                    recordingDuration: recordingDuration,
                    interruption: interruption ?? diagnosticMessage(for: salvaged.underlying)
                )
                if resumesCapture, handoffIsDurable { beginRecordingRequest() }
                return
            }
            deliveryTarget = nil
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
        let resumesCapture = settleInputModeAfterFinalization()

        // The microphone is released and the audio is on disk, so this dictation
        // no longer needs anything the next one wants. Hand it to a background
        // job and return to ready immediately: the user can start speaking again
        // right now instead of watching a spinner.
        recordingWarning = nil
        automaticStopInProgress = false
        phase = .ready
        let target = deliveryTarget
        deliveryTarget = nil
        let handoffIsDurable = startTranscription(
            audioURL: segment.url,
            target: target,
            deviceName: deviceName,
            recordingDuration: recordingDuration,
            interruption: interruption
        )
        // Do not let a later segment overtake speech that failed to enter the
        // private recovery journal. The selected mode remains sticky, but the
        // user sees and resolves the first segment's failure before recording
        // continues.
        if resumesCapture, handoffIsDurable { beginRecordingRequest() }
    }

    /// Applies a deferred source switch only after the recorder's `stop()` has
    /// synchronously released its AVCaptureSession. Returns whether capture
    /// should resume as the next ordered segment.
    private func settleInputModeAfterFinalization() -> Bool {
        guard let targetMode = pendingInputModeAfterFinalization else {
            resolveSelection()
            return false
        }
        pendingInputModeAfterFinalization = nil
        guard let targetDevice = availableDevice(for: targetMode) else {
            resolveSelection()
            deviceSelectionNotice = unavailableMessage(for: targetMode)
            return false
        }
        selectDevice(targetDevice, semanticMode: targetMode)
        return true
    }

    @discardableResult
    private func startTranscription(
        audioURL: URL,
        target: MacDeliveryTarget?,
        deviceName: String,
        recordingDuration: TimeInterval,
        interruption: String?,
        existingRecordID: UUID? = nil,
        isImport: Bool = false,
        requiresManualOutput: Bool = false
    ) -> Bool {
        let record: MacPendingAudioRecord
        do {
            if let existingRecordID {
                record = try pendingAudioStore.markTranscribing(existingRecordID)
            } else {
                record = try pendingAudioStore.stage(
                    sourceURL: audioURL,
                    id: MacActiveCaptureRecovery.captureID(
                        forFileName: audioURL.lastPathComponent
                    ) ?? UUID(),
                    deviceName: deviceName,
                    recordingDuration: recordingDuration,
                    interruptionReason: interruption
                )
            }
        } catch {
            recoveryNotice = "Could not journal the recording safely: \(error.localizedDescription)"
            recordCompletedFailure(
                "The recording was not sent because SpeakPaste could not save its recovery entry. \(error.localizedDescription)",
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: 0
            )
            return false
        }
        guard let durableAudioURL = try? pendingAudioStore.audioURL(for: record) else {
            recordCompletedFailure(
                "The recording was journaled with an unsafe path and was not sent.",
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: 0
            )
            return false
        }
        retryableFailures.removeAll { $0.id == record.id }
        if !networkIsAvailable {
            let reason = Self.offlineRetryReason
            let queued = queuePendingAudioForRetry(
                recordID: record.id,
                target: target,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                reason: reason,
                retriesOnReconnect: true,
                requiresManualOutput: true
            )
            if queued {
                reconnectRetryIDs.insert(record.id)
                recoveryNotice = "You're offline. The recording is saved and will retry automatically when the connection returns."
            } else {
                recoveryNotice = "You're offline. The private audio journal will be rescanned on the next launch because its visible retry entry could not be confirmed."
            }
            return queued
        }
        reconnectRetryIDs.remove(record.id)
        let networkGenerationAtRequestStart = networkPathGeneration
        let sequence: Int?
        if isImport || requiresManualOutput {
            sequence = nil
        } else {
            sequence = nextSpeakSequence
            nextSpeakSequence += 1
        }
        inFlightCount += 1
        Task { [weak self] in
            await self?.transcribe(
                sequence: sequence,
                recordID: record.id,
                createdAt: record.createdAt,
                audioURL: durableAudioURL,
                target: target,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                interruption: interruption,
                isImport: isImport,
                requiresManualOutput: requiresManualOutput,
                networkGenerationAtRequestStart: networkGenerationAtRequestStart
            )
        }
        return true
    }

    /// Transcribes one dictation. Several of these can be in flight at once;
    /// each takes a ticket so delivery still happens in spoken order. When
    /// `interruption` is set, the audio is a partial dictation salvaged from a
    /// stream that died mid-recording; the attempt is logged as a failure but
    /// the text the user already spoke is still delivered.
    private func transcribe(
        sequence: Int?,
        recordID: UUID,
        createdAt: Date,
        audioURL: URL,
        target: MacDeliveryTarget?,
        deviceName: String,
        recordingDuration: TimeInterval,
        interruption: String?,
        isImport: Bool,
        requiresManualOutput: Bool,
        networkGenerationAtRequestStart: UInt64
    ) async {
        defer { inFlightCount = max(0, inFlightCount - 1) }
        do {
            guard let apiKey = resolvedAPIKey else {
                throw ElevenLabsClientError.api(statusCode: 401, message: "ElevenLabs API key is missing.")
            }

            let transcriptionStartedAt = Date()
            let requestedLanguage = language
            let result = try await client.transcribe(
                audioURL: audioURL,
                apiKey: apiKey,
                language: requestedLanguage,
                cleanSpeech: cleanSpeech,
                keyterms: requestKeyterms(for: target)
            )
            let processed = MacTranscriptPostProcessor.apply(
                result.text,
                replacements: replacements.replacements,
                precedingText: isImport || requiresManualOutput
                    ? nil
                    : (autoPaste ? target?.precedingText : nil),
                spokenFormattingCommands: spokenFormattingCommands
            )
            guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ElevenLabsClientError.emptyTranscript
            }

            // Commit the recoverable text before deleting its only audio. If
            // the process dies after this point, History still has the exact
            // post-processed transcript. If History cannot commit, the audio
            // remains journaled and retryable instead.
            let proposedHistoryRecordID = UUID()
            var retainedAudioFileName: String?
            let audioRetentionGeneration = successfulAudioRetentionGeneration
            if keepsSuccessfulHistoryAudio {
                do {
                    let audioStore = historyAudioStore
                    retainedAudioFileName = try await Task.detached(priority: .utility) {
                        try audioStore.retain(
                            sourceURL: audioURL,
                            historyRecordID: proposedHistoryRecordID
                        )
                    }.value
                } catch {
                    recoveryNotice = "The transcript can still be saved, but its original audio could not be retained for playback: \(error.localizedDescription)"
                }
            }
            // The copy happens off the main actor. A Never Store or retained-
            // audio privacy action can therefore run while it owns the store
            // lock. Never append a stale reference after that action: delete
            // the just-finished copy (or leave it unreferenced and report the
            // cleanup failure so launch reconciliation can retry it).
            if let copiedFileName = retainedAudioFileName,
               audioRetentionGeneration != successfulAudioRetentionGeneration
                    || !keepsSuccessfulHistoryAudio {
                if !historyAudioStore.remove(copiedFileName) {
                    recoveryNotice = "A retained-audio privacy change took effect, but a just-finished private copy could not be removed: \(historyAudioStore.lastPersistenceError ?? "the audio file could not be updated")"
                }
                retainedAudioFileName = nil
            }
            let historyRecord = MacTranscriptRecord(
                id: proposedHistoryRecordID,
                createdAt: createdAt,
                text: processed,
                destination: isImport ? "Imported audio" : target?.applicationName,
                deviceName: isImport ? "Imported audio" : deviceName,
                recordingDuration: recordingDuration,
                retainedAudioFileName: retainedAudioFileName,
                sourcePendingAudioID: recordID
            )
            var historyRecordID: UUID?
            var deliveryEscrowID: UUID?
            if history.append(historyRecord) {
                // Keep the row identity even when the following escrow commit
                // fails. Copy can then repair that exact source-linked handoff
                // instead of treating nil escrow as permission to bypass it.
                historyRecordID = historyRecord.id
                if let retainedAudioFileName,
                   !historyAudioStore.publish(retainedAudioFileName) {
                    let repaired = history.clearRetainedAudioReference(
                        for: historyRecord.id
                    )
                    self.retainedAudioPublicationFailure(
                        repairedHistory: repaired,
                        detail: historyAudioStore.lastPersistenceError
                    )
                }

                do {
                    // Every transcript gets a temporary durable delivery
                    // escrow, not just Never Store. That keeps an old retry or
                    // import safe even if age/count retention removes its
                    // History row before delivery begins, and makes every
                    // possible external paste crash-ambiguous rather than
                    // silently replayable.
                    deliveryEscrowID = try MacHistoryDeliveryEscrow.commit(
                        historyRecord,
                        destinationBundleIdentifier: target?.bundleIdentifier,
                        to: pendingTranscriptStore
                    ).id
                } catch {
                    // Keep both source-linked proofs intact. History and the
                    // recovery audio remain available, but no external output
                    // may happen without durable delivery ownership.
                    recoveryNotice = "SpeakPaste could not save the transcript's delivery handoff, so it was not output. History and recovery audio remain preserved: \(error.localizedDescription)"
                }

                // First commit a consumed marker linked to History, then clean
                // up audio. Even if either journal write fails, this recording
                // is no longer eligible for retry or a second delivery.
                if deliveryEscrowID != nil {
                    do {
                        _ = try pendingAudioStore.markCompleted(
                            recordID,
                            historyRecordID: historyRecord.id
                        )
                        if history.clearSourcePendingAudioLinks([recordID]) {
                            try pendingAudioStore.finishCompletedCleanup(
                                authorizedPendingAudioIDs: [recordID]
                            )
                            if !history.applyAutomaticLimits() {
                                recoveryNotice = "The transcript is safe, but History retention could not finish: \(history.lastPersistenceError ?? "the History file could not be written")"
                            }
                            if !history.records.contains(where: { $0.id == historyRecord.id }) {
                                historyRecordID = nil
                            }
                        } else {
                            recoveryNotice = "The transcript and its completion marker are safe, but History could not finish cleanup: \(history.lastPersistenceError ?? "the History file could not be written")"
                        }
                    } catch {
                        let durableLocation = deliveryEscrowID == nil
                            ? "History"
                            : "the pending delivery queue"
                        recoveryNotice = "The transcript is safe in \(durableLocation), but its recovery audio could not be cleaned up: \(error.localizedDescription)"
                    }
                    retryableFailures.removeAll { $0.id == recordID }
                }
            } else {
                historyRecordID = nil
                if let retainedAudioFileName {
                    _ = historyAudioStore.remove(retainedAudioFileName)
                }
                let persistenceDetail = history.lastPersistenceError
                    ?? "the history file could not be written"
                let reason = "Transcription completed, but History could not save it: \(persistenceDetail)"
                if queuePendingAudioForRetry(
                    recordID: recordID,
                    target: target,
                    deviceName: deviceName,
                    recordingDuration: recordingDuration,
                    reason: reason,
                    retriesOnReconnect: false,
                    requiresManualOutput: requiresManualOutput
                ) {
                    recoveryNotice = "\(reason) The recording was kept for retry."
                } else {
                    recoveryNotice = "\(reason) The private audio journal will be rescanned on next launch."
                }
            }
            let finished = MacFinishedDictation(
                text: processed,
                historyRecordID: historyRecordID,
                deliveryEscrowID: deliveryEscrowID,
                createdAt: createdAt,
                target: target,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: Date().timeIntervalSince(transcriptionStartedAt),
                interruption: interruption,
                languageConfidenceNotice: MacLanguageConfidenceReview.notice(
                    isAutomatic: requestedLanguage == .automatic,
                    languageTitle: result.languageCode.flatMap {
                        TranscriptionLanguage.title(forAPICode: $0)
                    },
                    probability: result.languageProbability
                )
            )
            if isImport || requiresManualOutput {
                finishManualOutputDictation(finished, isImport: isImport)
            } else if let sequence {
                completedDictations[sequence] = finished
                await drainCompletedDictations()
            }
        } catch {
            let connectivityFailure = isConnectivityFailure(error)
            var reason = connectivityFailure
                ? "\(Self.connectivityRetryReason) \(diagnosticMessage(for: error))"
                : diagnosticMessage(for: error)
            // The service's ability to retry automatically and the user's
            // right to keep recorded speech are separate decisions. Preserve
            // every existing recording — including auth/request/no-speech
            // failures — so a corrected key or setting can recover it later.
            if queuePendingAudioForRetry(
                recordID: recordID,
                target: target,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                reason: reason,
                retriesOnReconnect: connectivityFailure,
                requiresManualOutput: requiresManualOutput || connectivityFailure
            ) {
                reason += " The recording was kept for retry."
                if connectivityFailure {
                    reconnectRetryIDs.insert(recordID)
                    recoveryNotice = "A connection problem stopped this transcription. The recording is saved and will retry after the next connection recovery; its transcript will wait for manual placement."
                } else {
                    recoveryNotice = "Transcription failed, but the recording is saved for an explicit Retry."
                }
            } else {
                reason += " SpeakPaste could not confirm the recovery index; the private audio journal will be rescanned on next launch."
                recoveryNotice = "A failed recording needs journal recovery on the next launch."
            }
            // A failed dictation must not stall the ones spoken after it.
            let failed = MacFinishedDictation(
                text: "",
                historyRecordID: nil,
                deliveryEscrowID: nil,
                createdAt: createdAt,
                target: target,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: 0,
                interruption: reason,
                languageConfidenceNotice: nil
            )
            if isImport || requiresManualOutput {
                recordCompletedFailure(
                    reason,
                    deviceName: deviceName,
                    recordingDuration: recordingDuration,
                    transcriptionDuration: 0
                )
            } else if let sequence {
                completedDictations[sequence] = failed
                await drainCompletedDictations()
            }
            // The path can recover while URLSession is still unwinding its
            // final failed attempt. In that ordering the path callback had no
            // queued ID to wake. Retry once for that newer generation; a
            // second failure starts in the new generation and cannot loop.
            if connectivityFailure,
               networkIsAvailable,
               networkPathGeneration > networkGenerationAtRequestStart {
                retryConnectivityFailures(
                    matching: Set([recordID]),
                    notice: "Connection returned while the request was finishing. Retrying the saved recording for manual placement."
                )
            }
        }
    }

    /// Moves a journaled recording back to the visible retry queue without
    /// ever trusting a raw path supplied by the caller.
    @discardableResult
    private func queuePendingAudioForRetry(
        recordID: UUID,
        target: MacDeliveryTarget?,
        deviceName: String,
        recordingDuration: TimeInterval,
        reason: String,
        retriesOnReconnect: Bool,
        requiresManualOutput: Bool
    ) -> Bool {
        let waitingRecord = try? pendingAudioStore.markWaiting(
            recordID,
            reason: reason,
            retryOnReconnect: retriesOnReconnect
        )
        guard
            let stored = waitingRecord ?? pendingAudioStore.record(withID: recordID),
            stored.status == .waiting,
            let durableAudioURL = try? pendingAudioStore.audioURL(for: stored)
        else {
            return false
        }
        retryableFailures.removeAll { $0.id == recordID }
        retryableFailures.append(
            MacRetryableDictation(
                id: recordID,
                audioURL: durableAudioURL,
                target: target,
                requiresManualOutput: requiresManualOutput,
                retriesOnReconnect: retriesOnReconnect,
                interruptionReason: stored.interruptionReason,
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                reason: reason,
                createdAt: stored.createdAt
            )
        )
        return true
    }

    private func isConnectivityFailure(_ error: Error) -> Bool {
        // The current path is only a preflight signal. It must never override
        // a concrete API/no-speech classification: a 401 received as Wi-Fi
        // drops is still an authentication failure, not permission to retry
        // automatically on the next path transition.
        if let clientError = error as? ElevenLabsClientError {
            return clientError.category == .network
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private func requestKeyterms(for target: MacDeliveryTarget?) -> [String] {
        let dynamic = dynamicContextKeyterms(for: target)
        var seen = Set<String>()
        // App- and caret-local names are the most specific hints for this one
        // dictation, so they receive the finite Scribe slots before the global
        // vocabulary. A full 1,000-term list must not silently suppress every
        // context hint while the UI claims context awareness is active.
        return (dynamic + vocabulary.keytermsForRequest)
            .compactMap { candidate -> String? in
                let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard MacVocabularyStore.validationFailure(for: term) == nil else {
                    return nil
                }
                guard seen.insert(term.lowercased()).inserted else { return nil }
                return term
            }
            .prefix(MacVocabularyStore.maximumTerms)
            .map { $0 }
    }

    private func dynamicContextKeyterms(for target: MacDeliveryTarget?) -> [String] {
        shouldCollectDynamicContext(for: target?.bundleIdentifier)
            ? target?.contextKeyterms ?? []
            : []
    }

    private func shouldCollectDynamicContext(for bundleIdentifier: String?) -> Bool {
        if let bundleIdentifier,
           let configured = deliveryPolicies.configuredPolicy(for: bundleIdentifier) {
            return configured.contextKeyterms
        }
        return contextAwareness
    }

    @discardableResult
    func retry(_ failure: MacRetryableDictation) -> Bool {
        guard !hasSourceLinkedHistory(forPendingAudioID: failure.id) else {
            retryableFailures.removeAll { $0.id == failure.id }
            reconnectRetryIDs.remove(failure.id)
            recoveryNotice = "That recording already produced a transcript. Retry is paused until its saved delivery handoff is resolved."
            return false
        }
        guard let record = pendingAudioStore.record(withID: failure.id) else {
            recoveryNotice = "That recording is no longer present in the recovery journal."
            return false
        }
        guard record.status == .waiting else {
            recoveryNotice = "That recording is already being transcribed."
            return false
        }
        return startTranscription(
            audioURL: failure.audioURL,
            target: failure.target,
            deviceName: failure.deviceName,
            recordingDuration: failure.recordingDuration,
            interruption: failure.interruptionReason,
            existingRecordID: failure.id,
            isImport: failure.deviceName == "Imported audio",
            requiresManualOutput: failure.requiresManualOutput
        )
    }

    func retryAllFailures() {
        for failure in retryableFailures { retry(failure) }
    }

    func discardFailure(_ failure: MacRetryableDictation) {
        guard !hasSourceLinkedHistory(forPendingAudioID: failure.id) else {
            retryableFailures.removeAll { $0.id == failure.id }
            recoveryNotice = "That recording already produced a transcript and cannot be discarded from the retry queue until its delivery handoff is resolved."
            return
        }
        do {
            try pendingAudioStore.discardWaiting(failure.id)
            retryableFailures.removeAll { $0.id == failure.id }
            reconnectRetryIDs.remove(failure.id)
            recoveryNotice = "Discarded one saved recording."
        } catch MacPendingAudioStoreError.recordNotWaiting {
            recoveryNotice = "That recording is currently transcribing and cannot be discarded."
        } catch {
            recoveryNotice = "Could not discard the saved recording: \(error.localizedDescription)"
        }
    }

    /// Escape is the direct exit gesture: one press abandons connecting or the
    /// active recording immediately without transcription.
    func requestRecordingCancellation() {
        guard phase == .recording || phase == .connecting else { return }
        cancelRecording()
    }

    /// Abandons a recording in progress without transcribing it.
    func cancelRecording() {
        guard phase == .recording || phase == .connecting else { return }
        pendingInputModeAfterFinalization = nil
        captureRequestID = nil
        captureStartTask?.cancel()
        captureStartTask = nil
        stopMeter()
        recorder.disconnect()
        endRecordingActivity()
        isMicrophoneConnected = false
        connectedDeviceID = nil
        connectionLatency = nil
        deliveryTarget = nil
        recordingWarning = nil
        automaticStopInProgress = false
        phase = .ready
    }

    /// Delivers finished dictations strictly in spoken order, so a short second
    /// thought cannot overtake the sentence it belongs after.
    private func drainCompletedDictations() async {
        guard !isDrainingCompletedDictations else { return }
        isDrainingCompletedDictations = true
        defer { isDrainingCompletedDictations = false }
        while let finished = completedDictations[nextDeliverySequence] {
            completedDictations[nextDeliverySequence] = nil
            nextDeliverySequence += 1
            await deliver(finished)
        }
    }

    /// Imports are intentionally a manual-output lane. A long file must not
    /// hold up later live dictations, nor may it overwrite the clipboard or
    /// paste into whichever app happens to be active when processing finishes.
    private func finishManualOutputDictation(
        _ finished: MacFinishedDictation,
        isImport: Bool
    ) {
        originalTranscript = finished.text
        transcript = finished.text
        transcriptLearningNotice = nil
        lastHistoryRecordID = finished.historyRecordID
        lastTranscriptPendingID = finished.deliveryEscrowID
        lastTranscriptOutputIsResolved = false
        var pendingHandoffSaved = false
        if let deliveryEscrowID = finished.deliveryEscrowID,
           let pending = pendingTranscriptStore.transcript(withID: deliveryEscrowID),
           pending.text == finished.text {
            presentPendingTranscript(pending, target: nil)
            pendingHandoffSaved = true
        }
        let manualOutputIsReady = pendingHandoffSaved
        var detail: String
        let sourceLabel = isImport ? "Imported file" : "Saved recording"
        if pendingHandoffSaved, finished.historyRecordID == nil {
            detail = "\(sourceLabel) transcribed — ready for manual placement; its delivery copy remains until output is resolved"
        } else if pendingHandoffSaved, finished.historyRecordID != nil {
            detail = "\(sourceLabel) transcribed — ready in History for manual placement"
        } else if finished.historyRecordID != nil {
            detail = "\(sourceLabel) transcribed and preserved in History, but manual output is paused until its delivery handoff can be saved; recovery audio was kept"
        } else {
            detail = "\(sourceLabel) transcribed — visible now, but its durable recovery handoff could not finish; recovery audio was kept"
        }
        if let languageConfidenceNotice = finished.languageConfidenceNotice {
            detail += " \(languageConfidenceNotice)"
        }
        if let interruption = finished.interruption {
            detail += " Recording stopped early; only the captured portion was transcribed. \(interruption)"
        }
        let completedCleanly = manualOutputIsReady && finished.interruption == nil
        attempts = reliabilityStore.prepend(
            MacReliabilityAttempt(
                deviceName: finished.deviceName,
                recordingDuration: finished.recordingDuration,
                transcriptionDuration: finished.transcriptionDuration,
                outcome: completedCleanly ? .success : .failure,
                detail: detail
            )
        )
        if isImport {
            fileImportNotice = detail
        } else {
            recoveryNotice = detail
        }
        guard !phase.isBusy else { return }
        if completedCleanly {
            phase = .succeeded(detail)
            scheduleReadyReset()
        } else {
            sounds.playFailed()
            phase = .failed(detail)
        }
    }

    private func deliver(_ finished: MacFinishedDictation) async {
        guard !finished.text.isEmpty else {
            recordCompletedFailure(
                finished.interruption ?? "Transcription failed.",
                deviceName: finished.deviceName,
                recordingDuration: finished.recordingDuration,
                transcriptionDuration: 0
            )
            return
        }

        // Post-processing and a durable text commit happened before recovery
        // audio was removed, so this is the exact recoverable delivery text.
        originalTranscript = finished.text
        transcript = finished.text
        transcriptLearningNotice = nil
        lastHistoryRecordID = finished.historyRecordID
        lastTranscriptPendingID = finished.deliveryEscrowID
        lastTranscriptOutputIsResolved = false
        guard let deliveryEscrowID = finished.deliveryEscrowID else {
            // The audio is visible in the retry queue. Do not paste or press
            // Return before its text is durable: retrying a failed commit must
            // not duplicate a message that was already delivered.
            var detail = "Transcribed, but not delivered because its durable recovery handoff could not finish. Recovery data was preserved."
            if let languageConfidenceNotice = finished.languageConfidenceNotice {
                detail += " \(languageConfidenceNotice)"
            }
            attempts = reliabilityStore.prepend(
                MacReliabilityAttempt(
                    deviceName: finished.deviceName,
                    recordingDuration: finished.recordingDuration,
                    transcriptionDuration: finished.transcriptionDuration,
                    outcome: .failure,
                    detail: detail
                )
            )
            guard !phase.isBusy else { return }
            sounds.playFailed()
            phase = .failed(detail)
            return
        }
        if pendingTranscriptStore.transcript(withID: deliveryEscrowID) == nil {
            if explicitlyResolvedDeliveryEscrowIDs.remove(deliveryEscrowID) != nil {
                if lastTranscriptPendingID == deliveryEscrowID {
                    lastTranscriptPendingID = nil
                    lastTranscriptOutputIsResolved = true
                }
                var detail = "Transcribed and copied explicitly before automatic delivery"
                if let languageConfidenceNotice = finished.languageConfidenceNotice {
                    detail += ". \(languageConfidenceNotice)"
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
                guard !phase.isBusy else { return }
                phase = .succeeded(detail)
                scheduleReadyReset()
                return
            }
            let detail = "Transcribed, but not delivered because its durable recovery handoff disappeared unexpectedly. History was preserved when configured."
            recordCompletedFailure(
                detail,
                deviceName: finished.deviceName,
                recordingDuration: finished.recordingDuration,
                transcriptionDuration: finished.transcriptionDuration
            )
            return
        }
        if let pending = pendingTranscriptStore.transcript(withID: deliveryEscrowID),
           pending.deliveryState == .deliveryUncertain {
            presentPendingTranscript(pending, target: finished.target)
            suspendedAutomaticHeldIDs.insert(deliveryEscrowID)
            let detail = "Automatic delivery was blocked because this transcript is already marked as possibly delivered. Review the waiting copy before any retry."
            recordCompletedFailure(
                detail,
                deviceName: finished.deviceName,
                recordingDuration: finished.recordingDuration,
                transcriptionDuration: finished.transcriptionDuration
            )
            return
        }
        guard ensureSourceRecoveryIsUnlinked(for: Set([deliveryEscrowID])) else {
            if let pending = pendingTranscriptStore.transcript(withID: deliveryEscrowID) {
                presentPendingTranscript(pending, target: nil)
            }
            let detail = "Transcribed, but output is paused until SpeakPaste can finish unlinking its source-audio recovery proof. The text and audio remain preserved."
            recordCompletedFailure(
                detail,
                deviceName: finished.deviceName,
                recordingDuration: finished.recordingDuration,
                transcriptionDuration: finished.transcriptionDuration
            )
            return
        }
        // Every route can change the clipboard, including manual/clipboard-only
        // mode and fallbacks that cannot paste. Persist ambiguity before calling
        // the controller; definite no-output outcomes restore pending below.
        if !beginDeliveryEscrowAttempt(finished.deliveryEscrowID) {
            if let escrowID = finished.deliveryEscrowID,
               let pending = pendingTranscriptStore.transcript(withID: escrowID) {
                presentPendingTranscript(pending, target: nil)
            }
            var detail = "Transcribed, but paste was blocked because its recovery handoff could not be marked safely. Use Copy or Discard from the waiting-text banner."
            if let languageConfidenceNotice = finished.languageConfidenceNotice {
                detail += " \(languageConfidenceNotice)"
            }
            attempts = reliabilityStore.prepend(
                MacReliabilityAttempt(
                    deviceName: finished.deviceName,
                    recordingDuration: finished.recordingDuration,
                    transcriptionDuration: finished.transcriptionDuration,
                    outcome: .failure,
                    detail: detail
                )
            )
            guard !phase.isBusy else { return }
            sounds.playFailed()
            phase = .failed(detail)
            return
        }
        activeDeliveryEscrowIDs.insert(deliveryEscrowID)
        let delivery = await pasteController.deliver(
            finished.text,
            to: finished.target,
            autoPaste: autoPaste,
            policy: deliveryPolicy(for: finished.target)
        )
        activeDeliveryEscrowIDs.remove(deliveryEscrowID)
        var detail = delivery.detail
        if case let .held(reason) = delivery, let target = finished.target {
            restoreDeliveryEscrowPending(finished.deliveryEscrowID)
            sounds.playHeld()
            hold(
                finished.text,
                for: target,
                pendingID: finished.deliveryEscrowID,
                createdAt: finished.createdAt
            )
            detail = "Held for \(target.applicationName) — \(reason.explanation)"
        } else if case .pasted(_, verified: false) = delivery,
                  let escrowID = finished.deliveryEscrowID,
                  let pending = pendingTranscriptStore.transcript(withID: escrowID) {
            // The side effect may already have happened. Keep the durable
            // uncertain escrow visible and refuse every implicit retry.
            presentPendingTranscript(pending, target: finished.target)
            suspendedAutomaticHeldIDs.insert(escrowID)
            detail = "\(delivery.detail); recovery copy marked as possibly delivered"
        } else if case .clipboardFailed = delivery,
                  let escrowID = finished.deliveryEscrowID {
            // No external insertion was attempted successfully, so an escrow
            // marked uncertain before the delivery gate can safely return to
            // pending. The clipboard failure itself remains visible.
            restoreDeliveryEscrowPending(escrowID)
            if let restored = pendingTranscriptStore.transcript(withID: escrowID) {
                presentPendingTranscript(restored, target: finished.target)
            }
            detail = delivery.detail
        } else {
            finishDeliveryEscrow(finished.deliveryEscrowID)
            if let target = finished.target {
            // Naming the destination and the route makes the attempt log the
            // record of where each dictation actually went.
                detail = "\(delivery.detail) → \(target.applicationName)"
            }
        }
        if let languageConfidenceNotice = finished.languageConfidenceNotice {
            detail += " \(languageConfidenceNotice)"
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
            // A completed background job never owns the live capture phase. If
            // the user is already speaking the next dictation, replacing
            // Listening with an older failure also stops the live meter and makes the
            // second Command press look broken.
            if !phase.isBusy {
                sounds.playFailed()
                phase = .failed("Recording stopped early — the dictation captured so far was still transcribed. \(detail).")
            }
            return
        }

        if delivery.requiresDeliveryAttention {
            attempts = reliabilityStore.prepend(
                MacReliabilityAttempt(
                    deviceName: finished.deviceName,
                    recordingDuration: finished.recordingDuration,
                    transcriptionDuration: finished.transcriptionDuration,
                    outcome: .failure,
                    detail: detail
                )
            )
            guard !phase.isBusy else { return }
            sounds.playFailed()
            phase = .failed(detail)
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
        // result. The microphone owns the capture phase while it is running.
        guard !phase.isBusy else { return }
        if delivery.isDelivered { sounds.playDelivered() }
        phase = .succeeded(detail)
        scheduleReadyReset()
    }

    @discardableResult
    func copyText(
        _ text: String,
        resolvingPendingID: UUID? = nil,
        requiresDurableResolution: Bool = false
    ) -> Bool {
        let requestedIDs = resolvingPendingID.map { Set([$0]) } ?? []
        guard let durableIDs = prepareDeliveryEscrows(for: requestedIDs) else {
            return false
        }
        guard !requiresDurableResolution || !durableIDs.isEmpty else {
            recoveryNotice = "Copy is paused because this transcript's delivery ownership could not be proven. Its saved recovery data remains untouched."
            return false
        }
        guard activeDeliveryEscrowIDs.isEmpty else {
            recoveryNotice = "Another transcript is currently being delivered. Wait for it to finish before changing the clipboard."
            // Never materialize a second in-memory copy of the escrow that is
            // itself crossing the output boundary. Its owning delivery path
            // will surface it if that attempt fails or becomes uncertain.
            presentDeliveryEscrows(
                durableIDs.subtracting(activeDeliveryEscrowIDs)
            )
            return false
        }
        guard ensureSourceRecoveryIsUnlinked(for: durableIDs) else {
            for id in durableIDs {
                if let pending = pendingTranscriptStore.transcript(withID: id) {
                    presentPendingTranscript(pending, target: nil)
                }
            }
            return false
        }
        let resolvesCurrentLast = !lastTranscriptOutputIsResolved
            && requestedIDs.contains(where: { id in
                id == lastTranscriptPendingID || id == lastHistoryRecordID
            })
        let originallyPendingIDs = Set(durableIDs.filter {
            pendingTranscriptStore.transcript(withID: $0)?.deliveryState == .pending
        })
        if !durableIDs.isEmpty,
           !markHeldDeliveryUncertain(durableIDs) {
            presentDeliveryEscrows(durableIDs)
            return false
        }
        guard pasteController.copyToPasteboardIfIdle(text) else {
            restoreHeldDeliveryPending(originallyPendingIDs)
            presentDeliveryEscrows(durableIDs)
            recoveryNotice = "The clipboard refused the transcript. The original remains in History or the waiting-text queue."
            if !phase.isBusy {
                phase = .failed("Could not copy the transcript to the clipboard.")
            }
            return false
        }

        guard !durableIDs.isEmpty else { return true }
        let visibleIDs = Set(heldTranscripts.map(\.id))
        let removed = removeDeliveredHeldTranscripts(durableIDs)
        heldTranscripts.removeAll { removed.contains($0.id) }
        suspendedAutomaticHeldIDs.subtract(removed)
        explicitlyResolvedDeliveryEscrowIDs.formUnion(
            removed.subtracting(visibleIDs)
        )
        if heldTranscripts.isEmpty { stopPendingWatcher() }
        if removed == durableIDs {
            if resolvesCurrentLast {
                lastTranscriptOutputIsResolved = true
            }
            recoveryNotice = durableIDs.count == 1
                ? "Copied the transcript and resolved its waiting recovery entry."
                : "Copied the waiting transcripts and resolved their recovery entries."
        } else {
            for id in durableIDs.subtracting(removed) {
                if let pending = pendingTranscriptStore.transcript(withID: id) {
                    presentPendingTranscript(pending, target: nil)
                }
            }
            recoveryNotice = "The transcript was copied, but its recovery entry could not be cleared. It remains marked as possibly delivered."
        }
        return true
    }

    /// Turns a source-linked History row into a durable output escrow on demand.
    /// This closes the failure path where History committed but the original
    /// escrow write did not: explicit Copy may repair that handoff, but it may
    /// never bypass it and leave the same audio eligible for a later retry.
    private func prepareDeliveryEscrows(
        for requestedIDs: Set<UUID>
    ) -> Set<UUID>? {
        guard !requestedIDs.isEmpty else { return [] }
        guard requestedIDs.isDisjoint(with: suppressedDuplicateDeliveryEscrowIDs) else {
            recoveryNotice = "Copy is paused because this row duplicates another transcript recovered from the same recording. The saved History rows remain available for review."
            return nil
        }
        var durableIDs = Set(requestedIDs.filter {
            pendingTranscriptStore.transcript(withID: $0) != nil
        })
        for id in durableIDs {
            guard let record = history.records.first(where: {
                $0.id == id && $0.sourcePendingAudioID != nil
            }) else {
                continue
            }
            guard
                let pending = pendingTranscriptStore.transcript(withID: id),
                pending.text == record.text,
                pending.createdAt == record.createdAt
            else {
                recoveryNotice = "Copy is paused because the delivery handoff does not exactly match its source-linked History proof. No clipboard data was changed."
                return nil
            }
        }

        for id in requestedIDs.subtracting(durableIDs) {
            guard let record = history.records.first(where: { $0.id == id }) else {
                if !history.isPendingAudioRecoveryAuthorityTrusted {
                    recoveryNotice = "Copy is paused because History could not prove this transcript's recovery state. No clipboard data was changed."
                    return nil
                }
                continue
            }
            guard record.sourcePendingAudioID != nil else { continue }
            guard history.isPendingAudioRecoveryAuthorityTrusted else {
                recoveryNotice = "Copy is paused because History is not safe to update. The transcript and its recovery audio remain untouched."
                return nil
            }
            do {
                let pending = try MacHistoryDeliveryEscrow.commit(
                    record,
                    to: pendingTranscriptStore
                )
                durableIDs.insert(pending.id)
                if !lastTranscriptOutputIsResolved,
                   lastHistoryRecordID == pending.id,
                   lastTranscriptPendingID == nil {
                    lastTranscriptPendingID = pending.id
                }
            } catch {
                recoveryNotice = "Copy is paused because the transcript's delivery handoff could not be saved. History and recovery audio remain preserved: \(error.localizedDescription)"
                return nil
            }
        }
        return durableIDs
    }

    // MARK: Held transcripts

    private func hold(
        _ text: String,
        for target: MacDeliveryTarget,
        pendingID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        let pending: MacPendingTranscript
        var needsPersistence = true
        if let pendingID,
           let existing = pendingTranscriptStore.transcript(withID: pendingID),
           existing.text == text {
            pending = existing
            needsPersistence = false
        } else {
            pending = MacPendingTranscript(
                id: pendingID ?? UUID(),
                text: text,
                destinationApplicationName: target.applicationName,
                destinationBundleIdentifier: target.bundleIdentifier,
                createdAt: createdAt
            )
        }
        if needsPersistence {
            do {
                try pendingTranscriptStore.upsert(pending)
            } catch {
                // Keep an in-memory and clipboard copy even when disk
                // persistence fails, but do not claim crash-safe recovery.
                let copied = pasteController.copyToPasteboardIfIdle(text)
                recoveryNotice = copied
                    ? "Held text is safe for this session and on the clipboard, but could not be saved to disk: \(error.localizedDescription)"
                    : "Held text is visible for this session, but neither its disk recovery entry nor clipboard copy could be saved: \(error.localizedDescription)"
            }
        }
        presentPendingTranscript(pending, target: target)
    }

    private func presentPendingTranscript(
        _ pending: MacPendingTranscript,
        target: MacDeliveryTarget?
    ) {
        if let index = heldTranscripts.firstIndex(where: { $0.id == pending.id }) {
            heldTranscripts[index].deliveryState = pending.deliveryState
            return
        }
        armedUncertainPasteIDs.removeAll()
        heldTranscripts.append(
            MacHeldTranscript(
                id: pending.id,
                text: pending.text,
                target: target,
                destinationApplicationName: pending.destinationApplicationName,
                destinationBundleIdentifier: pending.destinationBundleIdentifier,
                createdAt: pending.createdAt,
                deliveryState: pending.deliveryState
            )
        )
        if target != nil { startPendingWatcher() }
    }

    /// Re-read durable state rather than presenting a stale value captured
    /// before a failed write/reset. Every blocked clipboard path leaves the
    /// exact recovery entries visible for explicit review.
    private func presentDeliveryEscrows(_ identifiers: Set<UUID>) {
        for id in identifiers {
            if let pending = pendingTranscriptStore.transcript(withID: id) {
                presentPendingTranscript(pending, target: nil)
            }
        }
    }

    @discardableResult
    private func finishDeliveryEscrow(_ id: UUID?) -> Bool {
        guard let id else { return false }
        do {
            guard try pendingTranscriptStore.remove(id) else {
                // This runs only after the output result succeeded and after
                // source-audio recovery was unlinked. An already-absent escrow
                // is therefore idempotent cleanup, not a reason to strand the
                // visible transcript permanently read-only.
                if lastTranscriptPendingID == id {
                    lastTranscriptPendingID = nil
                    lastTranscriptOutputIsResolved = true
                }
                heldTranscripts.removeAll { $0.id == id }
                suspendedAutomaticHeldIDs.remove(id)
                armedUncertainPasteIDs.removeAll()
                if heldTranscripts.isEmpty { stopPendingWatcher() }
                recoveryNotice = "The transcript was output; its recovery entry had already been cleared."
                return true
            }
            if lastTranscriptPendingID == id {
                lastTranscriptPendingID = nil
                lastTranscriptOutputIsResolved = true
            }
            heldTranscripts.removeAll { $0.id == id }
            suspendedAutomaticHeldIDs.remove(id)
            armedUncertainPasteIDs.removeAll()
            if heldTranscripts.isEmpty { stopPendingWatcher() }
            return true
        } catch {
            // The requested output already exists, so a stale escrow is a
            // recoverable duplicate-warning problem rather than data loss.
            if let pending = pendingTranscriptStore.transcript(withID: id) {
                presentPendingTranscript(pending, target: nil)
            }
            recoveryNotice = "The transcript was output, but its pending recovery entry could not be removed. It remains marked as possibly delivered: \(error.localizedDescription)"
            return false
        }
    }

    /// A source-linked History row is the durable cross-store proof that keeps
    /// a completed recording from being transcribed twice. Its delivery escrow
    /// must not be removed or output while that link remains: launch recovery
    /// would otherwise recreate a fresh pending escrow after the first output.
    /// Retry the completion transaction on demand and allow output as soon as
    /// the source link itself is durably gone; later audio-file cleanup may
    /// continue independently without duplicate-delivery risk.
    private func ensureSourceRecoveryIsUnlinked(
        for escrowIDs: Set<UUID>
    ) -> Bool {
        guard !escrowIDs.isEmpty else { return true }
        let durableEscrowIDs = Set(escrowIDs.filter {
            pendingTranscriptStore.transcript(withID: $0) != nil
        })
        guard !durableEscrowIDs.isEmpty else { return true }
        // An empty/partial History view is not evidence that no source link
        // exists when the document failed closed. Removing the escrow in that
        // state could let a later restored source-linked row recreate it.
        guard history.isPendingAudioRecoveryAuthorityTrusted else {
            recoveryNotice = "Output is paused because History is not safe to update. The transcript and its recovery data remain untouched."
            return false
        }
        let linkedRecords = history.records.filter {
            durableEscrowIDs.contains($0.id) && $0.sourcePendingAudioID != nil
        }
        guard !linkedRecords.isEmpty else { return true }
        for record in linkedRecords {
            guard
                let pending = pendingTranscriptStore.transcript(withID: record.id),
                pending.text == record.text,
                pending.createdAt == record.createdAt
            else {
                recoveryNotice = "Output is paused because the delivery handoff does not exactly match its source-linked History proof. No saved recovery data was changed."
                return false
            }
        }

        var historyByPendingAudioID: [UUID: UUID] = [:]
        for record in linkedRecords {
            guard let pendingAudioID = record.sourcePendingAudioID else { continue }
            if historyByPendingAudioID[pendingAudioID] == nil {
                historyByPendingAudioID[pendingAudioID] = record.id
            }
        }
        guard historyByPendingAudioID.count == linkedRecords.count else {
            recoveryNotice = "Output is paused because more than one requested transcript came from the same recording. Review the canonical waiting copy so the dictation can cross the output boundary only once."
            return false
        }
        let pendingAudioIDs = Set(historyByPendingAudioID.keys)
        // If an old affected build created several History rows and escrows for
        // one recording, exactly one may cross the output boundary. Retire any
        // exact sibling escrows before clearing the shared source link; otherwise
        // a hidden duplicate could reappear on the next launch and be pasted.
        let siblingRecords = history.records.filter { record in
            guard let pendingAudioID = record.sourcePendingAudioID else { return false }
            return pendingAudioIDs.contains(pendingAudioID)
                && !durableEscrowIDs.contains(record.id)
        }
        var siblingEscrowIDs = Set<UUID>()
        var uncertainSiblingSourceIDs = Set<UUID>()
        for record in siblingRecords {
            guard let sibling = pendingTranscriptStore.transcript(withID: record.id) else {
                continue
            }
            guard sibling.text == record.text, sibling.createdAt == record.createdAt else {
                recoveryNotice = "Output is paused because another recovery entry collides with a duplicate History row. No saved text was removed."
                return false
            }
            siblingEscrowIDs.insert(record.id)
            if sibling.deliveryState == .deliveryUncertain,
               let pendingAudioID = record.sourcePendingAudioID {
                uncertainSiblingSourceIDs.insert(pendingAudioID)
            }
        }
        guard activeDeliveryEscrowIDs.isDisjoint(with: siblingEscrowIDs) else {
            recoveryNotice = "Output is paused because a duplicate recovery entry is already being delivered."
            return false
        }
        do {
            let canonicalized = try MacHistoryDeliveryEscrow.canonicalize(
                linkedRecords,
                removing: siblingRecords,
                in: pendingTranscriptStore
            )
            let retiredSiblingIDs = Set(siblingRecords.map(\.id))
            suppressedDuplicateDeliveryEscrowIDs.subtract(retiredSiblingIDs)
            heldTranscripts.removeAll { retiredSiblingIDs.contains($0.id) }
            suspendedAutomaticHeldIDs.subtract(retiredSiblingIDs)
            armedUncertainPasteIDs.removeAll()

            // The action that entered this method was authorized against a
            // seemingly safe canonical row. If an old sibling carried an
            // uncertainty receipt, surface the transferred warning and make
            // the user review it before any copy/paste side effect proceeds.
            let transferred = canonicalized.filter { pending in
                guard pending.deliveryState == .deliveryUncertain else { return false }
                guard let record = linkedRecords.first(where: { $0.id == pending.id }) else {
                    return false
                }
                guard let pendingAudioID = record.sourcePendingAudioID else { return false }
                return uncertainSiblingSourceIDs.contains(pendingAudioID)
            }
            if !transferred.isEmpty {
                for pending in transferred {
                    presentPendingTranscript(pending, target: nil)
                    suspendedAutomaticHeldIDs.insert(pending.id)
                }
                recoveryNotice = "Output is paused because a duplicate recovery entry may already have been delivered. Review the canonical waiting transcript before Copy, Discard, or Paste Anyway."
                return false
            }
        } catch {
            recoveryNotice = "Output is paused because duplicate recovery entries could not be retired safely: \(error.localizedDescription)"
            return false
        }
        do {
            try pendingAudioStore.reconcileCompletedHistory(
                historyByPendingAudioID
            )
        } catch {
            recoveryNotice = "Output is paused because the completed recording could not be acknowledged safely. The transcript and audio remain preserved: \(error.localizedDescription)"
            return false
        }
        guard history.clearSourcePendingAudioLinks(pendingAudioIDs) else {
            recoveryNotice = "Output is paused because History could not finish its source-audio transaction. The transcript and audio remain preserved: \(history.lastPersistenceError ?? "the History file could not be written")"
            return false
        }

        do {
            try pendingAudioStore.finishCompletedCleanup(
                authorizedPendingAudioIDs: pendingAudioIDs
            )
        } catch {
            recoveryNotice = "The transcript is ready for output, but acknowledged recovery audio still awaits private cleanup: \(error.localizedDescription)"
        }
        if !history.applyAutomaticLimits() {
            recoveryNotice = "The transcript is ready for output, but History retention could not finish: \(history.lastPersistenceError ?? "the History file could not be written")"
        }
        if let lastHistoryRecordID,
           !history.records.contains(where: { $0.id == lastHistoryRecordID }) {
            self.lastHistoryRecordID = nil
        }
        return true
    }

    /// Persisting this marker before the first possible paste makes a process
    /// death at the side-effect boundary recover as "possibly delivered,"
    /// never as a safe automatic retry, under every History retention mode.
    private func beginDeliveryEscrowAttempt(_ id: UUID?) -> Bool {
        guard let id else { return true }
        guard let pending = pendingTranscriptStore.transcript(withID: id) else {
            recoveryNotice = "Could not find the delivery handoff, so paste was blocked."
            return false
        }
        guard pending.deliveryState == .pending else {
            recoveryNotice = "Paste was blocked because this transcript is already marked as possibly delivered. Review it in the waiting-text banner."
            return false
        }
        do {
            try pendingTranscriptStore.setDeliveryState(.deliveryUncertain, for: Set([id]))
            return true
        } catch {
            recoveryNotice = "Could not mark the delivery handoff safely, so paste was blocked: \(error.localizedDescription)"
            return false
        }
    }

    private func restoreDeliveryEscrowPending(_ id: UUID?) {
        guard let id else { return }
        do {
            try pendingTranscriptStore.setDeliveryState(.pending, for: Set([id]))
        } catch {
            recoveryNotice = "Delivery did not occur, but the recovery handoff could not be reset. Verify the destination before Paste Anyway: \(error.localizedDescription)"
        }
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
        guard autoPaste, !phase.isBusy, !isDeliveringHeldTranscripts else { return }
        let ready = heldTranscripts.filter {
            !suspendedAutomaticHeldIDs.contains($0.id)
                && !$0.deliveryIsUncertain
                && $0.target?.canDeliverOnReturn == true
        }
        guard
            !ready.isEmpty,
            let target = ready.first?.target,
            deliveryPolicy(for: target)?.deliveryMethod != .clipboardOnly
        else {
            return
        }

        // Everything spoken for this field, in the order it was spoken, as one
        // insert. Two dictations while away should read as two sentences, not
        // arrive as a race.
        let text = ready.map(\.text).joined(separator: " ")
        let readyIdentifiers = Set(ready.map(\.id))
        let originallyPendingIdentifiers = Set(
            ready.filter { $0.deliveryState == .pending }.map(\.id)
        )
        guard ensureSourceRecoveryIsUnlinked(for: readyIdentifiers) else {
            phase = .failed(
                "Waiting text cannot return automatically until its source-audio recovery transaction finishes. Nothing was pasted or removed."
            )
            return
        }
        guard markHeldDeliveryUncertain(readyIdentifiers) else { return }
        isDeliveringHeldTranscripts = true
        activeDeliveryEscrowIDs.formUnion(readyIdentifiers)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeDeliveryEscrowIDs.subtract(readyIdentifiers)
                self.isDeliveringHeldTranscripts = false
            }
            let result = await self.pasteController.deliverHeld(
                text,
                to: target,
                policy: self.deliveryPolicy(for: target)
            )
            if case .pasted(_, verified: false) = result {
                // A write may have happened even though this field cannot be
                // read back. Never turn uncertainty into repeated inserts.
                self.suspendedAutomaticHeldIDs.formUnion(readyIdentifiers)
                if self.heldTranscripts.allSatisfy({ transcript in
                    transcript.target == nil
                        || transcript.deliveryIsUncertain
                        || self.suspendedAutomaticHeldIDs.contains(transcript.id)
                }) {
                    self.stopPendingWatcher()
                }
                guard !self.phase.isBusy else { return }
                self.sounds.playFailed()
                self.phase = .failed(
                    "Paste was sent but could not be confirmed. It will not be attempted again automatically; verify the field, then copy, paste, or discard the held copy."
                )
                return
            }
            // Held text is only forgotten once it has actually gone somewhere.
            // Anything else — secure input, a refused menu action, a swallowed
            // keystroke — keeps it queued, because the app promises it is safe.
            guard result.isDelivered else {
                self.restoreHeldDeliveryPending(originallyPendingIdentifiers)
                return
            }
            let durablyRemoved = self.removeDeliveredHeldTranscripts(readyIdentifiers)
            self.heldTranscripts.removeAll { durablyRemoved.contains($0.id) }
            self.suspendedAutomaticHeldIDs.subtract(durablyRemoved)
            if self.heldTranscripts.allSatisfy({ transcript in
                transcript.target == nil
                    || transcript.deliveryIsUncertain
                    || self.suspendedAutomaticHeldIDs.contains(transcript.id)
            }) {
                self.stopPendingWatcher()
            }
            guard !self.phase.isBusy else { return }
            guard durablyRemoved == readyIdentifiers else {
                self.sounds.playFailed()
                self.phase = .failed(
                    "Paste was confirmed, but a recovery copy could not be cleared. It remains marked as possibly delivered; verify before Paste Anyway."
                )
                return
            }
            self.phase = .succeeded("Pasted where you left off")
            self.scheduleReadyReset()
        }
    }

    /// Drops everything held at the caret's current location, wherever that is.
    /// The user is explicitly asking for this destination, so no target match is
    /// required.
    func armUncertainHeldPaste() {
        guard hasUncertainHeldTranscripts, !isDeliveringHeldTranscripts else { return }
        armedUncertainPasteIDs = Set(heldTranscripts.map(\.id))
        recoveryNotice = "Paste Anyway is armed once. Return to the intended destination field and press \(releaseHotKeyLabel); SpeakPaste will consume this authorization after one attempt."
    }

    func releaseHeldTranscripts(allowUncertain: Bool = false) {
        // Delivery feedback shares the app phase. Releasing while a
        // recording is live could replace `.recording` with success/failure
        // and make the stop shortcut start a second capture instead.
        guard
            !phase.isBusy,
            !heldTranscripts.isEmpty,
            !isDeliveringHeldTranscripts
        else {
            return
        }
        let text = heldTranscripts.map(\.text).joined(separator: " ")
        let identifiers = Set(heldTranscripts.map(\.id))
        if hasUncertainHeldTranscripts,
           !allowUncertain,
           armedUncertainPasteIDs != identifiers {
            phase = .failed(
                "Some waiting text may already have been pasted. Verify the destination, then arm Paste Anyway in the dashboard before using \(releaseHotKeyLabel) in the target app."
            )
            return
        }
        guard ensureSourceRecoveryIsUnlinked(for: identifiers) else {
            phase = .failed(
                "Waiting text cannot be output until its source-audio recovery transaction finishes. Nothing was pasted or removed."
            )
            return
        }
        // One confirmation authorizes exactly one attempt against exactly the
        // queue the user reviewed. Any outcome requires a fresh confirmation.
        armedUncertainPasteIDs.removeAll()
        let originallyPendingIdentifiers = Set(
            heldTranscripts.filter { $0.deliveryState == .pending }.map(\.id)
        )
        guard markHeldDeliveryUncertain(identifiers) else { return }
        isDeliveringHeldTranscripts = true
        activeDeliveryEscrowIDs.formUnion(identifiers)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeDeliveryEscrowIDs.subtract(identifiers)
                self.isDeliveringHeldTranscripts = false
            }
            let result = await self.pasteController.pasteAtCurrentFocus(text)
            guard result.isDelivered else {
                // The text stays queued. Saying why beats a silent no-op.
                if case .pasted(_, verified: false) = result {
                    self.phase = .failed(
                        "Paste was sent but could not be confirmed. The recovery copy is marked as possibly delivered; verify the field before Paste Anyway."
                    )
                } else {
                    self.restoreHeldDeliveryPending(originallyPendingIdentifiers)
                    self.phase = .failed("Could not place the held text — \(result.detail).")
                }
                return
            }
            let removed = self.removeDeliveredHeldTranscripts(identifiers)
            self.heldTranscripts.removeAll { removed.contains($0.id) }
            self.suspendedAutomaticHeldIDs.subtract(removed)
            if self.heldTranscripts.isEmpty { self.stopPendingWatcher() }
            guard removed == identifiers else {
                self.phase = .failed(
                    "Paste was confirmed, but a recovery copy could not be cleared. It remains marked as possibly delivered; verify before Paste Anyway."
                )
                return
            }
            self.phase = .succeeded("Pasted here")
            self.scheduleReadyReset()
        }
    }

    /// Writes the ambiguity marker before a paste can have any external side
    /// effect. If the recovery journal cannot be updated, delivery is refused:
    /// a crash between paste and bookkeeping must never turn into a duplicate.
    private func markHeldDeliveryUncertain(_ identifiers: Set<UUID>) -> Bool {
        do {
            try pendingTranscriptStore.setDeliveryState(.deliveryUncertain, for: identifiers)
            for index in heldTranscripts.indices where identifiers.contains(heldTranscripts[index].id) {
                heldTranscripts[index].deliveryState = .deliveryUncertain
            }
            return true
        } catch {
            recoveryNotice = "Could not mark waiting text safe for output, so nothing was pasted, copied, or removed: \(error.localizedDescription)"
            phase = .failed(
                "Output was blocked because its recovery state could not be saved."
            )
            return false
        }
    }

    /// Only entries that were safe-to-retry before this attempt may return to
    /// pending. An entry recovered as uncertain remains uncertain until the
    /// user explicitly discards it or accepts the duplicate risk.
    private func restoreHeldDeliveryPending(_ identifiers: Set<UUID>) {
        guard !identifiers.isEmpty else { return }
        do {
            try pendingTranscriptStore.setDeliveryState(.pending, for: identifiers)
            for index in heldTranscripts.indices where identifiers.contains(heldTranscripts[index].id) {
                heldTranscripts[index].deliveryState = .pending
            }
        } catch {
            recoveryNotice = "The paste did not complete, but its recovery state could not be reset. Verify the destination before trying Paste Anyway: \(error.localizedDescription)"
        }
    }

    /// A verified paste is removed from memory only after the matching durable
    /// recovery entry is gone. Cleanup failures deliberately leave an uncertain
    /// entry visible instead of resurrecting it as an automatic retry later.
    private func removeDeliveredHeldTranscripts(_ identifiers: Set<UUID>) -> Set<UUID> {
        guard ensureSourceRecoveryIsUnlinked(for: identifiers) else { return [] }
        let storedIdentifiers = Set(identifiers.filter {
            pendingTranscriptStore.transcript(withID: $0) != nil
        })
        let removedFromStore: Set<UUID>
        do {
            removedFromStore = try pendingTranscriptStore.remove(storedIdentifiers)
        } catch {
            recoveryNotice = "Text was output, but its saved recovery entry could not be removed. It remains marked as possibly delivered: \(error.localizedDescription)"
            return []
        }
        let removed = identifiers
            .subtracting(storedIdentifiers)
            .union(removedFromStore)
        if !removed.isEmpty {
            armedUncertainPasteIDs.removeAll()
            if let lastTranscriptPendingID, removed.contains(lastTranscriptPendingID) {
                self.lastTranscriptPendingID = nil
                lastTranscriptOutputIsResolved = true
            }
        }
        return removed
    }

    func discardHeldTranscripts() {
        guard !isDeliveringHeldTranscripts else { return }
        let identifiers = Set(heldTranscripts.map(\.id))
        guard !identifiers.isEmpty else { return }
        guard activeDeliveryEscrowIDs.isDisjoint(with: identifiers) else {
            recoveryNotice = "Waiting text is currently being delivered and cannot be discarded yet."
            return
        }
        guard ensureSourceRecoveryIsUnlinked(for: identifiers) else { return }
        let storedIdentifiers = Set(identifiers.filter {
            pendingTranscriptStore.transcript(withID: $0) != nil
        })
        do {
            let removedFromStore = try pendingTranscriptStore.remove(storedIdentifiers)
            let removed = identifiers
                .subtracting(storedIdentifiers)
                .union(removedFromStore)
            guard removed == identifiers else {
                recoveryNotice = "Could not discard every reviewed waiting transcript; none of the unrelated recovery entries were touched."
                return
            }
            heldTranscripts.removeAll { removed.contains($0.id) }
            suspendedAutomaticHeldIDs.subtract(removed)
            armedUncertainPasteIDs.removeAll()
            if let lastTranscriptPendingID, removed.contains(lastTranscriptPendingID) {
                self.lastTranscriptPendingID = nil
                lastTranscriptOutputIsResolved = true
            }
            if heldTranscripts.isEmpty { stopPendingWatcher() }
            recoveryNotice = "Discarded the reviewed waiting transcripts."
        } catch {
            recoveryNotice = "Could not discard held transcripts: \(error.localizedDescription)"
        }
    }

    func copyHeldTranscripts() {
        guard !heldTranscripts.isEmpty else { return }
        let text = heldTranscripts.map(\.text).joined(separator: " ")
        let identifiers = Set(heldTranscripts.map(\.id))
        guard activeDeliveryEscrowIDs.isEmpty else {
            recoveryNotice = "Another transcript is currently being delivered. Wait for it to finish before changing the clipboard."
            return
        }
        guard ensureSourceRecoveryIsUnlinked(for: identifiers) else { return }
        let originallyPendingIDs = Set(heldTranscripts.filter {
            $0.deliveryState == .pending
        }.map(\.id))
        guard markHeldDeliveryUncertain(identifiers) else { return }
        guard pasteController.copyToPasteboardIfIdle(text) else {
            restoreHeldDeliveryPending(originallyPendingIDs)
            recoveryNotice = "The clipboard refused the waiting text. Its recovery entries were kept."
            return
        }
        let removed = removeDeliveredHeldTranscripts(identifiers)
        heldTranscripts.removeAll { removed.contains($0.id) }
        suspendedAutomaticHeldIDs.subtract(removed)
        if heldTranscripts.isEmpty { stopPendingWatcher() }
        recoveryNotice = removed == identifiers
            ? "Copied the waiting text and resolved its reviewed recovery entries."
            : "The waiting text was copied, but a recovery entry could not be cleared and remains marked as possibly delivered."
    }

    private func scheduleReadyReset() {
        let successPhase = phase
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.phase == successPhase else { return }
            self.phase = .ready
        }
    }

    private func deliveryPolicy(for target: MacDeliveryTarget?) -> MacDeliveryPolicy? {
        guard let bundleIdentifier = target?.bundleIdentifier else { return nil }
        return deliveryPolicies.configuredPolicy(for: bundleIdentifier)
    }

    private func recordFailure(
        _ message: String,
        deviceName: String,
        recordingDuration: TimeInterval,
        transcriptionDuration: TimeInterval
    ) {
        stopMeter()
        endRecordingActivity()
        sounds.playFailed()
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

    /// Records a transcription/delivery failure that belongs to audio whose
    /// microphone session ended earlier. It may finish while a newer recording
    /// is live, so it must not stop that recording's meter or replace its phase.
    private func recordCompletedFailure(
        _ message: String,
        deviceName: String,
        recordingDuration: TimeInterval,
        transcriptionDuration: TimeInterval
    ) {
        attempts = reliabilityStore.prepend(
            MacReliabilityAttempt(
                deviceName: deviceName,
                recordingDuration: recordingDuration,
                transcriptionDuration: transcriptionDuration,
                outcome: .failure,
                detail: message
            )
        )
        guard !phase.isBusy else { return }
        sounds.playFailed()
        phase = .failed(message)
    }

    private func handleUnexpectedRecordingFailure(_ error: Error, salvagedAudioURL: URL?) {
        // Once Command has moved the phase to finalizing, stopAndTranscribe
        // owns this same failure and the pending recorder error owns the same
        // salvage URL. Do not delete it here: the stop path will journal it.
        if phase == .finalizing { return }
        // This callback handles failures while the UI would otherwise continue
        // to claim that it is safe to speak.
        guard phase == .recording else {
            if let salvagedAudioURL {
                try? FileManager.default.removeItem(at: salvagedAudioURL)
            }
            return
        }
        let deviceName = selectedDevice?.name ?? "Unknown microphone"
        let recordingDuration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        stopMeter()
        endRecordingActivity()
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
                guard self.phase == .recording else { return }
                let now = Date()
                self.elapsed = now.timeIntervalSince(self.recordingStartedAt ?? now)
                self.inputLevel = self.recorder.normalizedLevel
                let deliveredSamples = self.recorder.deliveredSampleCount
                if deliveredSamples != self.lastDeliveredSampleCount {
                    self.lastDeliveredSampleCount = deliveredSamples
                    self.lastDeliveredSampleAt = now
                } else if
                    now.timeIntervalSince(self.lastDeliveredSampleAt) >= Self.streamStallTimeout,
                    !self.automaticStopInProgress
                {
                    self.stopForCaptureInterruption(
                        "The microphone stopped sending audio. SpeakPaste kept the part already captured."
                    )
                    return
                }

                if self.inputLevel > 0.012 {
                    self.lastAudibleSampleAt = now
                    if self.recordingWarning?.hasPrefix("NO AUDIO") == true {
                        self.recordingWarning = nil
                    }
                } else if
                    now.timeIntervalSince(self.lastAudibleSampleAt) >= Self.silenceWarningDelay,
                    self.elapsed >= Self.silenceWarningDelay,
                    self.recordingWarning == nil
                {
                    self.recordingWarning = "NO AUDIO — check the microphone"
                }

                if self.elapsed >= Self.maximumRecordingDuration,
                   !self.automaticStopInProgress {
                    self.automaticStopInProgress = true
                    self.recordingWarning = "20-minute limit reached — finishing this dictation"
                    self.stopMeter()
                    self.sounds.playRecordingStopped()
                    self.phase = .finalizing
                    Task { await self.stopAndTranscribe() }
                } else if
                    self.elapsed >= Self.durationWarning,
                    self.recordingWarning == nil
                {
                    self.recordingWarning = "One minute left — SpeakPaste stops safely at 20 minutes"
                }
            }
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        inputLevel = 0
    }

    private func beginRecordingActivity() {
        guard recordingActivity == nil else { return }
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Recording a SpeakPaste dictation"
        )
    }

    private func endRecordingActivity() {
        guard let recordingActivity else { return }
        ProcessInfo.processInfo.endActivity(recordingActivity)
        self.recordingActivity = nil
    }

    /// The menu item and capture indicator carry static accessibility labels, but VoiceOver
    /// does not announce their changing text automatically. Post only the
    /// consequential transitions so a hands-free user knows when speech is
    /// safe and whether delivery finished without navigating back to the app.
    private func announceCapturePhase(_ phase: MacCapturePhase) {
        let announcement: String?
        switch phase {
        case .ready:
            announcement = nil
        case .connecting:
            announcement = "SpeakPaste is connecting."
        case .recording:
            announcement = "SpeakPaste is listening."
        case .finalizing:
            announcement = "SpeakPaste is releasing the microphone."
        case .succeeded:
            announcement = "Dictation complete."
        case .failed:
            announcement = "SpeakPaste has a dictation error."
        }
        guard let announcement else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo:
            [
                .announcement: announcement,
                .priority: NSNumber(
                    value: NSAccessibilityPriorityLevel.high.rawValue
                ),
            ]
        )
    }

    private func stopForCaptureInterruption(_ message: String) {
        guard phase == .recording, !automaticStopInProgress else { return }
        automaticStopInProgress = true
        recordingWarning = message
        stopMeter()
        sounds.playRecordingStopped()
        phase = .finalizing
        Task { await stopAndTranscribe(interruption: message) }
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
                let activeDeviceID = self.connectedDeviceID
                let wasRecording = self.phase == .recording
                let deviceName = self.selectedDevice?.name ?? "Selected microphone"
                self.refreshDevices()
                if
                    let activeDeviceID,
                    !self.devices.contains(where: { $0.id == activeDeviceID })
                {
                    if wasRecording {
                        self.stopForCaptureInterruption(
                            "\(deviceName) disconnected. SpeakPaste kept the part already captured."
                        )
                        return
                    }
                    self.recorder.disconnect()
                    self.isMicrophoneConnected = false
                    self.connectedDeviceID = nil
                    self.connectionLatency = nil
                    // The earlier refresh skipped selection while the mic was
                    // still marked connected; re-resolve now that it is not.
                    self.resolveSelection()
                }
            }
        }
    }

    private func observeLifecycleChanges() {
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.phase == .recording {
                        self.stopForCaptureInterruption(
                            "The Mac went to sleep. SpeakPaste kept the part already captured."
                        )
                    } else if self.phase == .connecting {
                        self.cancelRecording()
                    } else if self.microphoneTestState.isRunning {
                        self.microphoneTestTask?.cancel()
                        self.microphoneTestTask = nil
                        self.recorder.disconnectSynchronously()
                        self.isMicrophoneConnected = false
                        self.connectedDeviceID = nil
                        self.connectionLatency = nil
                        self.inputLevel = 0
                        self.microphoneTestState = .idle
                    }
                }
            }
        )
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.refreshDevices()
                }
            }
        )
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            // This handler runs on one serial queue. Dispatching from that
            // queue to main preserves callback order; independent Tasks can
            // otherwise apply an older offline status after a newer recovery.
            DispatchQueue.main.async { [weak self] in
                self?.networkAvailabilityChanged(available)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func networkAvailabilityChanged(_ available: Bool) {
        let isInitialPath = !hasReceivedNetworkPath
        let previousAvailability = networkIsAvailable
        let stateChanged = isInitialPath || available != previousAvailability
        if stateChanged {
            networkPathGeneration &+= 1
        }
        hasReceivedNetworkPath = true
        networkIsAvailable = available
        // A satisfied-to-satisfied callback is not a recovery and must not
        // resend audio. Initial satisfaction is allowed so a journal restored
        // at login can resume once, while every later wake requires a real
        // unavailable -> available transition.
        let pathBecameUsable = available
            && (isInitialPath || !previousAvailability)
        guard pathBecameUsable else { return }
        retryConnectivityFailures()
    }

    private func retryConnectivityFailures(
        matching requestedIDs: Set<UUID>? = nil,
        notice: String? = nil
    ) {
        let eligible = retryableFailures.filter { failure in
            reconnectRetryIDs.contains(failure.id)
                && failure.retriesOnReconnect
                && (requestedIDs == nil || requestedIDs?.contains(failure.id) == true)
        }
        var startedCount = 0
        var failedClaimCount = 0
        var lastClaimFailureNotice: String?
        for failure in eligible {
            reconnectRetryIDs.remove(failure.id)
            if retry(failure) {
                startedCount += 1
            } else if retryableFailures.contains(where: { $0.id == failure.id }) {
                // A synchronous journal problem did not consume the waiting
                // item. Preserve its wake eligibility and, crucially, the
                // specific error notice written by `retry`.
                reconnectRetryIDs.insert(failure.id)
                failedClaimCount += 1
                lastClaimFailureNotice = recoveryNotice
            }
        }
        if startedCount > 0 {
            let startedNotice = notice ?? (startedCount == 1
                ? "Connection restored. Retrying one saved recording; its transcript will wait for manual placement."
                : "Connection restored. Retrying \(startedCount) saved recordings; their transcripts will wait for manual placement.")
            if failedClaimCount > 0 {
                recoveryNotice = "\(startedNotice) \(failedClaimCount) additional recording\(failedClaimCount == 1 ? "" : "s") remained queued because its journal claim failed. \(lastClaimFailureNotice ?? "")"
            } else {
                recoveryNotice = startedNotice
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

    private var hasEnvironmentAPIKey: Bool {
        environmentAPIKey?.isEmpty == false
    }

    private func correctionTokens(in text: String) -> [String] {
        text.split { character in
            !(character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        .map(String.init)
    }

    /// One-time migration from the prototype's UserDefaults index. Only files
    /// already inside SpeakPaste's own PendingAudio directory are trusted; a
    /// tampered absolute path is never moved or deleted.
    private static func loadLegacyRetryableFailures() -> [MacRetryableDictation] {
        guard
            let data = UserDefaults.standard.data(forKey: retryableFailuresKey),
            let stored = try? JSONDecoder().decode([MacStoredRetryableDictation].self, from: data)
        else {
            return []
        }
        guard let directory = retryAudioDirectory?.standardizedFileURL else { return [] }
        let directoryPrefix = directory.path + "/"
        var recovered: [MacRetryableDictation] = []
        for item in stored {
            let url = URL(fileURLWithPath: item.audioPath).standardizedFileURL
            guard
                url.path.hasPrefix(directoryPrefix),
                FileManager.default.fileExists(atPath: url.path)
            else { continue }
            recovered.append(
                MacRetryableDictation(
                    id: item.id,
                    audioURL: url,
                    target: nil,
                    requiresManualOutput: true,
                    deviceName: item.deviceName,
                    recordingDuration: item.recordingDuration,
                    reason: item.reason,
                    createdAt: item.createdAt
                )
            )
        }
        return recovered
    }

    private static var retryAudioDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SpeakPaste", isDirectory: true)
            .appendingPathComponent("PendingAudio", isDirectory: true)
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        Task { @MainActor in _ = NSApp.setActivationPolicy(policy) }
    }

    private var resolvedAPIKey: String? {
        if hasEnvironmentAPIKey { return environmentAPIKey }
        let saved = keychain.load()
        if let saved, !saved.isEmpty { return saved }
        return nil
    }
}
