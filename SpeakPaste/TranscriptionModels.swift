import Foundation

/// A pinned Scribe v2 language hint.
///
/// This is a value-backed catalog rather than a closed enum so the documented
/// Scribe language set can grow without turning every display/API mapping into
/// another exhaustive switch. The three original persisted values remain
/// exactly `automatic`, `english`, and `spanish`.
struct TranscriptionLanguage: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    var id: String { rawValue }

    static let automatic = Self(uncheckedRawValue: "automatic")
    static let english = Self(uncheckedRawValue: "english")
    static let spanish = Self(uncheckedRawValue: "spanish")

    /// Scribe v2's language catalog as published by ElevenLabs. English and
    /// Spanish stay at the front because they were SpeakPaste's original pins;
    /// the remaining languages follow the documentation's alphabetical order.
    static let supportedCases: [Self] = catalog.map {
        Self(uncheckedRawValue: $0.rawValue)
    }

    /// The macOS menu can present the full Scribe catalog. The existing iPhone
    /// UI is a three-segment control, so it intentionally keeps its original
    /// choices until that surface gets a searchable/menu-style language picker.
#if os(macOS)
    static let allCases = supportedCases
#else
    static let allCases = [automatic, english, spanish]
#endif

    init?(rawValue: String) {
        guard Self.catalogByRawValue[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    var title: String {
        Self.catalogByRawValue[rawValue]?.title ?? rawValue
    }

    var apiCode: String? {
        Self.catalogByRawValue[rawValue]?.apiCode
    }

    static func title(forAPICode code: String) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.first { $0.apiCode?.lowercased() == normalized }?.title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let language = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported transcription language: \(rawValue)"
            )
        }
        self = language
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    private struct CatalogEntry: Sendable {
        let rawValue: String
        let title: String
        let apiCode: String?
    }

    private static let catalog: [CatalogEntry] = [
        CatalogEntry(rawValue: "automatic", title: "Auto", apiCode: nil),
        CatalogEntry(rawValue: "english", title: "English", apiCode: "en"),
        CatalogEntry(rawValue: "spanish", title: "Spanish", apiCode: "es"),
        CatalogEntry(rawValue: "afrikaans", title: "Afrikaans", apiCode: "afr"),
        CatalogEntry(rawValue: "amharic", title: "Amharic", apiCode: "amh"),
        CatalogEntry(rawValue: "arabic", title: "Arabic", apiCode: "ara"),
        CatalogEntry(rawValue: "armenian", title: "Armenian", apiCode: "hye"),
        CatalogEntry(rawValue: "assamese", title: "Assamese", apiCode: "asm"),
        CatalogEntry(rawValue: "asturian", title: "Asturian", apiCode: "ast"),
        CatalogEntry(rawValue: "azerbaijani", title: "Azerbaijani", apiCode: "aze"),
        CatalogEntry(rawValue: "belarusian", title: "Belarusian", apiCode: "bel"),
        CatalogEntry(rawValue: "bengali", title: "Bengali", apiCode: "ben"),
        CatalogEntry(rawValue: "bosnian", title: "Bosnian", apiCode: "bos"),
        CatalogEntry(rawValue: "bulgarian", title: "Bulgarian", apiCode: "bul"),
        CatalogEntry(rawValue: "burmese", title: "Burmese", apiCode: "mya"),
        CatalogEntry(rawValue: "cantonese", title: "Cantonese", apiCode: "yue"),
        CatalogEntry(rawValue: "catalan", title: "Catalan", apiCode: "cat"),
        CatalogEntry(rawValue: "cebuano", title: "Cebuano", apiCode: "ceb"),
        CatalogEntry(rawValue: "chichewa", title: "Chichewa", apiCode: "nya"),
        CatalogEntry(rawValue: "croatian", title: "Croatian", apiCode: "hrv"),
        CatalogEntry(rawValue: "czech", title: "Czech", apiCode: "ces"),
        CatalogEntry(rawValue: "danish", title: "Danish", apiCode: "dan"),
        CatalogEntry(rawValue: "dutch", title: "Dutch", apiCode: "nld"),
        CatalogEntry(rawValue: "estonian", title: "Estonian", apiCode: "est"),
        CatalogEntry(rawValue: "filipino", title: "Filipino", apiCode: "fil"),
        CatalogEntry(rawValue: "finnish", title: "Finnish", apiCode: "fin"),
        CatalogEntry(rawValue: "french", title: "French", apiCode: "fra"),
        CatalogEntry(rawValue: "fulah", title: "Fulah", apiCode: "ful"),
        CatalogEntry(rawValue: "galician", title: "Galician", apiCode: "glg"),
        CatalogEntry(rawValue: "ganda", title: "Ganda", apiCode: "lug"),
        CatalogEntry(rawValue: "georgian", title: "Georgian", apiCode: "kat"),
        CatalogEntry(rawValue: "german", title: "German", apiCode: "deu"),
        CatalogEntry(rawValue: "greek", title: "Greek", apiCode: "ell"),
        CatalogEntry(rawValue: "gujarati", title: "Gujarati", apiCode: "guj"),
        CatalogEntry(rawValue: "hausa", title: "Hausa", apiCode: "hau"),
        CatalogEntry(rawValue: "hebrew", title: "Hebrew", apiCode: "heb"),
        CatalogEntry(rawValue: "hindi", title: "Hindi", apiCode: "hin"),
        CatalogEntry(rawValue: "hungarian", title: "Hungarian", apiCode: "hun"),
        CatalogEntry(rawValue: "icelandic", title: "Icelandic", apiCode: "isl"),
        CatalogEntry(rawValue: "igbo", title: "Igbo", apiCode: "ibo"),
        CatalogEntry(rawValue: "indonesian", title: "Indonesian", apiCode: "ind"),
        CatalogEntry(rawValue: "irish", title: "Irish", apiCode: "gle"),
        CatalogEntry(rawValue: "italian", title: "Italian", apiCode: "ita"),
        CatalogEntry(rawValue: "japanese", title: "Japanese", apiCode: "jpn"),
        CatalogEntry(rawValue: "javanese", title: "Javanese", apiCode: "jav"),
        CatalogEntry(rawValue: "kabuverdianu", title: "Kabuverdianu", apiCode: "kea"),
        CatalogEntry(rawValue: "kannada", title: "Kannada", apiCode: "kan"),
        CatalogEntry(rawValue: "kazakh", title: "Kazakh", apiCode: "kaz"),
        CatalogEntry(rawValue: "khmer", title: "Khmer", apiCode: "khm"),
        CatalogEntry(rawValue: "korean", title: "Korean", apiCode: "kor"),
        CatalogEntry(rawValue: "kurdish", title: "Kurdish", apiCode: "kur"),
        CatalogEntry(rawValue: "kyrgyz", title: "Kyrgyz", apiCode: "kir"),
        CatalogEntry(rawValue: "lao", title: "Lao", apiCode: "lao"),
        CatalogEntry(rawValue: "latvian", title: "Latvian", apiCode: "lav"),
        CatalogEntry(rawValue: "lingala", title: "Lingala", apiCode: "lin"),
        CatalogEntry(rawValue: "lithuanian", title: "Lithuanian", apiCode: "lit"),
        CatalogEntry(rawValue: "luo", title: "Luo", apiCode: "luo"),
        CatalogEntry(rawValue: "luxembourgish", title: "Luxembourgish", apiCode: "ltz"),
        CatalogEntry(rawValue: "macedonian", title: "Macedonian", apiCode: "mkd"),
        CatalogEntry(rawValue: "malay", title: "Malay", apiCode: "msa"),
        CatalogEntry(rawValue: "malayalam", title: "Malayalam", apiCode: "mal"),
        CatalogEntry(rawValue: "maltese", title: "Maltese", apiCode: "mlt"),
        CatalogEntry(rawValue: "mandarin-chinese", title: "Mandarin Chinese", apiCode: "zho"),
        CatalogEntry(rawValue: "maori", title: "Māori", apiCode: "mri"),
        CatalogEntry(rawValue: "marathi", title: "Marathi", apiCode: "mar"),
        CatalogEntry(rawValue: "mongolian", title: "Mongolian", apiCode: "mon"),
        CatalogEntry(rawValue: "nepali", title: "Nepali", apiCode: "nep"),
        CatalogEntry(rawValue: "northern-sotho", title: "Northern Sotho", apiCode: "nso"),
        CatalogEntry(rawValue: "norwegian", title: "Norwegian", apiCode: "nor"),
        CatalogEntry(rawValue: "occitan", title: "Occitan", apiCode: "oci"),
        CatalogEntry(rawValue: "odia", title: "Odia", apiCode: "ori"),
        CatalogEntry(rawValue: "pashto", title: "Pashto", apiCode: "pus"),
        CatalogEntry(rawValue: "persian", title: "Persian", apiCode: "fas"),
        CatalogEntry(rawValue: "polish", title: "Polish", apiCode: "pol"),
        CatalogEntry(rawValue: "portuguese", title: "Portuguese", apiCode: "por"),
        CatalogEntry(rawValue: "punjabi", title: "Punjabi", apiCode: "pan"),
        CatalogEntry(rawValue: "romanian", title: "Romanian", apiCode: "ron"),
        CatalogEntry(rawValue: "russian", title: "Russian", apiCode: "rus"),
        CatalogEntry(rawValue: "serbian", title: "Serbian", apiCode: "srp"),
        CatalogEntry(rawValue: "shona", title: "Shona", apiCode: "sna"),
        CatalogEntry(rawValue: "sindhi", title: "Sindhi", apiCode: "snd"),
        CatalogEntry(rawValue: "slovak", title: "Slovak", apiCode: "slk"),
        CatalogEntry(rawValue: "slovenian", title: "Slovenian", apiCode: "slv"),
        CatalogEntry(rawValue: "somali", title: "Somali", apiCode: "som"),
        CatalogEntry(rawValue: "swahili", title: "Swahili", apiCode: "swa"),
        CatalogEntry(rawValue: "swedish", title: "Swedish", apiCode: "swe"),
        CatalogEntry(rawValue: "tamil", title: "Tamil", apiCode: "tam"),
        CatalogEntry(rawValue: "tajik", title: "Tajik", apiCode: "tgk"),
        CatalogEntry(rawValue: "telugu", title: "Telugu", apiCode: "tel"),
        CatalogEntry(rawValue: "thai", title: "Thai", apiCode: "tha"),
        CatalogEntry(rawValue: "turkish", title: "Turkish", apiCode: "tur"),
        CatalogEntry(rawValue: "ukrainian", title: "Ukrainian", apiCode: "ukr"),
        CatalogEntry(rawValue: "umbundu", title: "Umbundu", apiCode: "umb"),
        CatalogEntry(rawValue: "urdu", title: "Urdu", apiCode: "urd"),
        CatalogEntry(rawValue: "uzbek", title: "Uzbek", apiCode: "uzb"),
        CatalogEntry(rawValue: "vietnamese", title: "Vietnamese", apiCode: "vie"),
        CatalogEntry(rawValue: "welsh", title: "Welsh", apiCode: "cym"),
        CatalogEntry(rawValue: "wolof", title: "Wolof", apiCode: "wol"),
        CatalogEntry(rawValue: "xhosa", title: "Xhosa", apiCode: "xho"),
        CatalogEntry(rawValue: "zulu", title: "Zulu", apiCode: "zul"),
    ]

    private static let catalogByRawValue = Dictionary(
        uniqueKeysWithValues: catalog.map { ($0.rawValue, $0) }
    )
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
