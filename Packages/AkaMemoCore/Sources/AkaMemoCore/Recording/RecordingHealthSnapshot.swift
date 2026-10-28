import Foundation

/// The on-disk heartbeat described by `docs/specs/recording-health.md` §3.1.
///
/// The Watch writes it to `health.json`; the recovery scanner reads it after
/// a process termination to decide whether a session can be continued.
public struct RecordingHealthSnapshot: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let sessionStartedAtMs: Int64
    public let endedAtMs: Int64?
    public let lastAudioBufferAtMs: Int64?
    public let lastHeartbeatAtMs: Int64
    public let chunkSequence: Int?
    public let bytesWritten: Int64
    public let audioSessionActive: Bool
    public let batteryLevel: Double?
    public let state: String
    public let stateVersion: Int64
    public let totalGapMs: Int64
    public let interruptionCount: Int

    public init(
        sessionID: UUID,
        sessionStartedAtMs: Int64,
        endedAtMs: Int64?,
        lastAudioBufferAtMs: Int64?,
        lastHeartbeatAtMs: Int64,
        chunkSequence: Int?,
        bytesWritten: Int64,
        audioSessionActive: Bool,
        batteryLevel: Double?,
        state: String,
        stateVersion: Int64,
        totalGapMs: Int64,
        interruptionCount: Int
    ) {
        self.sessionID = sessionID
        self.sessionStartedAtMs = sessionStartedAtMs
        self.endedAtMs = endedAtMs
        self.lastAudioBufferAtMs = lastAudioBufferAtMs
        self.lastHeartbeatAtMs = lastHeartbeatAtMs
        self.chunkSequence = chunkSequence
        self.bytesWritten = bytesWritten
        self.audioSessionActive = audioSessionActive
        self.batteryLevel = batteryLevel
        self.state = state
        self.stateVersion = stateVersion
        self.totalGapMs = totalGapMs
        self.interruptionCount = interruptionCount
    }

    /// Returns a snapshot that closes the session without touching its audio.
    /// Used when the user dismisses a pending recovery prompt.
    public func markingCompleted(nowMs: Int64) -> RecordingHealthSnapshot {
        RecordingHealthSnapshot(
            sessionID: sessionID,
            sessionStartedAtMs: sessionStartedAtMs,
            endedAtMs: nowMs,
            lastAudioBufferAtMs: lastAudioBufferAtMs,
            lastHeartbeatAtMs: nowMs,
            chunkSequence: chunkSequence,
            bytesWritten: bytesWritten,
            audioSessionActive: false,
            batteryLevel: batteryLevel,
            state: "completed",
            stateVersion: StateVersion.next(
                lastKnown: stateVersion,
                nowMs: nowMs
            ),
            totalGapMs: totalGapMs,
            interruptionCount: interruptionCount
        )
    }
}
