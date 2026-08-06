import Combine
import Foundation

/// SF Symbols used for held-output state. Both preferred symbols predate the
/// macOS 14 deployment floor. The runtime fallback keeps a missing symbol from
/// turning the HUD into an empty capsule.
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

enum MacHUDCaptureActivity: Equatable, Sendable {
    case inactive
    case connecting
    case listening
    case releasing
}

/// The delivery gate for one user-owned dictation. Segment transcription may
/// complete in any order, but none of it is eligible for output until every
/// sequence in the closed dictation has produced a result.
struct MacOrderedDictationBatch: Equatable, Sendable {
    let sequences: Set<Int>

    var orderedSequences: [Int] { sequences.sorted() }

    func starts(at nextDeliverySequence: Int) -> Bool {
        orderedSequences.first == nextDeliverySequence
    }

    func isReady(completedSequences: Set<Int>) -> Bool {
        !sequences.isEmpty && sequences.isSubset(of: completedSequences)
    }
}

/// Runtime-only state for the floating indicator.
///
/// A segment is deliberately not a visual card. Several segments can be
/// transcribing behind one open dictation, but the HUD has one face because the
/// user still owns one message. Segment entries remain here only so the face can
/// stay in its draining state until every piece reaches the delivery boundary.
struct MacHUDPipeline: Equatable, Sendable {
    struct SourceNudge: Equatable, Sendable {
        let attempted: MacInputMode
        let live: MacInputMode?
        let startedAt: Date
    }

    struct Capture: Equatable, Sendable {
        /// Recorder request/segment identity. This may change on resume.
        let id: UUID
        let ordinal: Int?
        let source: MacInputMode
        var activity: MacHUDCaptureActivity
        var stageStartedAt: Date
    }

    enum FaceStage: Equatable, Sendable {
        case capture(
            source: MacInputMode,
            activity: MacHUDCaptureActivity,
            stageStartedAt: Date
        )
        case resting(startedAt: Date)
        case draining(startedAt: Date)
        case held(startedAt: Date)
    }

    struct Face: Equatable, Identifiable, Sendable {
        /// Stable for the whole dictation, including every pause and resume.
        let id: UUID
        let createdAt: Date
        var stage: FaceStage
    }

    enum DictationStage: Equatable, Sendable {
        case transcribing
        case awaitingDelivery
        case held
    }

    struct Dictation: Equatable, Identifiable, Sendable {
        /// Segment/work identity, not a HUD identity.
        let id: UUID
        var faceID: UUID?
        let ordinal: Int?
        let createdAt: Date
        var stage: DictationStage
        var stageStartedAt: Date
        var transcribingStartedAt: Date
        var recordingDuration: TimeInterval
    }

    private(set) var sourceNudge: SourceNudge?
    private(set) var face: Face?
    private(set) var capture: Capture?
    private(set) var dictations: [Dictation] = []

    var isDraining: Bool {
        guard let face else { return false }
        if case .draining = face.stage { return true }
        return false
    }

    var isTyping: Bool { isDraining }

    var visibleFaceID: UUID? { face?.id }

    var heldIDs: [UUID] {
        dictations.filter { $0.stage == .held }.map(\.id)
    }

    var orderedDictations: [Dictation] {
        dictations.enumerated().sorted { lhs, rhs in
            Self.isOlder(
                lhs.element,
                than: rhs.element,
                lhsOffset: lhs.offset,
                rhsOffset: rhs.offset
            )
        }.map(\.element)
    }

    mutating func showWrongSourceNudge(
        attempted: MacInputMode,
        live: MacInputMode?,
        at date: Date = Date()
    ) {
        sourceNudge = SourceNudge(
            attempted: attempted,
            live: live,
            startedAt: date
        )
    }

    /// Resting keeps the same face. It is not another card and it has no
    /// deadline; the next source key will update this face back to capture.
    mutating func beginResting(at date: Date = Date()) {
        guard var face else { return }
        if case .resting = face.stage { return }
        face.stage = .resting(startedAt: date)
        self.face = face
        capture = nil
        sourceNudge = nil
    }

