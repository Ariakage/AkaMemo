import Foundation

/// A session that a terminated process left behind and that can be continued
/// from the foreground.
public struct InterruptedSessionInfo: Sendable, Equatable {
    public let sessionID: UUID
    public let sessionStartedAtMs: Int64
    public let lastAudioBufferAtMs: Int64?
    public let lastHeartbeatAtMs: Int64
    public let lastStateVersion: Int64
    public let totalGapMs: Int64
    public let interruptionCount: Int
    public let nextSequence: Int
    public let sealedChunkCount: Int
    public let totalBytes: Int64

    public init(
        sessionID: UUID,
        sessionStartedAtMs: Int64,
        lastAudioBufferAtMs: Int64?,
        lastHeartbeatAtMs: Int64,
        lastStateVersion: Int64,
        totalGapMs: Int64,
        interruptionCount: Int,
        nextSequence: Int,
        sealedChunkCount: Int,
        totalBytes: Int64
    ) {
        self.sessionID = sessionID
        self.sessionStartedAtMs = sessionStartedAtMs
        self.lastAudioBufferAtMs = lastAudioBufferAtMs
        self.lastHeartbeatAtMs = lastHeartbeatAtMs
        self.lastStateVersion = lastStateVersion
        self.totalGapMs = totalGapMs
        self.interruptionCount = interruptionCount
        self.nextSequence = nextSequence
        self.sealedChunkCount = sealedChunkCount
        self.totalBytes = totalBytes
    }

    /// Audio gap to record when resuming at `nowMs`.
    public func recoveryGapMs(nowMs: Int64) -> Int64 {
        max(0, nowMs - (lastAudioBufferAtMs ?? lastHeartbeatAtMs))
    }
}

public enum InterruptedSessionScannerError: Error, Equatable, Sendable {
    case healthFileUnavailable
    case sessionMismatch
}

/// Detects a recording session that was not closed because the Watch app was
/// terminated. Only `recording`, `recovering` and `interrupted` heartbeats are
/// resumable; a session the user paused or stopped is left alone.
public struct InterruptedSessionScanner: Sendable {
    public static let resumableStates: Set<String> = [
        "recording",
        "recovering",
        "interrupted",
    ]

    private let audioRoot: URL
    private let healthFileURL: URL

    public init(audioRoot: URL, healthFileURL: URL) {
        self.audioRoot = audioRoot
        self.healthFileURL = healthFileURL
    }

    public func scan() -> InterruptedSessionInfo? {
        guard let health = loadHealth(),
            health.endedAtMs == nil,
            Self.resumableStates.contains(health.state)
        else {
            return nil
        }
        let directory = audioRoot.appending(
            path: health.sessionID.uuidString,
            directoryHint: .isDirectory
        )
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            return nil
        }

        let entries = loadManifest(at: directory)?.entries ?? []
        let presentEntries = entries.filter { $0.localState == .present }
        let highestSequence = max(
            entries.map(\.sequence).max() ?? -1,
            health.chunkSequence ?? -1
        )
        return InterruptedSessionInfo(
            sessionID: health.sessionID,
            sessionStartedAtMs: health.sessionStartedAtMs,
            lastAudioBufferAtMs: health.lastAudioBufferAtMs,
            lastHeartbeatAtMs: health.lastHeartbeatAtMs,
            lastStateVersion: health.stateVersion,
            totalGapMs: health.totalGapMs,
            interruptionCount: health.interruptionCount,
            nextSequence: highestSequence + 1,
            sealedChunkCount: presentEntries.count,
            totalBytes: presentEntries.reduce(Int64(0)) { total, entry in
                total + Int64(entry.byteSize ?? 0)
            }
        )
    }

    /// Closes the leftover session's heartbeat without deleting any audio so
    /// the user is not prompted again after choosing to ignore it.
    public func markCompleted(sessionID: UUID, nowMs: Int64) throws {
        guard let health = loadHealth() else {
            throw InterruptedSessionScannerError.healthFileUnavailable
        }
        guard health.sessionID == sessionID else {
            throw InterruptedSessionScannerError.sessionMismatch
        }
        let data = try JSONEncoder().encode(
            health.markingCompleted(nowMs: nowMs)
        )
        try data.write(to: healthFileURL, options: [.atomic])
    }

    private func loadHealth() -> RecordingHealthSnapshot? {
        guard let data = try? Data(contentsOf: healthFileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(
            RecordingHealthSnapshot.self,
            from: data
        )
    }

    private func loadManifest(at directory: URL) -> ChunkManifest? {
        let url = directory.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ChunkManifest.self, from: data)
    }
}
