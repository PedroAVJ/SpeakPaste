import Combine
import Foundation

/// Turns Scribe's automatic-language metadata into a quality warning without
/// altering or discarding the transcript. ElevenLabs does not publish a
/// calibrated intervention threshold; below 50%, even the top guess is more
/// likely than not to be wrong.
enum MacLanguageConfidenceReview {
    nonisolated static let automaticThreshold = 0.5

    nonisolated static func notice(
        isAutomatic: Bool,
        languageTitle: String?,
        probability: Double?
    ) -> String? {
        guard
            isAutomatic,
            let probability,
            probability.isFinite,
            probability >= 0,
            probability < automaticThreshold
        else {
            return nil
        }

        let percent = Int((probability * 100).rounded())
        if let languageTitle {
            return "Scribe was only \(percent)% confident that the language was \(languageTitle). Review the text or pin the language in Settings."
        }
        return "Scribe's automatic language confidence was only \(percent)%. Review the text or pin the language in Settings."
    }
}

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
    @Published private(set) var lastPersistenceError: String?

    /// A ceiling on a list that is scanned once per dictation. Well past any
    /// hand-curated vocabulary, and low enough that a runaway import cannot
    /// make delivery feel slow.
    nonisolated static let maximumReplacements = 500

    /// Nil when Application Support cannot be resolved. The rules still work
    /// for the session; only persistence is lost, which is not worth refusing
    /// to dictate over.
    private let fileURL: URL?
    /// Unreadable or future documents stay byte-for-byte untouched until the
    /// user removes them outside SpeakPaste.
    private var blockedExistingDocumentReason: String?

    /// `directory` exists so the rules can be exercised against a scratch folder
    /// instead of the real Application Support, matching `MacHistoryStore`.
    /// Production callers use the default.
    init(directory: URL? = nil) {
        let resolvedFileURL = Self.makeFileURL(in: directory)
        fileURL = resolvedFileURL
        let loaded = Self.load(from: resolvedFileURL)
        let permissionWarning: String?
        if loaded.blockedExistingDocumentReason == nil {
            do {
                try MacPrivateStoreIO.secureExistingStorage(at: resolvedFileURL)
                permissionWarning = nil
            } catch {
                permissionWarning = "Could not secure replacement storage: \(error.localizedDescription)"
            }
        } else {
            permissionWarning = nil
        }
        replacements = loaded.replacements
        blockedExistingDocumentReason = loaded.blockedExistingDocumentReason
            ?? permissionWarning
        let messages = [permissionWarning, loaded.warning].compactMap { $0 }
        lastPersistenceError = messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    @discardableResult
    func add(spoken: String, written: String) -> Bool {
        addAll([(spoken: spoken, written: written)]) == 1
    }

    /// Commits learned edits as one document transition. Either every proposed
    /// correction becomes durable and visible, or none of them does.
    @discardableResult
    func addAll(_ candidates: [(spoken: String, written: String)]) -> Int {
        guard
            !candidates.isEmpty,
            candidates.count <= Self.maximumReplacements - replacements.count
        else {
            return 0
        }
        let normalized = candidates.map { candidate in
            (
                spoken: candidate.spoken.trimmingCharacters(in: .whitespacesAndNewlines),
                written: candidate.written.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        // An empty spoken form would match at every position in every
        // transcript, so it is refused rather than stored and worked around.
        guard normalized.allSatisfy({ !$0.spoken.isEmpty }) else { return 0 }
        var proposed = replacements
        proposed.append(
            contentsOf: normalized.map { candidate in
                MacTextReplacement(
                    spoken: candidate.spoken,
                    written: candidate.written,
                    isEnabled: true,
                    matchesWholeWordsOnly: true
                )
            }
        )
        guard persist(proposed) else { return 0 }
        replacements = proposed
        return normalized.count
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        let proposed = replacements.filter { $0.id != id }
        guard proposed.count != replacements.count else { return false }
        guard persist(proposed) else { return false }
        replacements = proposed
        return true
    }

    /// Edits an existing rule in place. A rule that is no longer in the list is
    /// not resurrected: removal is the user's more recent intent.
    @discardableResult
    func update(_ replacement: MacTextReplacement) -> Bool {
        guard let index = replacements.firstIndex(where: { $0.id == replacement.id }) else {
            return false
        }
        var edited = replacement
        edited.spoken = replacement.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.written = replacement.written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.spoken.isEmpty else { return false }
        var proposed = replacements
        proposed[index] = edited
        guard persist(proposed) else { return false }
        replacements = proposed
        return true
    }

    @discardableResult
    private func persist(_ proposed: [MacTextReplacement]) -> Bool {
        guard let fileURL else {
            lastPersistenceError = "Application Support is unavailable."
            return false
        }
        if let blockedExistingDocumentReason {
            let existingFileWasRemoved: Bool
            do {
                existingFileWasRemoved = try !MacPrivateStoreIO
                    .existingRegularFileIsPresent(at: fileURL)
            } catch {
                existingFileWasRemoved = false
            }
            guard existingFileWasRemoved else {
                lastPersistenceError = blockedExistingDocumentReason
                return false
            }
            self.blockedExistingDocumentReason = nil
        }

        do {
            let encoder = JSONEncoder()
            // The file is meant to be legible to whoever opens it, and stable
            // enough that a backup diff shows only what actually changed.
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                StoredReplacements(
                    schemaVersion: StoredReplacements.currentSchemaVersion,
                    replacements: proposed
                )
            )
            try MacPrivateStoreIO.writeAtomically(data, to: fileURL)
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = error.localizedDescription
            return false
        }
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

    private static func load(from fileURL: URL?) -> MacReplacementLoadResult {
        guard let fileURL else {
            return MacReplacementLoadResult(
                replacements: [],
                warning: "Application Support is unavailable; replacement changes cannot be saved.",
                blockedExistingDocumentReason: nil
            )
        }
        let data: Data
        do {
            guard let loaded = try MacPrivateStoreIO.readExistingData(at: fileURL) else {
                return MacReplacementLoadResult(
                    replacements: [],
                    warning: nil,
                    blockedExistingDocumentReason: nil
                )
            }
            data = loaded
        } catch {
            let warning = "Replacement storage is unsafe or unreadable; it was left untouched and replacement changes are blocked."
            return MacReplacementLoadResult(
                replacements: [],
                warning: warning,
                blockedExistingDocumentReason: warning
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return blockedReplacementLoad(
                "Replacements are malformed; they were left untouched and replacement changes are blocked."
            )
        }

        let stored: [MacTextReplacement]
        if let legacy = object as? [Any] {
            guard
                replacementObjectsHaveExactFields(legacy),
                let decoded = try? JSONDecoder().decode([MacTextReplacement].self, from: data)
            else {
                return blockedReplacementLoad(
                    "Replacements use unsupported fields or are malformed; they were left untouched and replacement changes are blocked."
                )
            }
            stored = decoded
        } else {
            guard
                let documentObject = object as? [String: Any],
                Set(documentObject.keys) == Set(["schemaVersion", "replacements"]),
                let rawReplacements = documentObject["replacements"] as? [Any],
                replacementObjectsHaveExactFields(rawReplacements),
                let document = try? JSONDecoder().decode(StoredReplacements.self, from: data)
            else {
                return blockedReplacementLoad(
                    "Replacements use unsupported fields or are malformed; they were left untouched and replacement changes are blocked."
                )
            }
            guard document.schemaVersion == StoredReplacements.currentSchemaVersion else {
                return blockedReplacementLoad(
                    "Replacements use unsupported schema \(document.schemaVersion); they were left untouched and replacement changes are blocked."
                )
            }
            stored = document.replacements
        }

        guard validatedStoredReplacements(stored) else {
            return blockedReplacementLoad(
                "Replacements contain unsupported or damaged entries; they were left untouched and replacement changes are blocked."
            )
        }
        return MacReplacementLoadResult(
            replacements: stored,
            warning: nil,
            blockedExistingDocumentReason: nil
        )
    }

    private static func replacementObjectsHaveExactFields(_ values: [Any]) -> Bool {
        let expected = Set([
            "id",
            "spoken",
            "written",
            "isEnabled",
            "matchesWholeWordsOnly",
        ])
        return values.allSatisfy { value in
            guard let object = value as? [String: Any] else { return false }
            return Set(object.keys) == expected
        }
    }

    private static func validatedStoredReplacements(_ values: [MacTextReplacement]) -> Bool {
        guard values.count <= maximumReplacements else { return false }
        var ids = Set<UUID>()
        return values.allSatisfy { replacement in
            !replacement.spoken.isEmpty
                && replacement.spoken
                    == replacement.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                && replacement.written
                    == replacement.written.trimmingCharacters(in: .whitespacesAndNewlines)
                && ids.insert(replacement.id).inserted
        }
    }

    private static func blockedReplacementLoad(_ message: String) -> MacReplacementLoadResult {
        MacReplacementLoadResult(
            replacements: [],
            warning: message,
            blockedExistingDocumentReason: message
        )
    }
}

private struct StoredReplacements: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let replacements: [MacTextReplacement]
}

private struct MacReplacementLoadResult {
    let replacements: [MacTextReplacement]
    let warning: String?
    let blockedExistingDocumentReason: String?
}

/// Transcript content after deterministic substitutions and spoken formatting,
/// but before it is fitted against whatever is actually at the insertion point.
/// Keeping the seam decision separate lets queued chunks use the field's live
/// text rather than the stale text captured when recording began.
struct MacPreparedTranscriptChunk: Equatable, Sendable {
    let text: String
    /// A configured replacement at the first character owns its exact casing,
    /// even when the chunk is eventually inserted at a sentence boundary.
    let preservesLeadingReplacementCase: Bool
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
        precedingText: String?,
        spokenFormattingCommands: Bool = true
    ) -> String {
        fit(
            prepare(
                transcript,
                replacements: replacements,
                spokenFormattingCommands: spokenFormattingCommands
            ),
            after: precedingText
        )
    }

    /// Applies every transformation intrinsic to one transcript while leaving
    /// spacing and sentence casing open until its real delivery context exists.
    static func prepare(
        _ transcript: String,
        replacements: [MacTextReplacement],
        spokenFormattingCommands: Bool = true
    ) -> MacPreparedTranscriptChunk {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MacPreparedTranscriptChunk(
                text: "",
                preservesLeadingReplacementCase: false
            )
        }
        let substitution = substitute(
            trimmed,
            using: replacements.filter { $0.isEnabled && !$0.spoken.isEmpty }
        )
        let formatted = spokenFormattingCommands
            ? applySpokenFormattingCommands(substitution.text)
            : substitution.text
        return MacPreparedTranscriptChunk(
            text: formatted,
            preservesLeadingReplacementCase: substitution.startsWithExactReplacement
        )
    }

    /// Fits one prepared chunk against the field text observed at delivery.
    /// A silent recording must not push a stray space into the field.
    static func fit(
        _ chunk: MacPreparedTranscriptChunk,
        after actualPrecedingText: String?
    ) -> String {
        guard !chunk.text.isEmpty else { return "" }
        return join(
            chunk.text,
            after: actualPrecedingText,
            preservesLeadingReplacementCase: chunk.preservesLeadingReplacementCase
        )
    }

    /// Fits an ordered run as one insertion while carrying each fitted chunk
    /// forward as the real context for the next seam. The returned value is
    /// only the new insertion text; `precedingText` is not repeated.
    static func fold(
        _ chunks: [MacPreparedTranscriptChunk],
        after precedingText: String?
    ) -> String {
        var insertion = ""
        var actualPrecedingText = precedingText ?? ""
        for chunk in chunks {
            let fitted = fit(chunk, after: actualPrecedingText)
            insertion.append(fitted)
            actualPrecedingText.append(fitted)
        }
        return insertion
    }

    /// The small deterministic command set that does not require a second
    /// language model. Scribe already handles punctuation and backtracking; the
    /// missing piece is layout that cannot be represented in ordinary speech.
    private static func applySpokenFormattingCommands(_ text: String) -> String {
        let commands: [(String, String)] = [
            (#"(?i)[ \t]*\bnew paragraph\b[,.]?[ \t]*"#, "\n\n"),
            (#"(?i)[ \t]*\bnew line\b[,.]?[ \t]*"#, "\n"),
            (#"(?i)[ \t]*\b(?:bullet point|new bullet)\b[,.]?[ \t]*"#, "\n• "),
            (#"(?i)\bopen parenthesis\b[ \t]*"#, "("),
            (#"(?i)[ \t]*\bclose parenthesis\b"#, ")"),
            (#"(?i)\bopen bracket\b[ \t]*"#, "["),
            (#"(?i)[ \t]*\bclose bracket\b"#, "]"),
        ]
        var result = text
        for (pattern, replacement) in commands {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
        return result
            .replacingOccurrences(of: "\n \n", with: "\n\n")
            // The transcript itself was already trimmed before command
            // expansion. Newlines at either edge now represent commands the
            // user deliberately spoke and must survive delivery.
            .trimmingCharacters(in: .whitespaces)
    }

    private struct SubstitutionResult {
        let text: String
        /// A replacement at the first character owns its exact casing. This is
        /// how configured spellings such as `iPhone` and `eBay` survive the
        /// otherwise useful sentence-start capitalization pass.
        let startsWithExactReplacement: Bool
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
    private static func substitute(
        _ text: String,
        using replacements: [MacTextReplacement]
    ) -> SubstitutionResult {
        guard !replacements.isEmpty else {
            return SubstitutionResult(text: text, startsWithExactReplacement: false)
        }
        var result = ""
        var cursor = text.startIndex
        var startsWithExactReplacement = false
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
            if result.isEmpty,
               match.range.lowerBound == text.startIndex,
               !match.written.isEmpty {
                startsWithExactReplacement = true
            }
            result.append(match.written)
            cursor = match.range.upperBound
        }

        result.append(contentsOf: text[cursor...])
        return SubstitutionResult(
            text: result,
            startsWithExactReplacement: startsWithExactReplacement
        )
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
    private static func join(
        _ text: String,
        after precedingText: String?,
        preservesLeadingReplacementCase: Bool
    ) -> String {
        let sentenceCased = {
            preservesLeadingReplacementCase ? text : capitalizingFirstCharacter(text)
        }

        // A leading newline can only have been generated by an explicit spoken
        // layout command because raw API whitespace was trimmed before this
        // stage. It replaces ordinary inter-word spacing rather than following
        // it. Paragraphs begin a sentence; a single line break inherits sentence
        // casing from the text behind the caret.
        if text.first == "\n" {
            guard let precedingText, !precedingText.isEmpty else {
                return sentenceCased()
            }
            let beginsSentence = text.hasPrefix("\n\n")
                || startsNewSentence(before: precedingText)
            return beginsSentence ? sentenceCased() : text
        }

        guard let precedingText, let last = precedingText.last else {
            return sentenceCased()
        }
        if last.isWhitespace {
            // The space is already there; only the case is still open, and the
            // whitespace itself says nothing about it.
            return startsNewSentence(before: precedingText) ? sentenceCased() : text
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
            return " " + sentenceCased()
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
        guard let firstIndex = text.firstIndex(where: { !$0.isWhitespace }) else { return text }
        let first = text[firstIndex]
        guard first.isLowercase else { return text }

        // Scribe can already return mixed-case proper names. Uppercasing only
        // their first letter turns iPhone/macOS/eBay into incorrect spellings.
        // Plain lower-case words still receive normal sentence casing.
        var index = text.index(after: firstIndex)
        while index < text.endIndex, isWordCharacter(text[index]) {
            if text[index].isUppercase { return text }
            index = text.index(after: index)
        }

        // Non-locale casing keeps the result identical everywhere, which is
        // what makes this function testable without a locale fixture.
        return text[..<firstIndex]
            + String(first).uppercased()
            + text[text.index(after: firstIndex)...]
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
