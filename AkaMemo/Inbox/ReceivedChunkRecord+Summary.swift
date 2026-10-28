import AkaMemoCore
import Foundation

extension ReceivedChunkRecord {
    var summary: ChunkSummary {
        ChunkSummary(
            chunkID: chunkID,
            sessionID: sessionID,
            sessionStartedAtMs: TimeMath.epochMs(sessionStartedAt),
            sequence: sequence,
            startedAtMs: TimeMath.epochMs(startedAt),
            durationMs: durationMs,
            byteSize: byteSize,
            relativePath: relativePath
        )
    }
}
