import Foundation

public enum SessionTransition: String, Sendable, CaseIterable {
    case pause
    case resume
    case interruption
    case beginRecovery
    case recoverySucceeded
    case recoveryFailed
    case stop
    case finalizeSucceeded
    case finalizeFailed
    case fatalError
}

/// The legal session transitions from `docs/architecture/data-model.md`.
///
/// The state machine does not know whether the app is in the foreground.
/// Callers must only use `resume` or `beginRecovery` while the audio session
/// can be activated, and must never enter `recording` silently after launch.
public enum SessionStateMachine {
    public static func nextState(
        from current: RecordingSession.State,
        on transition: SessionTransition,
        autoRecoveryEnabled: Bool
    ) -> RecordingSession.State? {
        switch (current, transition) {
        case (.recording, .pause):
            return .paused
        case (.paused, .resume), (.interrupted, .resume):
            return .recording
        case (.recording, .interruption):
            return .interrupted
        case (.interrupted, .beginRecovery) where autoRecoveryEnabled:
            return .recovering
        case (.recovering, .recoverySucceeded):
            return .recording
        case (.recovering, .recoveryFailed):
            return .interrupted
        case (.recording, .stop), (.paused, .stop), (.interrupted, .stop), (.recovering, .stop):
            return .finalizing
        case (.finalizing, .finalizeSucceeded):
            return .completed
        case (.finalizing, .finalizeFailed), (.recording, .fatalError), (.paused, .fatalError),
            (.interrupted, .fatalError), (.recovering, .fatalError), (.finalizing, .fatalError):
            return .failed
        default:
            return nil
        }
    }
}
