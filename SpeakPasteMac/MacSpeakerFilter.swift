import Foundation

/// The enrolled owner's voice, learned from their own dictations.
///
/// There is no calibration screen on purpose. Every clean single-voice
/// dictation is already a labelled sample of the person using the app, on the
/// microphone they actually use, in the speaking style they actually use —
/// including whispering, which sounds nothing like read-aloud enrollment
/// prompts and is exactly the case that needs to work.
struct MacSpeakerProfile: Codable, Equatable, Sendable {
    /// Enough samples to describe the normal spread of one voice without
    /// letting the profile drift on a single unusual dictation.
    static let capacity = 12
    /// Below this the spread estimate is meaningless, so no filtering happens.
    static let minimumEnrolled = 3

    private(set) var signatures: [MacVoiceSignature]

    init(signatures: [MacVoiceSignature] = []) {
        self.signatures = Array(signatures.suffix(Self.capacity))
    }

    var isEnrolled: Bool { signatures.count >= Self.minimumEnrolled }

    var centroid: MacVoiceSignature? {
        MacVoiceSignature.centroid(of: signatures)
    }

    /// The similarity a voice must reach to be treated as the owner.
    ///
    /// It is derived from how tightly the owner's own samples cluster rather
    /// than fixed, because that spread is the only available evidence of what
    /// "close enough" means for this voice on this microphone. Three deviations
    /// below the owner's mean self-similarity keeps their off days inside the
    /// boundary; the clamps stop a freakishly tight or loose cluster from
    /// producing a threshold that accepts everyone or no one.
    var acceptanceFloor: Double {
        guard isEnrolled, let centroid else { return 1 }
        let similarities = signatures.map { $0.similarity(to: centroid) }
        let mean = similarities.reduce(0, +) / Double(similarities.count)
        let variance = similarities
            .reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(similarities.count)
        let deviation = variance > 0 ? sqrt(variance) : 0
        return min(0.9, max(0.3, mean - 3 * deviation))
    }

    /// Appends one sample, retiring the oldest past capacity so the profile
    /// tracks the voice as a cold, a new microphone, or a new room changes it.
    mutating func enroll(_ signature: MacVoiceSignature) {
        signatures.append(signature)
        if signatures.count > Self.capacity {
            signatures.removeFirst(signatures.count - Self.capacity)
        }
    }
}

/// Decides which diarized speakers in a dictation belong to the person the app
/// is enrolled to, and rebuilds the transcript from only their words.
///
/// The policy is biased hard toward keeping text. Leaving a stray line of
/// someone else's speech in the transcript is an annoyance the user can see and
/// delete; silently deleting the words they actually dictated is data loss they
/// may not notice until the paste has already happened. Every ambiguous case
/// therefore resolves to "keep everything".
enum MacSpeakerFilter {
    enum Reason: Equatable, Sendable {
        /// The response carried no per-word speaker labels at all.
        case noDiarization
        /// One voice in the recording. Nothing to separate, and the only case
        /// that may contribute to enrollment.
        case singleSpeaker
        /// More than one voice, but no voiceprint to compare them against yet.
        case notEnrolled
        /// More than one voice, but the recording could not be re-read to
        /// characterize them.
        case unreadableAudio
        /// More than one voice and none of them resembled the enrolled owner.
        /// The owner may simply be absent, so the whole transcript stands.
        case noConfidentMatch
        /// At least one voice was recognized as the owner.
        case matched
    }

    struct Decision: Equatable, Sendable {
        let reason: Reason
        let keptSpeakerIDs: Set<String>
        let removedSpeakerIDs: Set<String>
        /// Similarity of each evaluated speaker to the enrolled voiceprint.
        /// Carried purely so the result is explainable after the fact.
        let scores: [String: Double]
        let acceptanceFloor: Double?

        var removedSomeone: Bool { !removedSpeakerIDs.isEmpty }
    }

    struct Outcome: Equatable, Sendable {
        let text: String
        let decision: Decision
        /// Set only when this dictation is a clean, single-voice sample that
        /// should strengthen the stored voiceprint.
        let enrollmentCandidate: MacVoiceSignature?
    }

