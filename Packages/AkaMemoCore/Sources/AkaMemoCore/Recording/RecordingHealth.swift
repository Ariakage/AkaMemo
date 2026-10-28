import Foundation

public enum RecordingHealthStatus: String, Codable, Sendable, CaseIterable {
    case healthy
    case recovering
    case interrupted
}

/// Audio-buffer watchdog used on the watch.
///
/// Ten seconds without an audio buffer starts recovery; thirty seconds marks
/// the session interrupted. The session start is the reference before the
/// first buffer arrives, so a freshly started recording is not reported as
/// broken.
public struct RecordingHealthEvaluator: Sendable, Equatable {
    public static let standard = RecordingHealthEvaluator(
        warningAfter: RecordingConfiguration.audioBufferWarningThreshold,
        interruptionAfter: RecordingConfiguration.audioBufferInterruptionThreshold
    )

    public let warningAfter: TimeInterval
    public let interruptionAfter: TimeInterval

    public init(warningAfter: TimeInterval, interruptionAfter: TimeInterval) {
        self.warningAfter = warningAfter
        self.interruptionAfter = interruptionAfter
    }

    public func status(
        now: Date,
        lastAudioBufferAt: Date?,
        sessionStartedAt: Date
    ) -> RecordingHealthStatus {
        let reference = lastAudioBufferAt ?? sessionStartedAt
        let elapsed = now.timeIntervalSince(reference)
        if elapsed >= interruptionAfter {
            return .interrupted
        }
        if elapsed >= warningAfter {
            return .recovering
        }
        return .healthy
    }

    /// Returns the audio gap in milliseconds. Clock skew and missing buffer
    /// timestamps produce zero rather than a negative or invented gap.
    public func gapMilliseconds(from lastAudioBufferAt: Date?, to resumedAt: Date) -> Int64 {
        guard let lastAudioBufferAt else {
            return 0
        }
        let gap = resumedAt.timeIntervalSince(lastAudioBufferAt)
        guard gap > 0, gap.isFinite else {
            return 0
        }
        return Int64((gap * 1000).rounded())
    }
}

public enum RecordingRecoveryDecision: Sendable, Equatable {
    case retry(after: TimeInterval, attempt: Int)
    case giveUp
}

/// The 1s / 5s / 15s recovery schedule, limited to three attempts.
public enum RecordingRecoverySchedule {
    public static func decision(
        completedAttempts: Int,
        delays: [TimeInterval] = RecordingConfiguration.recoveryDelays
    ) -> RecordingRecoveryDecision {
        guard completedAttempts < delays.count else {
            return .giveUp
        }
        let index = max(0, completedAttempts)
        return .retry(after: delays[index], attempt: index + 1)
    }
}
