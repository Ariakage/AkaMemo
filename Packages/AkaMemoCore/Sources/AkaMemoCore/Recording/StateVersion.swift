import Foundation

/// Monotonic state version shared by heartbeat, battery and recording state.
///
/// The version never goes backwards within a session. After losing persisted
/// state, `afterPersistenceLoss` jumps to the current time instead of
/// restarting at 1. A new session starts at `initial`.
public enum StateVersion {
    public static let initial: Int64 = 1

    public static func next(lastKnown: Int64, nowMs: Int64) -> Int64 {
        let incremented = lastKnown == Int64.max ? Int64.max : lastKnown + 1
        return max(incremented, nowMs)
    }

    public static func afterPersistenceLoss(nowMs: Int64) -> Int64 {
        max(initial, nowMs)
    }
}
