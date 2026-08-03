import Foundation

/// Decides whether Escape may discard the current recording immediately.
///
/// Short recordings remain cheap to abandon. Once a recording reaches the
/// protection threshold, one Escape only arms a brief confirmation window; a
/// second Escape inside that window performs the cancellation. Keeping this as
/// a value type with an injected timestamp makes the safety boundary fully
/// deterministic and independent of AppKit or the recorder.
struct MacRecordingCancellationPolicy: Equatable {
    enum Decision: Equatable {
        case cancelImmediately
        case confirmAgain(expiresAt: Date)
    }

    static let defaultProtectedDuration: TimeInterval = 30
    static let defaultConfirmationWindow: TimeInterval = 3

    let protectedDuration: TimeInterval
    let confirmationWindow: TimeInterval
    private(set) var armedUntil: Date?

    init(
        protectedDuration: TimeInterval = Self.defaultProtectedDuration,
        confirmationWindow: TimeInterval = Self.defaultConfirmationWindow
    ) {
        self.protectedDuration = max(0, protectedDuration)
        self.confirmationWindow = max(0, confirmationWindow)
    }

    mutating func requestCancellation(
        recordingDuration: TimeInterval,
        now: Date
    ) -> Decision {
        guard recordingDuration >= protectedDuration else {
            reset()
            return .cancelImmediately
        }

        if let armedUntil, now <= armedUntil {
            reset()
            return .cancelImmediately
        }

        let expiration = now.addingTimeInterval(confirmationWindow)
        armedUntil = expiration
        return .confirmAgain(expiresAt: expiration)
    }

    mutating func reset() {
        armedUntil = nil
    }
}

/// Observable presentation-neutral state for a future menu, HUD, or other UI.
/// The policy owns the decision; this value only describes what happened.
struct MacRecordingCancelConfirmation: Equatable {
    let message: String
    let expiresAt: Date
}
