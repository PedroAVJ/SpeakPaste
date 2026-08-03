import Combine
import Foundation

/// One literal substitution the user configured: what Scribe tends to hear, and
/// what should be written instead. The spoken form is matched case-insensitively
/// because Scribe decides capitalization on its own, while the written form is
/// inserted exactly as configured — that is the whole point of the rule.
struct MacTextReplacement: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var spoken: String
    var written: String
    var isEnabled: Bool
    /// Off by default only for rules the user deliberately loosens: substring
    /// matching rewrites the middle of words that were never dictated wrong.
    var matchesWholeWordsOnly: Bool

    init(spoken: String, written: String, isEnabled: Bool, matchesWholeWordsOnly: Bool) {
        self.id = UUID()
        self.spoken = spoken
        self.written = written
        self.isEnabled = isEnabled
        self.matchesWholeWordsOnly = matchesWholeWordsOnly
    }
}

/// The user's replacement rules, kept in Application Support rather than
/// `UserDefaults`: this is a list a person curates over months, and it should
/// survive a defaults reset and be readable and backupable as a plain file.
@MainActor
final class MacReplacementStore: ObservableObject {
    /// Order is meaningful. When two rules match at the same position the
    /// longer one wins, and equal-length rules resolve in this order, so the
    /// list the user sees is the list that decides.
    @Published private(set) var replacements: [MacTextReplacement] = []

    /// A ceiling on a list that is scanned once per dictation. Well past any
    /// hand-curated vocabulary, and low enough that a runaway import cannot
    /// make delivery feel slow.
    nonisolated static let maximumReplacements = 500

    /// Nil when Application Support cannot be resolved. The rules still work
    /// for the session; only persistence is lost, which is not worth refusing
    /// to dictate over.
    private let fileURL: URL?

    /// `directory` exists so the rules can be exercised against a scratch folder
    /// instead of the real Application Support, matching `MacHistoryStore`.
    /// Production callers use the default.
    init(directory: URL? = nil) {
        fileURL = Self.makeFileURL(in: directory)
        replacements = Self.load(from: fileURL)
    }

    func add(spoken: String, written: String) {
        let trimmedSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty spoken form would match at every position in every
        // transcript, so it is refused rather than stored and worked around.
        guard !trimmedSpoken.isEmpty, replacements.count < Self.maximumReplacements else { return }
        replacements.append(
            MacTextReplacement(
                spoken: trimmedSpoken,
                written: written.trimmingCharacters(in: .whitespacesAndNewlines),
                isEnabled: true,
                matchesWholeWordsOnly: true
            )
        )
        persist()
    }

    func remove(_ id: UUID) {
        guard replacements.contains(where: { $0.id == id }) else { return }
        replacements.removeAll { $0.id == id }
        persist()
    }

    /// Edits an existing rule in place. A rule that is no longer in the list is
    /// not resurrected: removal is the user's more recent intent.
    func update(_ replacement: MacTextReplacement) {
        guard let index = replacements.firstIndex(where: { $0.id == replacement.id }) else { return }
        var edited = replacement
        edited.spoken = replacement.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.written = replacement.written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.spoken.isEmpty else { return }
        replacements[index] = edited
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        // The file is meant to be legible to whoever opens it, and stable
        // enough that a backup diff shows only what actually changed.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(replacements) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func makeFileURL(in directory: URL?) -> URL? {
        if let directory {
            return directory.appending(path: "replacements.json", directoryHint: .notDirectory)
        }
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else {
            return nil
        }
        return base
            .appending(path: "SpeakPaste", directoryHint: .isDirectory)
            .appending(path: "replacements.json", directoryHint: .notDirectory)
    }

    private static func load(from fileURL: URL?) -> [MacTextReplacement] {
        guard
            let fileURL,
            let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode([MacTextReplacement].self, from: data)
        else {
            return []
        }
        return Array(stored.prefix(maximumReplacements))
    }
}

