import AVFoundation
import Foundation

/// The two built-in capture sources, one per source key. Exact device UIDs come
/// and go; carrying the semantic choice instead keeps an absent iPhone from
/// silently turning into the Mac microphone (or vice versa).
enum MacInputMode: String, CaseIterable, Equatable, Sendable {
    case mac
    case iPhone

    var opposite: MacInputMode {
        self == .mac ? .iPhone : .mac
    }

    var title: String {
        switch self {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        }
    }

    func matches(isContinuityDevice: Bool, isBuiltInDevice: Bool) -> Bool {
        switch self {
        case .mac: isBuiltInDevice
        case .iPhone: isContinuityDevice
        }
    }
}

/// Plans a Voice Processing I/O route from explicit topology rather than from
/// device names. A device may be used directly only when it is both the chosen
/// input and the current output and exposes channels in both directions.
enum MacVoiceProcessingRoutePlan: Equatable, Sendable {
    case directDevice
    case privateAggregate

    static func choose(
        selectedInputUID: String,
        selectedInputChannelCount: UInt32,
        currentOutputUID: String,
        currentOutputChannelCount: UInt32
    ) -> Self? {
        guard selectedInputChannelCount > 0, currentOutputChannelCount > 0 else {
            return nil
        }
        return selectedInputUID == currentOutputUID
            ? .directDevice
            : .privateAggregate
    }
}

/// A private aggregate can also contain input channels exposed by the current
/// output device (for example an AirPods microphone). SpeakPaste puts its
/// selected input first, then pins every destination channel to that leading
/// range so VPIO cannot silently record the output device's microphone.
enum MacSelectedInputChannelMap {
    static func make(
        selectedInputChannelCount: UInt32,
        destinationChannelCount: UInt32
    ) -> [Int32]? {
        guard selectedInputChannelCount > 0, destinationChannelCount > 0 else {
            return nil
        }
        return (0..<destinationChannelCount).map {
            Int32($0 % selectedInputChannelCount)
        }
    }
}

enum MacAudibleReadinessPolicy {
    /// RMS below this floor is indistinguishable from a muted digital stream.
    /// Ordinary room tone is comfortably above it.
    static let silenceFloor: Float = 0.0015

    static func isAudible(rms: Float) -> Bool {
        rms.isFinite && rms > silenceFloor
    }

    static func isReady(
        steadyWindows: Int,
        audibleWindows: Int,
        requiredSteadyWindows: Int
    ) -> Bool {
        steadyWindows >= requiredSteadyWindows && audibleWindows > 0
    }
}

enum MacMicrophoneModeReadinessPolicy {
    /// Voice Isolation is the promise that must never be inferred from the
    /// user's preference alone. Other mode differences remain visible but do
    /// not make otherwise-valid capture unusable.
    static func permitsRecording(
        preferred: MacSystemMicrophoneMode,
        active: MacSystemMicrophoneMode
    ) -> Bool {
        preferred != .voiceIsolation || active == .voiceIsolation
    }
}

enum MacOtherAudioDuckingLifecyclePolicy {
    /// An async enable may complete after Escape, pause, or a newer recording.
    /// Only the still-current live recording is allowed to keep ducking active.
    static func shouldKeepActivation(
        activationID: UUID,
        currentActivationID: UUID?,
        isRecording: Bool
    ) -> Bool {
        isRecording && activationID == currentActivationID
    }
}

/// The system-owned microphone processing choice, translated into a stable
/// value that can be rendered and exported without carrying AVFoundation types
/// through the rest of the app.
enum MacSystemMicrophoneMode: String, Codable, Equatable, Sendable {
    case standard
    case wideSpectrum
    case voiceIsolation
    case unknown

    init(_ mode: AVCaptureDevice.MicrophoneMode) {
        switch mode {
        case .standard:
            self = .standard
        case .wideSpectrum:
            self = .wideSpectrum
        case .voiceIsolation:
            self = .voiceIsolation
        @unknown default:
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .wideSpectrum: "Wide Spectrum"
        case .voiceIsolation: "Voice Isolation"
        case .unknown: "Unknown"
        }
    }
}

/// A truthful view of Apple's two read-only microphone-mode properties.
///
/// `preferred` is what the user selected in Control Center. `active` is
/// deliberately absent while SpeakPaste owns no capture route; once a route is
/// active it says what that route actually applied, which can differ from the
/// preference when the route does not support it.
struct MacMicrophoneModeStatus: Equatable, Sendable {
    let preferred: MacSystemMicrophoneMode
    let active: MacSystemMicrophoneMode?

    static func evaluate(
        preferred: MacSystemMicrophoneMode,
        systemActive: MacSystemMicrophoneMode,
        hasActiveCaptureRoute: Bool
    ) -> Self {
        Self(
            preferred: preferred,
            active: hasActiveCaptureRoute ? systemActive : nil
        )
    }

    var summary: String {
        guard let active else {
            return "macOS has \(preferred.title) selected. Start a microphone, then check here to confirm what the active route applies."
        }
        if active == preferred {
            return "\(active.title) is active for this capture."
        }
        return "macOS has \(preferred.title) selected, but this active route is using \(active.title). The route may not support the selected mode."
    }
}
