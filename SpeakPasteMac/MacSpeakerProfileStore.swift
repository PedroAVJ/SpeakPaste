import Combine
import Foundation

/// Persists the enrolled voiceprint next to SpeakPaste's other private state.
///
/// The file holds derived numbers only — never audio, never transcripts — and
/// deleting it is a complete reset: the next few dictations re-enroll from
/// scratch.
@MainActor
final class MacSpeakerProfileStore: ObservableObject {
    @Published private(set) var profile: MacSpeakerProfile
    @Published private(set) var lastPersistenceError: String?

    /// Nil when Application Support could not be resolved. The profile still
    /// works for the session; it just will not outlive it.
    private let fileURL: URL?
    /// A document we could not interpret is never overwritten in place.
    private var blockedExistingDocumentReason: String?

    /// `directory` exists so the profile can be exercised against a scratch
    /// folder instead of the real Application Support, matching the other
    /// stores. Production callers use the default.
    init(directory: URL? = nil) {
        let resolvedFileURL = Self.storedFileURL(in: directory)
        fileURL = resolvedFileURL

        var warning: String?
        var blocked: String?
        var loaded = MacSpeakerProfile()
        do {
            if let data = try MacPrivateStoreIO.readExistingData(at: resolvedFileURL) {
                let document = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
                guard document.schemaVersion <= StoredSpeakerProfile.currentSchemaVersion else {
                    throw StoredSpeakerProfileError.newerSchema(document.schemaVersion)
                }
                loaded = MacSpeakerProfile(signatures: document.signatures)
            }
            try MacPrivateStoreIO.secureExistingStorage(at: resolvedFileURL)
        } catch let error as StoredSpeakerProfileError {
            blocked = error.message
        } catch {
            // A corrupt profile is recoverable by discarding it: the samples
            // are re-earned from ordinary use within a handful of dictations.
            // Refusing to write is reserved for a document from a future build,
            // which may hold state this one would destroy.
            warning = "The stored voice profile could not be read and will be rebuilt: \(error.localizedDescription)"
        }

        profile = loaded
        blockedExistingDocumentReason = blocked
        lastPersistenceError = blocked ?? warning
    }

    /// Records one clean sample of the owner's voice.
    @discardableResult
    func enroll(_ signature: MacVoiceSignature) -> Bool {
        var proposed = profile
        proposed.enroll(signature)
        return commit(proposed)
    }

    /// Forgets the enrolled voice entirely. Filtering stops until enough new
    /// dictations have accumulated.
    @discardableResult
    func reset() -> Bool {
        commit(MacSpeakerProfile())
    }

    private func commit(_ proposed: MacSpeakerProfile) -> Bool {
        if let blockedExistingDocumentReason {
            lastPersistenceError = blockedExistingDocumentReason
            return false
        }
        profile = proposed
        guard let fileURL else {
            lastPersistenceError = "The voice profile is in memory only; Application Support was unavailable."
            return false
        }
        do {
            let document = StoredSpeakerProfile(
                schemaVersion: StoredSpeakerProfile.currentSchemaVersion,
                signatures: proposed.signatures
            )
            let data = try JSONEncoder().encode(document)
            try MacPrivateStoreIO.writeAtomically(data, to: fileURL)
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = "The voice profile could not be saved: \(error.localizedDescription)"
            return false
        }
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

        return container.appending(path: "voice-profile.json", directoryHint: .notDirectory)
    }
}

private enum StoredSpeakerProfileError: LocalizedError {
    case newerSchema(Int)

    var message: String {
        switch self {
        case let .newerSchema(version):
            "The voice profile was written by a newer version of SpeakPaste (format \(version)). It will not be changed by this version."
        }
    }

    var errorDescription: String? { message }
}

private struct StoredSpeakerProfile: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let signatures: [MacVoiceSignature]
}
