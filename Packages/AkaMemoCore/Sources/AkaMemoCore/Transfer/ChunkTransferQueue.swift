import Foundation

public struct ChunkTransferQueueEntry: Codable, Sendable, Equatable {
    public var envelope: ChunkTransferEnvelope
    public var state: AudioChunk.TransferState
    public var attemptCount: Int
    public var nextAttemptAtMs: Int64
    public var lastErrorCode: String?
    public var updatedAtMs: Int64

    public init(
        envelope: ChunkTransferEnvelope,
        state: AudioChunk.TransferState,
        attemptCount: Int,
        nextAttemptAtMs: Int64,
        lastErrorCode: String? = nil,
        updatedAtMs: Int64
    ) {
        self.envelope = envelope
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAtMs = nextAttemptAtMs
        self.lastErrorCode = lastErrorCode
        self.updatedAtMs = updatedAtMs
    }
}

/// The persistent Watch transfer queue (`queue/transfer-manifest.json`).
public struct ChunkTransferQueueDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var entries: [ChunkTransferQueueEntry]

    public init(
        schemaVersion: Int = ChunkTransferQueueDocument.currentSchemaVersion,
        entries: [ChunkTransferQueueEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries.sorted { $0.envelope.startedAtMs < $1.envelope.startedAtMs }
    }

    public func entry(chunkID: UUID) -> ChunkTransferQueueEntry? {
        entries.first { $0.envelope.chunkID == chunkID }
    }

    public mutating func upsert(_ entry: ChunkTransferQueueEntry) {
        if let index = entries.firstIndex(where: { $0.envelope.chunkID == entry.envelope.chunkID })
        {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.envelope.startedAtMs < $1.envelope.startedAtMs }
    }
}
