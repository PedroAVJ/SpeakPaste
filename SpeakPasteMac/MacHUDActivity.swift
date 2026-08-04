import Combine
import Foundation

/// SF Symbols used for held-output state. Both preferred symbols predate the
/// macOS 14 deployment floor. The runtime fallback keeps a misspelled or
/// unexpectedly unavailable symbol from turning the HUD into an empty glyph.
enum MacHUDHeldSymbol {
    static let clipboard = "clipboard.fill"
    static let recovery = "doc.text.fill"
    static let fallback = "doc.fill"

    static func systemName(
        clipboardBacked: Bool,
        isAvailable: (String) -> Bool
    ) -> String {
        let preferred = clipboardBacked ? clipboard : recovery
        return isAvailable(preferred) ? preferred : fallback
    }
}

/// The microphone-facing portion of one HUD card.
enum MacHUDCaptureActivity: Equatable, Sendable {
    case inactive
    case connecting
    case listening
    case releasing
}

/// Runtime-only presentation state for every dictation that still matters to
/// the floating HUD. Its identifiers are deliberately independent of History,
/// recovery-journal, and network-attempt identifiers: one card keeps this ID
/// from the first connection pulse through transcription, held output, or
/// verified delivery.
struct MacHUDPipeline: Equatable, Sendable {
    struct Capture: Equatable, Sendable {
        let id: UUID
        let ordinal: Int?
        var activity: MacHUDCaptureActivity
        var stageStartedAt: Date
    }

    enum DictationStage: Equatable, Sendable {
        case transcribing
        /// The network result is ready but an older spoken ticket still owns
        /// the delivery turn. Keeping this stage visible closes the old hole
        /// where an out-of-order result vanished before it could be inserted.
        case awaitingDelivery
        case held
    }

    struct Dictation: Equatable, Identifiable, Sendable {
        let id: UUID
        let ordinal: Int?
        let createdAt: Date
        var stage: DictationStage
        var stageStartedAt: Date
        var transcribingStartedAt: Date
        var recordingDuration: TimeInterval
    }

    private(set) var capture: Capture?
    private(set) var dictations: [Dictation] = []

    var heldIDs: [UUID] {
        orderedDictations
            .filter { $0.stage == .held }
            .map(\.id)
    }

    var orderedDictations: [Dictation] {
        dictations.enumerated().sorted { lhs, rhs in
            Self.isOlder(lhs.element, than: rhs.element, lhsOffset: lhs.offset, rhsOffset: rhs.offset)
        }.map(\.element)
    }

    mutating func beginCapture(
        id: UUID,
        ordinal: Int?,
        at date: Date = Date()
    ) {
        capture = Capture(
            id: id,
            ordinal: ordinal,
            activity: .connecting,
            stageStartedAt: date
        )
    }

    mutating func updateCapture(
        id: UUID,
        activity: MacHUDCaptureActivity,
        at date: Date = Date()
    ) {
        guard var current = capture, current.id == id else { return }
        guard current.activity != activity else { return }
        current.activity = activity
        current.stageStartedAt = date
        capture = current
    }

    mutating func discardCapture(id: UUID?) {
        guard let id, capture?.id == id else { return }
        capture = nil
    }

    mutating func beginTranscription(
        id: UUID,
        ordinal: Int?,
        recordingDuration: TimeInterval,
        createdAt: Date,
        at date: Date = Date()
    ) {
        discardCapture(id: id)
        let duration = recordingDuration.isFinite ? max(0, recordingDuration) : 0
        if let index = dictations.firstIndex(where: { $0.id == id }) {
            dictations[index].stage = .transcribing
            dictations[index].stageStartedAt = date
            dictations[index].transcribingStartedAt = date
            dictations[index].recordingDuration = duration
            return
        }
        dictations.append(
            Dictation(
                id: id,
                ordinal: ordinal,
                createdAt: createdAt,
                stage: .transcribing,
                stageStartedAt: date,
                transcribingStartedAt: date,
                recordingDuration: duration
            )
        )
    }

    mutating func markAwaitingDelivery(id: UUID, at date: Date = Date()) {
        guard let index = dictations.firstIndex(where: { $0.id == id }) else { return }
        guard dictations[index].stage != .held else { return }
        dictations[index].stage = .awaitingDelivery
        dictations[index].stageStartedAt = date
    }

