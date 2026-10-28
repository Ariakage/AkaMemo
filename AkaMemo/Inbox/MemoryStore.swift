import AkaMemoCore
import Foundation
import SwiftData

@ModelActor
actor MemoryStore {
    func contains(chunkID: UUID, checksumSHA256: String) throws -> Bool {
        var descriptor = FetchDescriptor<ReceivedChunkRecord>(
            predicate: #Predicate { record in
                record.chunkID == chunkID && record.checksumSHA256 == checksumSHA256
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func contains(chunkID: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<ReceivedChunkRecord>(
            predicate: #Predicate { record in
                record.chunkID == chunkID
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func contains(sessionID: UUID, sequence: Int) throws -> Bool {
        var descriptor = FetchDescriptor<ReceivedChunkRecord>(
            predicate: #Predicate { record in
                record.sessionID == sessionID && record.sequence == sequence
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func insert(
        envelope: ChunkTransferEnvelope,
        relativePath: String,
        receivedAt: Date
    ) throws {
        let record = ReceivedChunkRecord(
            chunkID: envelope.chunkID,
            sessionID: envelope.sessionID,
            sessionStartedAt: TimeMath.date(epochMs: envelope.sessionStartedAtMs),
            sequence: envelope.sequence,
            startedAt: TimeMath.date(epochMs: envelope.startedAtMs),
            durationMs: envelope.durationMs,
            byteSize: envelope.byteSize,
            checksumSHA256: envelope.checksumSHA256,
            formatVersion: envelope.formatVersion,
            sampleRate: envelope.sampleRate,
            channels: envelope.channels,
            bitRate: envelope.bitRate,
            relativePath: relativePath,
            receivedAt: receivedAt
        )
        modelContext.insert(record)
        try modelContext.save()
    }

    func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<ReceivedChunkRecord>())
    }
}
