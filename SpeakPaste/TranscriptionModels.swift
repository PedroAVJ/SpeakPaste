import Foundation

enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable {
    case automatic
    case english
    case spanish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .english: "English"
        case .spanish: "Spanish"
        }
    }

    var apiCode: String? {
        switch self {
        case .automatic: nil
        case .english: "en"
        case .spanish: "es"
        }
    }
}

struct TranscriptionResult: Decodable, Equatable {
    let text: String
    let languageCode: String?
    let languageProbability: Double?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
        case languageProbability = "language_probability"
    }
}

struct TranscriptItem: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    let languageCode: String?
    let duration: TimeInterval
    /// Links background history to the App Group delivery it can acknowledge.
    /// Optional so history written by older builds still decodes.
    let sourceSessionID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        languageCode: String?,
        duration: TimeInterval,
        sourceSessionID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.languageCode = languageCode
        self.duration = duration
        self.sourceSessionID = sourceSessionID
    }
}
