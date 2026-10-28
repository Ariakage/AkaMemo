import Foundation

/// The fields needed to group a verified chunk into a recording session.
public struct ChunkSummary: Sendable, Equatable {
    public let chunkID: UUID
    public let sessionID: UUID
    public let sessionStartedAtMs: Int64
    public let sequence: Int
    public let startedAtMs: Int64
    public let durationMs: Int
    public let byteSize: Int
    public let relativePath: String

    public init(
        chunkID: UUID,
        sessionID: UUID,
        sessionStartedAtMs: Int64,
        sequence: Int,
        startedAtMs: Int64,
        durationMs: Int,
        byteSize: Int,
        relativePath: String
    ) {
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.sessionStartedAtMs = sessionStartedAtMs
        self.sequence = sequence
        self.startedAtMs = startedAtMs
        self.durationMs = durationMs
        self.byteSize = byteSize
        self.relativePath = relativePath
    }
}

public struct SessionSummary: Identifiable, Sendable, Equatable {
    public var id: UUID { sessionID }

    public let sessionID: UUID
    public let startedAtMs: Int64
    public let chunks: [ChunkSummary]

    public init(sessionID: UUID, startedAtMs: Int64, chunks: [ChunkSummary]) {
        self.sessionID = sessionID
        self.startedAtMs = startedAtMs
        self.chunks = chunks
    }

    public var chunkCount: Int {
        chunks.count
    }

    public var totalBytes: Int64 {
        chunks.reduce(0) { $0 + Int64($1.byteSize) }
    }

    public var totalDurationMs: Int64 {
        chunks.reduce(0) { $0 + Int64($1.durationMs) }
    }
}

public enum SessionAggregator {
    /// Groups verified chunks into sessions, sorted newest first.
    ///
    /// Duplicate chunk IDs are ignored so a repeated transfer cannot inflate
    /// the session totals. Chunks within a session are ordered by sequence.
    public static func group(_ chunks: [ChunkSummary]) -> [SessionSummary] {
        var seenChunkIDs = Set<UUID>()
        var grouped: [UUID: [ChunkSummary]] = [:]

        for chunk in chunks where seenChunkIDs.insert(chunk.chunkID).inserted {
            grouped[chunk.sessionID, default: []].append(chunk)
        }

        return
            grouped
            .compactMap { sessionID, sessionChunks -> SessionSummary? in
                let sorted = sessionChunks.sorted {
                    ($0.sequence, $0.startedAtMs) < ($1.sequence, $1.startedAtMs)
                }
                guard let first = sorted.first else {
                    return nil
                }
                let startedAtMs =
                    sorted.map(\.sessionStartedAtMs).min()
                    ?? first.startedAtMs
                return SessionSummary(
                    sessionID: sessionID,
                    startedAtMs: startedAtMs,
                    chunks: sorted
                )
            }
            .sorted {
                if $0.startedAtMs == $1.startedAtMs {
                    return $0.sessionID.uuidString < $1.sessionID.uuidString
                }
                return $0.startedAtMs > $1.startedAtMs
            }
    }
}