    mutating func markHeld(
        id: UUID,
        ordinal: Int? = nil,
        createdAt: Date = Date(),
        recordingDuration: TimeInterval = 0,
        at date: Date = Date()
    ) {
        if let index = dictations.firstIndex(where: { $0.id == id }) {
            dictations[index].stage = .held
            dictations[index].stageStartedAt = date
            return
        }
        dictations.append(
            Dictation(
                id: id,
                ordinal: ordinal,
                createdAt: createdAt,
                stage: .held,
                stageStartedAt: date,
                transcribingStartedAt: date,
                recordingDuration: recordingDuration.isFinite
                    ? max(0, recordingDuration)
                    : 0
            )
        )
    }

    mutating func finish(id: UUID) {
        if capture?.id == id { capture = nil }
        dictations.removeAll { $0.id == id }
    }

    mutating func finish(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let capture, ids.contains(capture.id) { self.capture = nil }
        dictations.removeAll { ids.contains($0.id) }
    }

    private static func isOlder(
        _ lhs: Dictation,
        than rhs: Dictation,
        lhsOffset: Int,
        rhsOffset: Int
    ) -> Bool {
        switch (lhs.ordinal, rhs.ordinal) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return false
        case (nil, _?):
            return true
        default:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhsOffset < rhsOffset
        }
    }
}

/// The resolved, bounded depth stack consumed by SwiftUI. It is a projection
/// of the full pipeline, never the authority for delivery state.
struct MacHUDStack: Equatable, Sendable {
    enum CardContent: Equatable, Sendable {
        case capture(MacHUDCaptureActivity)
        case transcription(
            stage: MacHUDPipeline.DictationStage,
            enqueuedAt: Date,
            recordingDuration: TimeInterval
        )
        /// One just-finished chunk could not leave safely. Durable queue
        /// depth belongs to the dashboard; the floating HUD reports only the
        /// current event and never becomes a notification counter.
        case held
    }

    struct Card: Equatable, Identifiable, Sendable {
        let id: UUID
        let content: CardContent
        /// Zero is frontmost. Depth drives scale, lift, and dimming.
        let depth: Int
        /// Work folded between the front and the oldest visible rear cards.
        let hiddenDeeperCount: Int
        let ordinal: Int?
    }

    static let visibleCardBudget = 3
    static let connectingVisibilityCap: TimeInterval = 20
    static let releasingVisibilityCap: TimeInterval = 15
    static let transcriptionVisibilityCap: TimeInterval = 90
    static let heldVisibilityCap: TimeInterval = 2
    static let empty = MacHUDStack(
        cards: [],
        totalTranscriptionCount: 0,
        hasTransientHold: false
    )

    /// Front-to-back. The rearmost visible work is always the oldest, which is
    /// the next spoken ticket eligible to deliver.
    let cards: [Card]
    let totalTranscriptionCount: Int
    let hasTransientHold: Bool

    var isEmpty: Bool { cards.isEmpty }
    var liveDictationCount: Int { totalTranscriptionCount }
    var frontIsReleasing: Bool {
        cards.first?.content == .capture(.releasing)
    }

    static func resolve(
        pipeline: MacHUDPipeline,
        at date: Date = Date()
    ) -> MacHUDStack {
        struct Entry {
            let id: UUID
            let content: CardContent
            let ordinal: Int?
            let createdAt: Date
        }

        let activeDictations = pipeline.orderedDictations.filter { dictation in
            switch dictation.stage {
            case .held:
                date.timeIntervalSince(dictation.stageStartedAt)
                    < heldVisibilityCap
            case .transcribing, .awaitingDelivery:
                date.timeIntervalSince(dictation.transcribingStartedAt)
                    < transcriptionVisibilityCap
            }
        }
        let held = activeDictations.filter { $0.stage == .held }
        let transcribing = activeDictations.filter { $0.stage != .held }

        var oldestFirst: [Entry] = transcribing.map { dictation in
            Entry(
                id: dictation.id,
                content: .transcription(
                    stage: dictation.stage,
                    enqueuedAt: dictation.transcribingStartedAt,
                    recordingDuration: dictation.recordingDuration
                ),
                ordinal: dictation.ordinal,
                createdAt: dictation.createdAt
            )
        }
        // Several chunks may become held close together, but the HUD reports
        // only the newest event. The ordered queue stays in the dashboard.
        if let newestHeld = held.max(by: { lhs, rhs in
            if lhs.stageStartedAt == rhs.stageStartedAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.stageStartedAt < rhs.stageStartedAt
        }) {
            oldestFirst.append(
                Entry(
                    id: newestHeld.id,
                    content: .held,
                    ordinal: newestHeld.ordinal,
                    createdAt: newestHeld.createdAt
                )
            )
        }
        oldestFirst.sort { lhs, rhs in
            switch (lhs.ordinal, rhs.ordinal) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return false
            case (nil, _?):
                return true
            default:
                return lhs.createdAt < rhs.createdAt
            }
        }