    /// - Parameter makeSignature: produces a fingerprint for a set of time
    ///   spans in the recording, or nil when there is too little usable audio.
    ///   Injected rather than called directly so the policy stays testable
    ///   without a real audio file.
    static func apply(
        to result: TranscriptionResult,
        profile: MacSpeakerProfile,
        makeSignature: (_ ranges: [ClosedRange<TimeInterval>]) -> MacVoiceSignature?
    ) -> Outcome {
        let speakers = result.speakerIDs
        guard !speakers.isEmpty else {
            return unchanged(result, reason: .noDiarization)
        }

        let ranges = spokenRanges(in: result)

        if speakers.count == 1, let only = speakers.first {
            // A lone voice is kept whoever it belongs to: a guest dictating on
            // this Mac should get their words, not silence. It only feeds the
            // voiceprint when it plausibly is the owner — otherwise the first
            // visitor would quietly redefine who the app listens for.
            var candidate: MacVoiceSignature?
            if let signature = ranges[only].flatMap({ makeSignature($0) }) {
                if let centroid = profile.centroid, profile.isEnrolled {
                    let score = signature.similarity(to: centroid)
                    candidate = score >= profile.acceptanceFloor ? signature : nil
                } else {
                    candidate = signature
                }
            }
            return Outcome(
                text: result.text,
                decision: Decision(
                    reason: .singleSpeaker,
                    keptSpeakerIDs: speakers,
                    removedSpeakerIDs: [],
                    scores: [:],
                    acceptanceFloor: profile.isEnrolled ? profile.acceptanceFloor : nil
                ),
                enrollmentCandidate: candidate
            )
        }

        guard profile.isEnrolled, let centroid = profile.centroid else {
            return unchanged(result, reason: .notEnrolled)
        }

        var scores: [String: Double] = [:]
        for speaker in speakers {
            guard
                let speakerRanges = ranges[speaker],
                let signature = makeSignature(speakerRanges)
            else {
                continue
            }
            scores[speaker] = signature.similarity(to: centroid)
        }

        guard !scores.isEmpty else {
            return unchanged(result, reason: .unreadableAudio)
        }

        let floor = profile.acceptanceFloor
        guard let best = scores.values.max(), best >= floor else {
            return unchanged(result, reason: .noConfidentMatch, scores: scores, floor: floor)
        }

        // Every speaker at or above the floor is treated as the owner. One
        // person is routinely split across two labels when they change volume
        // mid-dictation, and a margin against the single best score would throw
        // half their sentence away.
        var kept = Set(scores.filter { $0.value >= floor }.keys)
        // A speaker whose audio could not be characterized is unproven, not
        // convicted. Keeping them costs at most a stray phrase.
        kept.formUnion(speakers.filter { scores[$0] == nil })

        let removed = speakers.subtracting(kept)
        guard !removed.isEmpty else {
            return Outcome(
                text: result.text,
                decision: Decision(
                    reason: .matched,
                    keptSpeakerIDs: kept,
                    removedSpeakerIDs: [],
                    scores: scores,
                    acceptanceFloor: floor
                ),
                enrollmentCandidate: nil
            )
        }

        // Filtering that leaves nothing behind is treated as a failed
        // separation, not as a transcript of silence. Whatever the speaker
        // labels claimed, the user did dictate something.
        let filtered = transcript(from: result.words, keeping: kept)
        guard !filtered.isEmpty else {
            return unchanged(result, reason: .noConfidentMatch, scores: scores, floor: floor)
        }

        return Outcome(
            text: filtered,
            decision: Decision(
                reason: .matched,
                keptSpeakerIDs: kept,
                removedSpeakerIDs: removed,
                scores: scores,
                acceptanceFloor: floor
            ),
            // Audio containing more than one voice never trains the voiceprint,
            // however confident the split looked.
            enrollmentCandidate: nil
        )
    }

    /// Time spans of actual spoken words, per speaker, merged into as few
    /// contiguous reads as possible.
    static func spokenRanges(
        in result: TranscriptionResult
    ) -> [String: [ClosedRange<TimeInterval>]] {
        var grouped: [String: [ClosedRange<TimeInterval>]] = [:]
        for word in result.words {
            guard
                word.kind == .word,
                let speaker = word.speakerID,
                let range = word.timeRange
            else {
                continue
            }
            grouped[speaker, default: []].append(range)
        }
        return grouped.mapValues { MacDictationAudioReader.mergedRanges($0) }
    }

    /// Rebuilds the transcript from the kept speakers' entries.
    ///
    /// Removing a speaker leaves the whitespace that surrounded them, so runs
    /// of spaces are collapsed. Line breaks survive: Scribe emits them where a
    /// real break belongs, and the spoken-formatting pass downstream still
    /// needs to see them.
    static func transcript(
        from words: [TranscribedWord],
        keeping kept: Set<String>
    ) -> String {
        var assembled = ""
        for word in words {
            guard word.kind.carriesTranscriptText else { continue }
            if let speaker = word.speakerID, !kept.contains(speaker) { continue }
            assembled += word.text
        }

        var collapsed = ""
        var pendingSpace = false
        for character in assembled {
            if character == " " || character == "\t" {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                if !collapsed.isEmpty, character != "\n" {
                    collapsed.append(" ")
                }
                pendingSpace = false
            }
            collapsed.append(character)
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unchanged(
        _ result: TranscriptionResult,
        reason: Reason,
        scores: [String: Double] = [:],
        floor: Double? = nil
    ) -> Outcome {
        Outcome(
            text: result.text,
            decision: Decision(
                reason: reason,
                keptSpeakerIDs: result.speakerIDs,
                removedSpeakerIDs: [],
                scores: scores,
                acceptanceFloor: floor
            ),
            enrollmentCandidate: nil
        )
    }
}
