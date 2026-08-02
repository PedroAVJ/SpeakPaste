import Foundation

struct MacReliabilityAttempt: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let deviceName: String
    let recordingDuration: TimeInterval
    let transcriptionDuration: TimeInterval
    let outcome: Outcome
    let detail: String

    enum Outcome: String, Codable {
        case success
        case failure
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        deviceName: String,
        recordingDuration: TimeInterval,
        transcriptionDuration: TimeInterval,
        outcome: Outcome,
        detail: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.recordingDuration = recordingDuration
        self.transcriptionDuration = transcriptionDuration
        self.outcome = outcome
        self.detail = detail
    }
}

struct MacReliabilityStore {
    private let defaults: UserDefaults
    private let key = "mac-reliability-attempts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [MacReliabilityAttempt] {
        guard
            let data = defaults.data(forKey: key),
            let attempts = try? JSONDecoder().decode([MacReliabilityAttempt].self, from: data)
        else {
            return []
        }
        return attempts
    }

    func prepend(_ attempt: MacReliabilityAttempt) -> [MacReliabilityAttempt] {
        let attempts = Array(([attempt] + load()).prefix(20))
        if let data = try? JSONEncoder().encode(attempts) {
            defaults.set(data, forKey: key)
        }
        return attempts
    }
}
