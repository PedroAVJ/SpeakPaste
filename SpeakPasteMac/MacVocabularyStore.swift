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
    @Published private(set) var lastPersistenceError: String?

    /// Scribe's documented batch limits. Breaching any of them rejects the
    /// whole request — the transcription is lost, not just the offending term —
    /// so they are enforced on the way in rather than discovered on the wire.
    nonisolated static let maximumTerms = 1000
    /// The API contract is strictly fewer than 50 characters.
    nonisolated static let maximumCharactersPerTerm = 49
    nonisolated static let maximumWordsPerTerm = 5

    /// Nil when Application Support could not be resolved or created. The list
    /// still works for the session; it just will not outlive it.
    private let fileURL: URL?
    /// A document we could not fully interpret is never overwritten in place.
    /// Removing it outside SpeakPaste is the explicit recovery boundary.
    private var blockedExistingDocumentReason: String?

    /// `directory` exists so the list can be exercised against a scratch folder
    /// instead of the real Application Support, matching `MacHistoryStore`.
    /// Production callers use the default.
    init(directory: URL? = nil) {
        let resolvedFileURL = Self.storedFileURL(in: directory)
        fileURL = resolvedFileURL
        let loaded = Self.load(from: resolvedFileURL)
        let permissionWarning: String?
        if loaded.blockedExistingDocumentReason == nil {
            do {
                try MacPrivateStoreIO.secureExistingStorage(at: resolvedFileURL)
                permissionWarning = nil
            } catch {
                permissionWarning = "Could not secure vocabulary storage: \(error.localizedDescription)"
            }
        } else {
            permissionWarning = nil
        }
        terms = loaded.terms
        blockedExistingDocumentReason = loaded.blockedExistingDocumentReason
            ?? permissionWarning
        let messages = [permissionWarning, loaded.warning].compactMap { $0 }
        lastPersistenceError = messages.isEmpty ? nil : messages.joined(separator: " ")
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

        let proposed = Self.sortedForDisplay(terms + [candidate])
        guard persist(proposed) else { return false }
        terms = proposed
        return true
    }

    /// Matches case-insensitively, so removing a term always undoes adding that
    /// same term regardless of how either was capitalized.
    @discardableResult
    func remove(_ term: String) -> Bool {
        let key = Self.duplicateKey(term)
        let remaining = terms.filter { Self.duplicateKey($0) != key }
        guard remaining.count != terms.count else { return false }

        guard persist(remaining) else { return false }
        terms = remaining
        return true
    }

    @discardableResult
    func replaceAll(_ terms: [String]) -> Bool {
        let proposed = Self.normalized(terms)
        guard persist(proposed) else { return false }
        self.terms = proposed
        return true
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

        let proposed = Self.sortedForDisplay(merged)
        guard persist(proposed) else { return 0 }
        terms = proposed
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
            return "Terms must be fewer than 50 characters."
        }
        if candidate.split(whereSeparator: \.isWhitespace).count > maximumWordsPerTerm {
            return "Terms are limited to \(maximumWordsPerTerm) words."
        }
        let unsupported = CharacterSet(charactersIn: "<>{}[]\\")
            .union(.controlCharacters)
        if candidate.rangeOfCharacter(from: unsupported) != nil {
            return "Scribe keyterms cannot contain <, >, {, }, [, ], backslashes, or control characters."
        }
        return nil
    }

    @discardableResult
    private func persist(_ proposed: [String]) -> Bool {
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
            // One term per line, because the point of keeping this outside
            // UserDefaults is that a person can open it and read it.
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                StoredVocabulary(
                    schemaVersion: StoredVocabulary.currentSchemaVersion,
                    terms: proposed
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

    private static func load(from fileURL: URL?) -> MacVocabularyLoadResult {
        guard let fileURL else {
            return MacVocabularyLoadResult(
                terms: [],
                warning: "Application Support is unavailable; vocabulary changes cannot be saved.",
                blockedExistingDocumentReason: nil
            )
        }
        let data: Data
        do {
            guard let loaded = try MacPrivateStoreIO.readExistingData(at: fileURL) else {
                return MacVocabularyLoadResult(
                    terms: [],
                    warning: nil,
                    blockedExistingDocumentReason: nil
                )
            }
            data = loaded
        } catch {
            let warning = "Vocabulary storage is unsafe or unreadable; it was left untouched and vocabulary changes are blocked."
            return MacVocabularyLoadResult(
                terms: [],
                warning: warning,
                blockedExistingDocumentReason: warning
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return blockedLoad("Vocabulary is malformed; it was left untouched and vocabulary changes are blocked.")
        }

        let storedTerms: [String]
        if object is [Any] {
            // Raw arrays are the format shipped by earlier builds. They remain
            // readable and migrate only after a successful user mutation.
            guard let legacy = try? JSONDecoder().decode([String].self, from: data) else {
                return blockedLoad("Vocabulary is malformed; it was left untouched and vocabulary changes are blocked.")
            }
            storedTerms = legacy
        } else {
            guard
                let documentObject = object as? [String: Any],
                Set(documentObject.keys) == Set(["schemaVersion", "terms"]),
                let document = try? JSONDecoder().decode(StoredVocabulary.self, from: data)
            else {
                return blockedLoad("Vocabulary uses unsupported fields or is malformed; it was left untouched and vocabulary changes are blocked.")
            }
            guard document.schemaVersion == StoredVocabulary.currentSchemaVersion else {
                return blockedLoad("Vocabulary uses unsupported schema \(document.schemaVersion); it was left untouched and vocabulary changes are blocked.")
            }
            storedTerms = document.terms
        }

        guard let validated = validatedStoredTerms(storedTerms) else {
            return blockedLoad("Vocabulary contains unsupported or damaged entries; it was left untouched and vocabulary changes are blocked.")
        }
        return MacVocabularyLoadResult(
            terms: validated,
            warning: nil,
            blockedExistingDocumentReason: nil
        )
    }

    private static func blockedLoad(_ message: String) -> MacVocabularyLoadResult {
        MacVocabularyLoadResult(
            terms: [],
            warning: message,
            blockedExistingDocumentReason: message
        )
    }

    private static func validatedStoredTerms(_ candidates: [String]) -> [String]? {
        guard candidates.count <= maximumTerms else { return nil }
        var keys = Set<String>()
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                candidate == trimmed,
                validationFailure(for: candidate) == nil,
                keys.insert(duplicateKey(candidate)).inserted
            else {
                return nil
            }
        }
        return sortedForDisplay(candidates)
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

        return container.appending(path: "vocabulary.json", directoryHint: .notDirectory)
    }
}

private struct StoredVocabulary: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let terms: [String]
}

private struct MacVocabularyLoadResult {
    let terms: [String]
    let warning: String?
    let blockedExistingDocumentReason: String?
}
