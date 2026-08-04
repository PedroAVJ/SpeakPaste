import Foundation

/// Recognizes one bare press-and-release of the right Command key. Physical
/// key-side detection stays in `MacGlobalHotKey`; this state machine only owns
/// the modifier/chord boundary and is kept pure for regression tests.
struct CommandTapRecognizer {
    private(set) var isCommandDown = false
    private(set) var isTapCandidate = false

    mutating func modifiersChanged(commandDown: Bool, hasOtherModifiers: Bool) -> Bool {
        if commandDown {
            if !isCommandDown {
                isCommandDown = true
                isTapCandidate = !hasOtherModifiers
            } else if hasOtherModifiers {
                isTapCandidate = false
            }
            return false
        }

        guard isCommandDown else { return false }
        let recognizedTap = isTapCandidate && !hasOtherModifiers
        reset()
        return recognizedTap
    }

    mutating func keyPressed() {
        if isCommandDown {
            isTapCandidate = false
        }
    }

    mutating func reset() {
        isCommandDown = false
        isTapCandidate = false
    }
}

enum CommandTapSequenceAction: Equatable {
    case deferSingle(UUID)
    case doubleTap
}

/// Separates a single Command tap from a double tap without letting the first
/// half of a double tap start or stop recording. `MacGlobalHotKey` owns the
/// short timer; the token prevents a canceled or stale timer from firing.
struct CommandTapSequenceRecognizer {
    private var pendingSingleToken: UUID?

    var hasPendingSingleTap: Bool { pendingSingleToken != nil }

    mutating func registerTap() -> CommandTapSequenceAction {
        if pendingSingleToken != nil {
            pendingSingleToken = nil
            return .doubleTap
        }

        let token = UUID()
        pendingSingleToken = token
        return .deferSingle(token)
    }

    mutating func commitSingleTap(token: UUID) -> Bool {
        guard pendingSingleToken == token else { return false }
        pendingSingleToken = nil
        return true
    }

    mutating func cancel() {
        pendingSingleToken = nil
    }
}
