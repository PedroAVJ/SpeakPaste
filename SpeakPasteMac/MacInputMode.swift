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