    /// Phase changes call this before `beginCapture`. It intentionally does not
    /// erase the face: doing so would break identity across pause/resume.
    mutating func endResting() {}

    mutating func beginCapture(
        id: UUID,
        ordinal: Int?,
        source: MacInputMode,
        at date: Date = Date()
    ) {
        capture = Capture(
            id: id,
            ordinal: ordinal,
            source: source,
            activity: .connecting,
            stageStartedAt: date
        )
        if var face, face.canReopen {
            face.stage = .capture(
                source: source,
                activity: .connecting,
                stageStartedAt: date
            )
            self.face = face
        } else {
            face = Face(
                id: id,
                createdAt: date,
                stage: .capture(
                    source: source,
                    activity: .connecting,
                    stageStartedAt: date
                )
            )
        }
        sourceNudge = nil
    }

    mutating func updateCapture(
        id: UUID,
        activity: MacHUDCaptureActivity,
        at date: Date = Date()
    ) {
        guard var current = capture, current.id == id else { return }
        guard current.activity != activity else { return }
        // The Mac source glyph is one courtesy beat measured from the keypress,
        // not a second half-second delay after the recorder reports live. The
        // iPhone has a real wait edge, while Releasing starts its own cap.
        let stageStartedAt = activity == .listening && current.source == .mac
            ? current.stageStartedAt
            : date
        current.activity = activity
        current.stageStartedAt = stageStartedAt
        capture = current
        guard var face else { return }
        face.stage = .capture(
            source: current.source,
            activity: activity,
            stageStartedAt: stageStartedAt
        )
        self.face = face
    }

    mutating func discardCapture(id: UUID?) {
        guard let id, capture?.id == id else { return }
        capture = nil
    }

    mutating func beginDraining(at date: Date = Date()) {
        guard var face else { return }
        face.stage = .draining(startedAt: date)
        self.face = face
        capture = nil
        sourceNudge = nil
    }

