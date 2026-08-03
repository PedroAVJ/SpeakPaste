import Combine
import Foundation

/// The words a person uses that a general model has never heard: colleagues'
/// names, product names, acronyms, code identifiers. They ride along with every
/// transcription as Scribe keyterms so recognition is biased toward them.
///
/// The list is a JSON file rather than a defaults blob on purpose. It is the
/// one piece of SpeakPaste state worth bulk-editing, diffing, or copying
/// between machines, and a text editor is the right tool for that.
@MainActor
final class MacVocabularyStore: ObservableObject {
    @Published private(set) var terms: [String] = []

    /// Scribe's documented batch limits. Breaching any of them rejects the
    /// whole request — the transcription is lost, not just the offending term —
    /// so they are enforced on the way in rather than discovered on the wire.
    nonisolated static let maximumTerms = 1000
    nonisolated static let maximumCharactersPerTerm = 50
    nonisolated static let maximumWordsPerTerm = 5

    /// Nil when Application Support could not be resolved or created. The list
    /// still works for the session; it just will not outlive it.
    private let fileURL: URL?

    /// `directory` exists so the list can be exercised against a scratch folder
    /// instead of the real Application Support, matching `MacHistoryStore`.
    /// Production callers use the default.
    init(directory: URL? = nil) {
        fileURL = Self.storedFileURL(in: directory)
        terms = Self.normalized(Self.decodedTerms(at: fileURL))
    }

    /// Returns whether the term was stored. Invalid and case-insensitively
    /// duplicate terms are refused, as is anything past the batch limit.
    @discardableResult
    func add(_ term: String) -> Bool {
        let candidate = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validationFailure(for: candidate) == nil else { return false }
        guard terms.count < Self.maximumTerms else { return false }
        let key = Self.duplicateKey(candidate)
        guard !terms.contains(where: { Self.duplicateKey($0) == key }) else { return false }

        terms = Self.sortedForDisplay(terms + [candidate])
        persist()
        return true
    }

    /// Matches case-insensitively, so removing a term always undoes adding that
    /// same term regardless of how either was capitalized.
    func remove(_ term: String) {
        let key = Self.duplicateKey(term)
        let remaining = terms.filter { Self.duplicateKey($0) != key }
        guard remaining.count != terms.count else { return }

        terms = remaining
        persist()
    }

    func replaceAll(_ terms: [String]) {
        self.terms = Self.normalized(terms)
        persist()
    }

    /// Accepts a pasted list separated by newlines, commas, or both, and
    /// returns how many terms were actually stored. Blanks, over-long entries,
    /// and terms already present are skipped rather than failing the paste, so
    /// one bad line in a hundred does not cost the other ninety-nine.
    @discardableResult
    func importDelimited(_ raw: String) -> Int {
        var keys = Set(terms.map { Self.duplicateKey($0) })
        var merged = terms

        for piece in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            guard merged.count < Self.maximumTerms else { break }
            let candidate = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                Self.validationFailure(for: candidate) == nil,
                keys.insert(Self.duplicateKey(candidate)).inserted
            else {
                continue
            }
            merged.append(candidate)
        }

        let added = merged.count - terms.count
        guard added > 0 else { return 0 }

        terms = Self.sortedForDisplay(merged)
        persist()
        return added
    }

    /// The keyterms to send with a transcription. The cap is applied again here
    /// because the backing file is meant to be hand-edited: a person who pastes
    /// two thousand lines into it should lose the overflow, not every dictation
    /// until they notice.
    var keytermsForRequest: [String] {
        Array(terms.prefix(Self.maximumTerms))
    }

    /// A reason the term cannot be stored, phrased for display, or nil when it
    /// is acceptable.
    nonisolated static func validationFailure(for term: String) -> String? {
        let candidate = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            return "Enter a word or phrase."
        }
        if candidate.count > maximumCharactersPerTerm {
            return "Terms are limited to \(maximumCharactersPerTerm) characters."
        }
        if candidate.split(whereSeparator: \.isWhitespace).count > maximumWordsPerTerm {
            return "Terms are limited to \(maximumWordsPerTerm) words."
        }
        return nil
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        // One term per line, because the point of keeping this outside
        // UserDefaults is that a person can open it and read it.
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(terms) else { return }
        // The directory exists as of launch, but the file is advertised as
        // hand-editable — someone who moves or clears the SpeakPaste folder
        // mid-session would otherwise lose every edit made afterwards, with an
        // atomic write that fails silently.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Trims, drops what Scribe would reject, collapses case-insensitive
    /// duplicates, and caps the list, so `terms` is always exactly what would
    /// go on the wire.
    private nonisolated static func normalized(_ candidates: [String]) -> [String] {
        var accepted: [String] = []
        var keys = Set<String>()

        for candidate in candidates {
            guard accepted.count < maximumTerms else { break }
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                validationFailure(for: term) == nil,
                keys.insert(duplicateKey(term)).inserted
            else {
                continue
            }
            accepted.append(term)
        }

        return sortedForDisplay(accepted)
    }

    /// Finder-style ordering: case-insensitive, and never reports two different
    /// terms as equal, so the displayed order is deterministic.
    private nonisolated static func sortedForDisplay(_ terms: [String]) -> [String] {
        terms.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private nonisolated static func duplicateKey(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A missing or unreadable file is an empty vocabulary, never an error: a
    /// corrupt list must not be able to stop the user from dictating.
    private static func decodedTerms(at url: URL?) -> [String] {
        guard
            let url,
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return stored
    }

    private static func storedFileURL(in directory: URL?) -> URL? {
        let manager = FileManager.default
        let container: URL
        if let directory {
            container = directory
        } else {
            guard
                let support = try? manager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            else {
                return nil
            }
            container = support.appending(path: "SpeakPaste", directoryHint: .isDirectory)
        }

        do {
            try manager.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return container.appending(path: "vocabulary.json", directoryHint: .notDirectory)
    }
}
