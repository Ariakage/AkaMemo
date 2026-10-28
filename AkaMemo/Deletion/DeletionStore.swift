import AkaMemoCore
import Foundation
import SwiftData

enum InboxDeletionMatch: Sendable, Equatable {
    case none
    case chunk(tombstoneID: UUID)
    case session(tombstoneID: UUID)
    case epoch(epochMs: Int64)
}

struct DeletionTarget: Sendable, Equatable {
    let chunkID: UUID
    let sessionID: UUID
    let relativePath: String
    let startedAtMs: Int64
}

struct DeletionPlan: Sendable, Equatable {
    let scope: DeletionScope
    let command: DeletionCommand
    let targets: [DeletionTarget]
    let transcriptPaths: [String]
    let chunkIDs: [UUID]
    let sessionIDs: [UUID]
}

enum DeletionStoreError: Error, Equatable, Sendable {
    case missingEntity
}

/// Persists tombstones and the data epoch, answers inbox checks, and removes
/// local SwiftData rows only after the caller has finished file/index cleanup.
@ModelActor
actor DeletionStore {
    func matchForInbox(
        chunkID: UUID,
        sessionID: UUID,
        sessionStartedAtMs: Int64
    ) throws -> InboxDeletionMatch {
        if let tombstone = try chunkTombstone(chunkID: chunkID) {
            return .chunk(tombstoneID: tombstone.tombstoneID)
        }
        if let tombstone = try sessionTombstone(sessionID: sessionID) {
            return .session(tombstoneID: tombstone.tombstoneID)
        }
        if let epoch = try latestEpoch(), sessionStartedAtMs < epoch.epochMs {
            return .epoch(epochMs: epoch.epochMs)
        }
        return .none
    }

    /// Track imports are rejected by session tombstone or DataEpoch; a chunk
    /// tombstone does not apply to the session track.
    func matchForTrack(
        sessionID: UUID,
        sessionStartedAtMs: Int64
    ) throws -> InboxDeletionMatch {
        if let tombstone = try sessionTombstone(sessionID: sessionID) {
            return .session(tombstoneID: tombstone.tombstoneID)
        }
        if let epoch = try latestEpoch(), sessionStartedAtMs < epoch.epochMs {
            return .epoch(epochMs: epoch.epochMs)
        }
        return .none
    }

    /// Writes the tombstone (or epoch) first and returns what must be removed.
    /// SwiftData rows are left in place until `completeDeletion`.
    func prepareDeletion(
        scope: DeletionScope,
        entityID: UUID?,
        sessionID: UUID?,
        reason: String,
        now: Date = Date()
    ) throws -> DeletionPlan {
        let nowMs = TimeMath.epochMs(now)
        let tombstoneID = UUID()
        var resolvedSessionID = sessionID

        switch scope {
        case .chunk:
            guard let entityID else {
                throw DeletionStoreError.missingEntity
            }
            let chunk = try findChunk(id: entityID)
            resolvedSessionID = chunk?.sessionID ?? sessionID
            let record = DeletionTombstoneRecord(
                tombstoneID: tombstoneID,
                entityTypeRaw: "chunk",
                entityID: entityID,
                sessionID: resolvedSessionID,
                deletedAt: now,
                expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
                reason: reason
            )
            modelContext.insert(record)
        case .session:
            guard let entityID else {
                throw DeletionStoreError.missingEntity
            }
            resolvedSessionID = entityID
            let record = DeletionTombstoneRecord(
                tombstoneID: tombstoneID,
                entityTypeRaw: "session",
                entityID: entityID,
                sessionID: entityID,
                deletedAt: now,
                expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
                reason: reason
            )
            modelContext.insert(record)
        case .all:
            let epoch = DataEpochRecord(
                tombstoneID: tombstoneID,
                epochMs: nowMs,
                createdAt: now
            )
            modelContext.insert(epoch)
        }
        try modelContext.save()

        let chunks: [ReceivedChunkRecord]
        switch scope {
        case .chunk:
            chunks =
                try entityID.flatMap { try findChunk(id: $0) }.map {
                    [$0]
                } ?? []
        case .session:
            guard let wanted = resolvedSessionID else {
                throw DeletionStoreError.missingEntity
            }
            chunks = try modelContext.fetch(
                FetchDescriptor<ReceivedChunkRecord>(
                    predicate: #Predicate { record in
                        record.sessionID == wanted
                    }
                )
            )
        case .all:
            // Only sessions that started before the epoch are in scope. A
            // recording that began after the epoch must survive delete-all.
            chunks = try modelContext.fetch(
                FetchDescriptor<ReceivedChunkRecord>()
            ).filter {
                TimeMath.epochMs($0.sessionStartedAt) < nowMs
            }
        }

        let targets = chunks.map { chunk in
            DeletionTarget(
                chunkID: chunk.chunkID,
                sessionID: chunk.sessionID,
                relativePath: chunk.relativePath,
                startedAtMs: TimeMath.epochMs(chunk.startedAt)
            )
        }
        let chunkIDs = targets.map(\.chunkID)
        let sessionIDs = Array(Set(targets.map(\.sessionID)))
        let chunkByID = Dictionary(
            uniqueKeysWithValues: chunks.map { ($0.chunkID, $0) }
        )

        let transcripts: [TranscriptRecord]
        switch scope {
        case .chunk:
            transcripts = try fetchTranscripts(chunkIDs: chunkIDs)
        case .session:
            transcripts = try fetchTranscripts(sessionIDs: sessionIDs)
        case .all:
            transcripts = try fetchTranscripts(sessionIDs: sessionIDs)
        }
        let transcriptPaths = transcripts.compactMap {
            transcript
                -> String? in
            guard let chunk = chunkByID[transcript.chunkID] else {
                return nil
            }
            return TranscriptPaths.relativePath(
                chunkStartedAt: chunk.startedAt,
                chunkID: chunk.chunkID,
                transcriptID: transcript.transcriptID
            )
        }

        let command = DeletionCommand(
            tombstoneID: tombstoneID,
            scope: scope,
            entityID: entityID,
            sessionID: resolvedSessionID,
            epochMs: scope == .all ? nowMs : nil,
            deletedAtMs: nowMs
        )
        return DeletionPlan(
            scope: scope,
            command: command,
            targets: targets,
            transcriptPaths: transcriptPaths,
            chunkIDs: chunkIDs,
            sessionIDs: sessionIDs
        )
    }

    func completeDeletion(_ plan: DeletionPlan) throws {
        switch plan.scope {
        case .chunk:
            for chunkID in plan.chunkIDs {
                try deleteSegments(chunkID: chunkID)
                try deleteTranscripts(chunkID: chunkID)
                try deleteTasks(chunkID: chunkID)
                for record in try modelContext.fetch(
                    FetchDescriptor<ReceivedChunkRecord>(
                        predicate: #Predicate { record in
                            record.chunkID == chunkID
                        }
                    )
                ) {
                    modelContext.delete(record)
                }
            }
        case .session:
            for sessionID in plan.sessionIDs {
                try deleteSegments(sessionID: sessionID)
                try deleteTranscripts(sessionID: sessionID)
                try deleteTasks(sessionID: sessionID)
                try deleteTracks(sessionID: sessionID)
                for record in try modelContext.fetch(
                    FetchDescriptor<ReceivedChunkRecord>(
                        predicate: #Predicate { record in
                            record.sessionID == sessionID
                        }
                    )
                ) {
                    modelContext.delete(record)
                }
            }
        case .all:
            // Only remove what was captured in the plan. A new recording that
            // starts after the epoch may have arrived while files were being
            // deleted and must survive.
            for sessionID in plan.sessionIDs {
                try deleteSegments(sessionID: sessionID)
                try deleteTranscripts(sessionID: sessionID)
                try deleteTasks(sessionID: sessionID)
                try deleteTracks(sessionID: sessionID)
            }
            let chunkIDs = Set(plan.chunkIDs)
            for record in try modelContext.fetch(
                FetchDescriptor<ReceivedChunkRecord>()
            ) where chunkIDs.contains(record.chunkID) {
                modelContext.delete(record)
            }
        }
        try modelContext.save()
    }

    func markAcknowledged(
        tombstoneID: UUID,
        now: Date = Date()
    ) throws {
        var descriptor = FetchDescriptor<DeletionTombstoneRecord>(
            predicate: #Predicate { record in
                record.tombstoneID == tombstoneID
            }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first,
            record.acknowledgedAt == nil
        {
            record.acknowledgedAt = now
        }

        var epochDescriptor = FetchDescriptor<DataEpochRecord>(
            predicate: #Predicate { record in
                record.tombstoneID == tombstoneID
            }
        )
        epochDescriptor.fetchLimit = 1
        if let epoch = try modelContext.fetch(epochDescriptor).first,
            epoch.watchAckAt == nil
        {
            epoch.watchAckAt = now
        }
        try modelContext.save()
    }

    func unacknowledgedCommands() throws -> [DeletionCommand] {
        let tombstones = try modelContext.fetch(
            FetchDescriptor<DeletionTombstoneRecord>(
                predicate: #Predicate { record in
                    record.acknowledgedAt == nil
                }
            )
        )
        let epochs = try modelContext.fetch(
            FetchDescriptor<DataEpochRecord>(
                predicate: #Predicate { record in
                    record.watchAckAt == nil
                }
            )
        )
        var commands = tombstones.map(Self.command(for:))
        commands.append(contentsOf: epochs.map(Self.command(for:)))
        return commands.sorted { $0.deletedAtMs < $1.deletedAtMs }
    }

    /// Used when the inbox rejects a late chunk: return the tombstone or epoch
    /// that caused the rejection so it can be sent back to the Watch.
    func commandForRejectedChunk(
        chunkID: UUID,
        sessionID: UUID
    ) throws -> DeletionCommand? {
        if let tombstone = try chunkTombstone(chunkID: chunkID) {
            return Self.command(for: tombstone)
        }
        if let tombstone = try sessionTombstone(sessionID: sessionID) {
            return Self.command(for: tombstone)
        }
        if let epoch = try latestEpoch() {
            return Self.command(for: epoch)
        }
        return nil
    }

    private static func command(
        for record: DeletionTombstoneRecord
    ) -> DeletionCommand {
        let scope = DeletionScope(rawValue: record.entityTypeRaw) ?? .chunk
        return DeletionCommand(
            tombstoneID: record.tombstoneID,
            scope: scope,
            entityID: record.entityID,
            sessionID: record.sessionID,
            deletedAtMs: TimeMath.epochMs(record.deletedAt)
        )
    }

    private static func command(for epoch: DataEpochRecord) -> DeletionCommand {
        DeletionCommand(
            tombstoneID: epoch.tombstoneID,
            scope: .all,
            epochMs: epoch.epochMs,
            deletedAtMs: TimeMath.epochMs(epoch.createdAt)
        )
    }

    private func chunkTombstone(
        chunkID: UUID
    ) throws -> DeletionTombstoneRecord? {
        var descriptor = FetchDescriptor<DeletionTombstoneRecord>(
            predicate: #Predicate { record in
                record.entityTypeRaw == "chunk" && record.entityID == chunkID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func sessionTombstone(
        sessionID: UUID
    ) throws -> DeletionTombstoneRecord? {
        var descriptor = FetchDescriptor<DeletionTombstoneRecord>(
            predicate: #Predicate { record in
                record.entityTypeRaw == "session"
                    && record.entityID == sessionID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func latestEpoch() throws -> DataEpochRecord? {
        var descriptor = FetchDescriptor<DataEpochRecord>(
            sortBy: [SortDescriptor(\.epochMs, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func findChunk(id: UUID) throws -> ReceivedChunkRecord? {
        var descriptor = FetchDescriptor<ReceivedChunkRecord>(
            predicate: #Predicate { record in
                record.chunkID == id
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchTranscripts(
        chunkIDs: [UUID]
    ) throws -> [TranscriptRecord] {
        guard !chunkIDs.isEmpty else {
            return []
        }
        let all = try modelContext.fetch(FetchDescriptor<TranscriptRecord>())
        let wanted = Set(chunkIDs)
        return all.filter { wanted.contains($0.chunkID) }
    }

    private func fetchTranscripts(
        sessionIDs: [UUID]
    ) throws -> [TranscriptRecord] {
        guard !sessionIDs.isEmpty else {
            return []
        }
        let all = try modelContext.fetch(FetchDescriptor<TranscriptRecord>())
        let wanted = Set(sessionIDs)
        return all.filter { wanted.contains($0.sessionID) }
    }

    private func deleteSegments(chunkID: UUID) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<TranscriptSegmentRecord>(
                predicate: #Predicate { record in
                    record.chunkID == chunkID
                }
            )
        ) {
            modelContext.delete(record)
        }
    }

    private func deleteSegments(sessionID: UUID) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<TranscriptSegmentRecord>(
                predicate: #Predicate { record in
                    record.sessionID == sessionID
                }
            )
        ) {
            modelContext.delete(record)
        }
    }

    private func deleteTranscripts(chunkID: UUID) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<TranscriptRecord>(
                predicate: #Predicate { record in
                    record.chunkID == chunkID
                }
            )
        ) {
            modelContext.delete(record)
        }
    }

    private func deleteTranscripts(sessionID: UUID) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<TranscriptRecord>(
                predicate: #Predicate { record in
                    record.sessionID == sessionID
                }
            )
        ) {
            modelContext.delete(record)
        }
    }

    private func deleteTasks(chunkID: UUID) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<TranscriptionTaskRecord>(
                predicate: #Predicate { record in
                    record.chunkID == chunkID
                }
            )
        ) {
            modelContext.delete(record)
        }
    }

    private func deleteTracks(sessionID: UUID) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<LocationTrackRecord>(
                predicate: #Predicate { record in
                    record.sessionID == sessionID
                }
            )
        ) {
            modelContext.delete(record)
        }
    }

    private func deleteTasks(sessionID: UUID) throws {
        for record in try modelContext.fetch(
            FetchDescriptor<TranscriptionTaskRecord>(
                predicate: #Predicate { record in
                    record.sessionID == sessionID
                }
            )
        ) {
            modelContext.delete(record)
        }
    }

}