/// Deterministic, local cleanup applied to a finished transcript just before it
/// is delivered. Everything here is a rule the user can predict and a rule the
/// user asked for: the configured substitutions, and the spacing and casing
/// needed to make the insertion sit correctly against the text already at the
/// cursor. Nothing else in the user's speech is touched.
enum MacTranscriptPostProcessor {
    static func apply(
        _ transcript: String,
        replacements: [MacTextReplacement],
        precedingText: String?
    ) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // A silent recording must not push a stray space into the field.
        guard !trimmed.isEmpty else { return "" }
        let substituted = substitute(
            trimmed,
            using: replacements.filter { $0.isEnabled && !$0.spoken.isEmpty }
        )
        return join(substituted, after: precedingText)
    }

    private struct Match {
        let range: Range<String.Index>
        let written: String
    }

    /// A single left-to-right pass. Text that a rule has already produced is
    /// never rescanned, so one rule's output cannot be swallowed by another
    /// rule and the result does not depend on how the rules happen to chain.
    ///
    /// Each rule carries its own forward-only search cursor. Re-searching every
    /// rule over the whole remaining transcript after every substitution is
    /// quadratic, and this runs on the main actor between transcription and
    /// paste: a 5,000-character dictation against 30 rules froze the app for
    /// about four seconds, and the store permits 500 rules. Because a search
    /// started later can only find a match later, a rule's cached hit stays
    /// valid until the cursor passes it, which makes the pass near-linear.
    private static func substitute(_ text: String, using replacements: [MacTextReplacement]) -> String {
        guard !replacements.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        var pending: [Range<String.Index>?] = replacements.map {
            firstRange(of: $0, in: text, from: text.startIndex)
        }

        while cursor < text.endIndex {
            // The earliest match wins; at the same position the longest one
            // does, so a rule for "New York City" is not pre-empted by one for
            // "New York". Ties beyond that go to the earlier rule in the list,
            // which is the order the user sees.
            var best: Match?
            for index in replacements.indices {
                if let cached = pending[index], cached.lowerBound < cursor {
                    pending[index] = firstRange(of: replacements[index], in: text, from: cursor)
                }
                // A rule that found nothing from an earlier start can find
                // nothing from a later one, so nil is final.
                guard let range = pending[index] else { continue }
                if let current = best {
                    guard range.lowerBound < current.range.lowerBound
                        || (range.lowerBound == current.range.lowerBound
                            && range.upperBound > current.range.upperBound)
                    else {
                        continue
                    }
                }
                best = Match(range: range, written: replacements[index].written)
            }

            guard let match = best else { break }
            result.append(contentsOf: text[cursor..<match.range.lowerBound])
            result.append(match.written)
            cursor = match.range.upperBound
        }

        result.append(contentsOf: text[cursor...])
        return result
    }

    private static func firstRange(
        of replacement: MacTextReplacement,
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var searchStart = start
        while searchStart < text.endIndex {
            guard
                let range = text.range(
                    of: replacement.spoken,
                    options: [.caseInsensitive],
                    range: searchStart..<text.endIndex
                )
            else {
                return nil
            }
            if !replacement.matchesWholeWordsOnly || isWholeWord(range, in: text) {
                return range
            }
            // "cat" inside "category" is not a hit, but a later "cat" may be.
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex,
           isWordCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Makes the transcript fit what is already at the cursor. Only the leading
    /// space and the first character's case are ever decided here.
    private static func join(_ text: String, after precedingText: String?) -> String {
        guard let precedingText, let last = precedingText.last else {
            return capitalizingFirstCharacter(text)
        }
        if last.isWhitespace {
            // The space is already there; only the case is still open, and the
            // whitespace itself says nothing about it.
            return startsNewSentence(before: precedingText) ? capitalizingFirstCharacter(text) : text
        }
        if isOpeningMark(at: precedingText.index(before: precedingText.endIndex), in: precedingText) {
            return text
        }
        // A transcript that opens with punctuation belongs against the word
        // before it. " , and then" is never what was dictated.
        if let first = text.first, attachingMarks.contains(first) {
            return text
        }
        if startsNewSentence(before: precedingText) {
            return " " + capitalizingFirstCharacter(text)
        }
        // Mid-sentence. Recasing here would be an edit the user never asked for.
        return " " + text
    }

    /// Whether the insertion point begins a sentence. Trailing whitespace and
    /// closing punctuation are transparent, so `He said "Done."` counts just as
    /// `Done.` does.
    private static func startsNewSentence(before precedingText: String) -> Bool {
        var index = precedingText.endIndex
        while index > precedingText.startIndex {
            let previous = precedingText.index(before: index)
            let character = precedingText[previous]
            if character.isWhitespace || closingMarks.contains(character) {
                index = previous
                continue
            }
            return sentenceTerminators.contains(character)
        }
        // Nothing but whitespace and punctuation behind the cursor: this is the
        // start of the text.
        return true
    }

    /// A straight quote opens as often as it closes, so it counts as opening
    /// only where a quotation could actually begin.
    private static func isOpeningMark(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if openingMarks.contains(character) { return true }
        guard ambiguousQuotes.contains(character) else { return false }
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return previous.isWhitespace || openingMarks.contains(previous)
    }

    private static func capitalizingFirstCharacter(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Non-locale casing keeps the result identical everywhere, which is
        // what makes this function testable without a locale fixture.
        return String(first).uppercased() + text.dropFirst()
    }

    /// Marks that never take a space in front of them, so a transcript opening
    /// with one is pasted flush against the text already at the cursor.
    private static let attachingMarks: Set<Character> = [
        ",", ".", "!", "?", ":", ";", "%", ")", "]", "}",
        "\u{201D}", "\u{2019}", "\u{00BB}", "\u{203A}",
    ]
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", ":"]
    private static let closingMarks: Set<Character> = [")", "]", "}", "\"", "'", "\u{201D}", "\u{2019}", "\u{00BB}", "\u{203A}"]
    private static let openingMarks: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "\u{00AB}", "\u{2039}", "\u{00BF}", "\u{00A1}"]
    private static let ambiguousQuotes: Set<Character> = ["\"", "'"]
}
