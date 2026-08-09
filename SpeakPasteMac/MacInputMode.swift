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

/// Separates an expected Voice Processing I/O route rebuild from a real lost
/// session. Kept free of AVFoundation types so the recovery contract can be
/// tested without opening a microphone.
enum MacVoiceProcessingSessionHealth: Equatable {
    case active
    case recoveringConfiguration
    case connectionFailed
    case deviceUnavailable

    static func evaluate(
        sessionMatches: Bool,
        hasEngine: Bool,
        inputRouteMatches: Bool,
        engineIsRunning: Bool
    ) -> Self {
        guard sessionMatches, hasEngine else { return .connectionFailed }
        guard inputRouteMatches else { return .deviceUnavailable }
        return engineIsRunning ? .active : .recoveringConfiguration
    }
}