        var frontToBack = Array(oldestFirst.reversed())
        if let capture = visibleCapture(in: pipeline, at: date) {
            frontToBack.insert(
                Entry(
                    id: capture.id,
                    content: .capture(capture.activity),
                    ordinal: capture.ordinal,
                    createdAt: capture.stageStartedAt
                ),
                at: 0
            )
        }
        guard !frontToBack.isEmpty else { return .empty }

        let visible: [Entry]
        let hiddenCount: Int
        if frontToBack.count <= visibleCardBudget {
            visible = frontToBack
            hiddenCount = 0
        } else {
            // Keep the semantic front plus the two oldest cards. Hidden middle
            // work is summarized on the oldest/rearmost visible surface.
            visible = [frontToBack[0]] + frontToBack.suffix(visibleCardBudget - 1)
            hiddenCount = frontToBack.count - visibleCardBudget
        }

        return MacHUDStack(
            cards: visible.enumerated().map { depth, entry in
                Card(
                    id: entry.id,
                    content: entry.content,
                    depth: depth,
                    hiddenDeeperCount: depth == visible.count - 1 ? hiddenCount : 0,
                    ordinal: entry.ordinal
                )
            },
            totalTranscriptionCount: transcribing.count,
            hasTransientHold: !held.isEmpty
        )
    }

    static func nextExpiry(
        in pipeline: MacHUDPipeline,
        after date: Date = Date()
    ) -> Date? {
        var deadlines = pipeline.dictations.compactMap { dictation -> Date? in
            let deadline: Date
            switch dictation.stage {
            case .held:
                deadline = dictation.stageStartedAt.addingTimeInterval(
                    heldVisibilityCap
                )
            case .transcribing, .awaitingDelivery:
                deadline = dictation.transcribingStartedAt.addingTimeInterval(
                    transcriptionVisibilityCap
                )
            }
            return deadline > date ? deadline : nil
        }
        if let capture = pipeline.capture {
            let cap: TimeInterval?
            switch capture.activity {
            case .connecting:
                cap = connectingVisibilityCap
            case .releasing:
                cap = releasingVisibilityCap
            case .listening, .inactive:
                cap = nil
            }
            if let cap {
                let deadline = capture.stageStartedAt.addingTimeInterval(cap)
                if deadline > date { deadlines.append(deadline) }
            }
        }
        return deadlines.min()
    }

    func accessibilityLabel(
        sourceName: String?,
        heldClipboardBacked: Bool = false
    ) -> String {
        var parts = ["SpeakPaste"]
        if case .capture(let activity) = cards.first?.content {
            switch activity {
            case .connecting:
                parts.append("Connecting")
            case .listening:
                parts.append("Listening")
            case .releasing:
                parts.append("Releasing the microphone")
            case .inactive:
                break
            }
            if let sourceName { parts.append(sourceName) }
        }
        if totalTranscriptionCount == 1 {
            parts.append("1 dictation transcribing")
        } else if totalTranscriptionCount > 1 {
            parts.append("\(totalTranscriptionCount) dictations transcribing")
        }
        if hasTransientHold {
            parts.append("Dictation held")
            if heldClipboardBacked {
                parts.append("The held dictation is on the clipboard")
            }
        }
        return parts.joined(separator: ", ")
    }

    static func publisher<Pipeline: Publisher>(
        _ pipeline: Pipeline
    ) -> AnyPublisher<MacHUDStack, Never>
    where Pipeline.Output == MacHUDPipeline, Pipeline.Failure == Never {
        pipeline
            .map { resolve(pipeline: $0) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private static func visibleCapture(
        in pipeline: MacHUDPipeline,
        at date: Date
    ) -> MacHUDPipeline.Capture? {
        guard let capture = pipeline.capture, capture.activity != .inactive else {
            return nil
        }
        let elapsed = date.timeIntervalSince(capture.stageStartedAt)
        switch capture.activity {
        case .connecting where elapsed >= connectingVisibilityCap:
            return nil
        case .releasing where elapsed >= releasingVisibilityCap:
            return nil
        default:
            return capture
        }
    }
}