    /// Removes the face immediately and detaches its segment work. Completion
    /// may still populate recovery, but it cannot replay the dismissed HUD.
    mutating func dismissFace() {
        guard let faceID = face?.id else { return }
        face = nil
        capture = nil
        sourceNudge = nil
        for index in dictations.indices where dictations[index].faceID == faceID {
            dictations[index].faceID = nil
        }
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
        let faceID = face?.id
        if let index = dictations.firstIndex(where: { $0.id == id }) {
            dictations[index].faceID = dictations[index].faceID ?? faceID
            dictations[index].stage = .transcribing
            dictations[index].stageStartedAt = date
            dictations[index].transcribingStartedAt = date
            dictations[index].recordingDuration = duration
            return
        }
        dictations.append(
            Dictation(
                id: id,
                faceID: faceID,
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
        let resolvedFaceID: UUID?
        if let index = dictations.firstIndex(where: { $0.id == id }) {
            dictations[index].stage = .held
            dictations[index].stageStartedAt = date
            resolvedFaceID = dictations[index].faceID
        } else {
            let faceID = face?.id ?? id
            dictations.append(
                Dictation(
                    id: id,
                    faceID: faceID,
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
            resolvedFaceID = faceID
            if face == nil {
                face = Face(
                    id: faceID,
                    createdAt: createdAt,
                    stage: .held(startedAt: date)
                )
            }
        }
        guard let resolvedFaceID, var face, face.id == resolvedFaceID else { return }
        face.stage = .held(startedAt: date)
        self.face = face
        capture = nil
        sourceNudge = nil
    }

    mutating func finish(id: UUID) {
        if capture?.id == id { capture = nil }
        let removedFaceID = dictations.first(where: { $0.id == id })?.faceID
        dictations.removeAll { $0.id == id }
        removeFinishedFaceIfNeeded(candidateID: removedFaceID)
    }

    mutating func finish(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let capture, ids.contains(capture.id) { self.capture = nil }
        let candidateFaceIDs = Set(
            dictations.lazy.filter { ids.contains($0.id) }.compactMap(\.faceID)
        )
        dictations.removeAll { ids.contains($0.id) }
        for faceID in candidateFaceIDs {
            removeFinishedFaceIfNeeded(candidateID: faceID)
        }
    }

    /// Maps segment receipts back to the one user-visible dictation identity.
    func faceIDs(forWorkIDs ids: Set<UUID>) -> Set<UUID> {
        Set(ids.compactMap { id in
            if face?.id == id { return id }
            return dictations.first(where: { $0.id == id })?.faceID
        })
    }

    /// True only when removing this work item will finish the one draining face.
    func finishesDrainingFace(withWorkID id: UUID) -> Bool {
        finishesDrainingFace(withWorkIDs: Set([id]))
    }

    /// True when one atomic output transaction owns every remaining piece of
    /// the visible draining dictation.
    func finishesDrainingFace(withWorkIDs ids: Set<UUID>) -> Bool {
        guard let face, case .draining = face.stage else { return false }
        let workIDs = Set(
            dictations.lazy.filter { $0.faceID == face.id }.map(\.id)
        )
        return !workIDs.isEmpty && workIDs.isSubset(of: ids)
    }

    private mutating func removeFinishedFaceIfNeeded(candidateID: UUID?) {
        guard let candidateID, let currentFace = face, currentFace.id == candidateID else {
            return
        }
        guard !dictations.contains(where: { $0.faceID == candidateID }) else { return }
        switch currentFace.stage {
        case .draining, .held:
            face = nil
            sourceNudge = nil
        case .capture, .resting:
            break
        }
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

private extension MacHUDPipeline.Face {
    /// Capture/rest/drain are phases of one still-open dictation. Held is a
    /// terminal recovery acknowledgment; a new source press should visually
    /// morph the shared capsule but must start a new model identity.
    var canReopen: Bool {
        switch stage {
        case .capture, .resting, .draining:
            true
        case .held:
            false
        }
    }
}

/// The one-card projection consumed by SwiftUI. `cards` remains an array so the
/// controller can keep its small diffing surface, but its budget is one by
/// contract: an open dictation is never serialized as a stack of segments.
struct MacHUDStack: Equatable, Sendable {
    enum CardContent: Equatable, Sendable {
        case sourceNudge(attempted: MacInputMode, live: MacInputMode?)
        case capture(
            source: MacInputMode,
            activity: MacHUDCaptureActivity,
            stageStartedAt: Date
        )
        case resting
        case draining
        case held
        case positioning
    }

    struct Card: Equatable, Identifiable, Sendable {
        let id: UUID
        let content: CardContent
    }

    static let visibleCardBudget = 1
    static let sourceNudgeVisibilityCap: TimeInterval = 1.4
    static let macStartVisibilityCap: TimeInterval = 0.5
    static let connectingVisibilityCap: TimeInterval = 20
    static let releasingVisibilityCap: TimeInterval = 15
    static let drainingVisibilityCap: TimeInterval = 90
    static let heldVisibilityCap: TimeInterval = 2
    static let empty = MacHUDStack(cards: [])
    static let positioning = MacHUDStack(
        cards: [
            Card(
                id: UUID(uuidString: "5EC18866-1373-414D-984D-82EA8858F795")!,
                content: .positioning
            )
        ]
    )

    let cards: [Card]

    var isEmpty: Bool { cards.isEmpty }
    var isResting: Bool { cards.first?.content == .resting }
    var isDraining: Bool { cards.first?.content == .draining }
    var frontIsReleasing: Bool {
        guard case .capture(_, .releasing, _) = cards.first?.content else {
            return false
        }
        return true
    }

    static func resolve(
        pipeline: MacHUDPipeline,
        at date: Date = Date()
    ) -> MacHUDStack {
        guard let face = pipeline.face else { return .empty }
        let content: CardContent

        if let nudge = visibleSourceNudge(in: pipeline, at: date),
           case .capture = face.stage {
            content = .sourceNudge(attempted: nudge.attempted, live: nudge.live)
        } else {
            switch face.stage {
            case let .capture(source, activity, stageStartedAt):
                let elapsed = date.timeIntervalSince(stageStartedAt)
                let connectingCap = source == .mac
                    ? macStartVisibilityCap
                    : connectingVisibilityCap
                if activity == .inactive
                    || (activity == .connecting && elapsed >= connectingCap)
                    || (activity == .releasing && elapsed >= releasingVisibilityCap) {
                    return .empty
                }
                content = .capture(
                    source: source,
                    activity: activity,
                    stageStartedAt: stageStartedAt
                )
            case .resting:
                content = .resting
            case let .draining(startedAt):
                guard date.timeIntervalSince(startedAt) < drainingVisibilityCap else {
                    return .empty
                }
                content = .draining
            case let .held(startedAt):
                guard date.timeIntervalSince(startedAt) < heldVisibilityCap else {
                    return .empty
                }
                content = .held
            }
        }
        return MacHUDStack(cards: [Card(id: face.id, content: content)])
    }

    static func nextExpiry(
        in pipeline: MacHUDPipeline,
        after date: Date = Date()
    ) -> Date? {
        var deadlines: [Date] = []
        if let nudge = pipeline.sourceNudge {
            let deadline = nudge.startedAt.addingTimeInterval(sourceNudgeVisibilityCap)
            if deadline > date { deadlines.append(deadline) }
        }
        if let face = pipeline.face {
            let deadline: Date?
            switch face.stage {
            case let .capture(source, activity, stageStartedAt):
                switch activity {
                case .connecting:
                    deadline = stageStartedAt.addingTimeInterval(
                        source == .mac
                            ? macStartVisibilityCap
                            : connectingVisibilityCap
                    )
                case .releasing:
                    deadline = stageStartedAt.addingTimeInterval(releasingVisibilityCap)
                case .listening, .inactive:
                    deadline = nil
                }
            case .resting:
                deadline = nil
            case let .draining(startedAt):
                deadline = startedAt.addingTimeInterval(drainingVisibilityCap)
            case let .held(startedAt):
                deadline = startedAt.addingTimeInterval(heldVisibilityCap)
            }
            if let deadline, deadline > date { deadlines.append(deadline) }
        }
        return deadlines.min()
    }

    func accessibilityLabel(
        sourceName: String?,
        heldClipboardBacked: Bool = false
    ) -> String {
        var parts = ["SpeakPaste"]
        guard let content = cards.first?.content else { return parts[0] }
        switch content {
        case let .sourceNudge(attempted, _):
            parts.append("Pause before switching to the \(attempted.title) microphone")
        case let .capture(source, activity, _):
            switch activity {
            case .connecting:
                parts.append(source == .iPhone ? "Waiting for iPhone microphone" : "Starting Mac microphone")
            case .listening:
                parts.append("Listening")
            case .releasing:
                parts.append("Releasing the microphone")
            case .inactive:
                break
            }
            if let sourceName { parts.append(sourceName) }
        case .resting:
            parts.append("Dictation resting — nothing has been delivered")
        case .draining:
            parts.append("Dictation transcribing for delivery")
        case .held:
            parts.append("Dictation held")
            if heldClipboardBacked {
                parts.append("The held dictation is on the clipboard")
            }
        case .positioning:
            parts.append("Move mode. Drag the capsule, then choose Done Moving HUD from the menu bar")
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

    private static func visibleSourceNudge(
        in pipeline: MacHUDPipeline,
        at date: Date
    ) -> MacHUDPipeline.SourceNudge? {
        guard let nudge = pipeline.sourceNudge else { return nil }
        return date.timeIntervalSince(nudge.startedAt) < sourceNudgeVisibilityCap
            ? nudge
            : nil
    }
}
