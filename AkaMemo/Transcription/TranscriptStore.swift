import AkaMemoCore
import Foundation
import SwiftData

struct TranscriptionTaskSnapshot: Sendable, Equatable {
    let taskID: UUID
    let chunkID: UUID
    let sessionID: UUID
    let startedAtMs: Int64
    let durationMs: Int64
    let relativePath: String
    let attemptCount: Int
}

struct TranscriptSaveResult: Sendable, Equatable {
    let transcriptID: UUID
    let relativePath: String
    let entries: [SearchIndexEntry]
}

/// SwiftData access for transcripts and the persistent transcription queue.
@ModelActor
actor TranscriptStore {
    static let retryDelays: [TimeInterval] = [30, 120, 600]
    static let maxAttempts = 3

    /// Creates missing queue rows, recovers rows left `running` by a crash,
    /// and returns the tasks that are due now, oldest chunk first.
    func prepareDueTasks(
        providerID: String,
        providerVersion: String,
        now: Date
    ) throws -> [TranscriptionTaskSnapshot] {
        let chunks = try modelContext.fetch(
            FetchDescriptor<ReceivedChunkRecord>(
                sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.sequence)]
            )
        )
        let transcripts = try modelContext.fetch(
            FetchDescriptor<TranscriptRecord>()
        )
        let readyChunkIDs = Set(
            transcripts
                .filter {
                    $0.providerID == providerID
                        && $0.providerVersion == providerVersion
                        && $0.status == .ready
                }
                .map(\.chunkID)
        )

        var tasks = try modelContext.fetch(
            FetchDescriptor<TranscriptionTaskRecord>()
        )
        let chunkIDs = Set(chunks.map(\.chunkID))
        for task in tasks where !chunkIDs.contains(task.chunkID) {
            modelContext.delete(task)
        }
        tasks.removeAll { !chunkIDs.contains($0.chunkID) }

        var taskByChunk: [UUID: TranscriptionTaskRecord] = [:]
        for task in tasks
        where task.providerID == providerID && task.providerVersion == providerVersion {
            taskByChunk[task.chunkID] = task
        }

        for chunk in chunks where !readyChunkIDs.contains(chunk.chunkID) {
            if let task = taskByChunk[chunk.chunkID] {
                if task.state == .running {
                    task.state = .queued
                    task.nextAttemptAt = now
                    task.updatedAt = now
                }
            } else {
                let task = TranscriptionTaskRecord(
                    chunkID: chunk.chunkID,
                    sessionID: chunk.sessionID,
                    providerID: providerID,
                    providerVersion: providerVersion,
                    nextAttemptAt: now,
                    createdAt: now,
                    updatedAt: now
                )
                modelContext.insert(task)
                taskByChunk[chunk.chunkID] = task
            }
        }
        try modelContext.save()

        let chunkByID = Dictionary(
            uniqueKeysWithValues: chunks.map { ($0.chunkID, $0) }
        )
        return taskByChunk.values
            .filter { $0.state == .queued && $0.nextAttemptAt <= now }
            .sorted { lhs, rhs in
                let left = chunkByID[lhs.chunkID]?.startedAt ?? .distantPast
                let right = chunkByID[rhs.chunkID]?.startedAt ?? .distantPast
                if left == right {
                    return (chunkByID[lhs.chunkID]?.sequence ?? 0)
                        < (chunkByID[rhs.chunkID]?.sequence ?? 0)
                }
                return left < right
            }
            .compactMap { task in
                guard let chunk = chunkByID[task.chunkID] else {
                    return nil
                }
                return TranscriptionTaskSnapshot(
                    taskID: task.taskID,
                    chunkID: task.chunkID,
                    sessionID: task.sessionID,
                    startedAtMs: TimeMath.epochMs(chunk.startedAt),
                    durationMs: Int64(chunk.durationMs),
                    relativePath: chunk.relativePath,
                    attemptCount: task.attemptCount
                )
            }
    }

    func hasReadyTranscript(
        chunkID: UUID,
        providerID: String,
        providerVersion: String
    ) throws -> Bool {
        try findTranscript(
            chunkID: chunkID,
            providerID: providerID,
            providerVersion: providerVersion
        )?.status == .ready
    }

    func saveTranscript(
        snapshot: TranscriptionTaskSnapshot,
        draft: TranscriptDraft,
        now: Date
    ) throws -> TranscriptSaveResult? {
        guard let chunk = try findChunk(id: snapshot.chunkID),
            let task = try findTask(id: snapshot.taskID)
        else {
            return nil
        }
        if let existing = try findTranscript(
            chunkID: snapshot.chunkID,
            providerID: draft.providerID,
            providerVersion: draft.providerVersion
        ), existing.status == .ready {
            task.state = .ready
            task.lastErrorCode = nil
            task.updatedAt = now
            try modelContext.save()
            return TranscriptSaveResult(
                transcriptID: existing.transcriptID,
                relativePath: Self.transcriptRelativePath(
                    chunkStartedAt: chunk.startedAt,
                    chunkID: chunk.chunkID,
                    transcriptID: existing.transcriptID
                ),
                entries: try indexEntries(
                    transcript: existing,
                    chunk: chunk
                )
            )
        }

        let transcript =
            try findTranscript(
                chunkID: snapshot.chunkID,
                providerID: draft.providerID,
                providerVersion: draft.providerVersion
            )
            ?? {
                let record = TranscriptRecord(
                    chunkID: chunk.chunkID,
                    sessionID: chunk.sessionID,
                    providerID: draft.providerID,
                    providerVersion: draft.providerVersion,
                    language: draft.language,
                    text: draft.text,
                    status: .ready,
                    createdAt: now,
                    updatedAt: now
                )
                modelContext.insert(record)
                return record
            }()
        transcript.text = draft.text
        transcript.language = draft.language
        transcript.status = .ready
        transcript.errorCode = nil
        transcript.updatedAt = now

        let transcriptID = transcript.transcriptID
        let staleSegments = try modelContext.fetch(
            FetchDescriptor<TranscriptSegmentRecord>(
                predicate: #Predicate { segment in
                    segment.transcriptID == transcriptID
                }
            )
        )
        for segment in staleSegments {
            modelContext.delete(segment)
        }
        for segmentDraft in draft.segments where !segmentDraft.text.isEmpty {
            let endMs = max(segmentDraft.endMs, segmentDraft.startMs)
            let segment = TranscriptSegmentRecord(
                transcriptID: transcript.transcriptID,
                chunkID: chunk.chunkID,
                sessionID: chunk.sessionID,
                startMs: segmentDraft.startMs,
                endMs: endMs,
                text: segmentDraft.text,
                confidence: segmentDraft.confidence
            )
            modelContext.insert(segment)
        }

        task.state = .ready
        task.attemptCount = 0
        task.lastErrorCode = nil
        task.updatedAt = now
        try modelContext.save()

        return TranscriptSaveResult(
            transcriptID: transcript.transcriptID,
            relativePath: Self.transcriptRelativePath(
                chunkStartedAt: chunk.startedAt,
                chunkID: chunk.chunkID,
                transcriptID: transcript.transcriptID
            ),
            entries: try indexEntries(transcript: transcript, chunk: chunk)
        )
    }

    /// All searchable entries of the newest ready transcript per chunk.
    func indexEntries() throws -> [SearchIndexEntry] {
        let readyRaw = TranscriptStatus.ready.rawValue
        let readyTranscripts = try modelContext.fetch(
            FetchDescriptor<TranscriptRecord>(
                predicate: #Predicate { record in
                    record.statusRaw == readyRaw
                }
            )
        )
        var latestByChunk: [UUID: TranscriptRecord] = [:]
        for transcript in readyTranscripts {
            if let existing = latestByChunk[transcript.chunkID],
                existing.updatedAt >= transcript.updatedAt
            {
                continue
            }
            latestByChunk[transcript.chunkID] = transcript
        }

        let segments = try modelContext.fetch(
            FetchDescriptor<TranscriptSegmentRecord>()
        )
        return segments.compactMap { segment in
            guard let transcript = latestByChunk[segment.chunkID],
                transcript.transcriptID == segment.transcriptID
            else {
                return nil
            }
            return SearchIndexEntry(
                segmentID: segment.segmentID,
                chunkID: segment.chunkID,
                sessionID: segment.sessionID,
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                language: transcript.language,
                providerVersion: transcript.providerVersion
            )
        }
    }

    /// Records a failed attempt. Returns the attempt count after recording.
    @discardableResult
    func recordFailure(
        snapshot: TranscriptionTaskSnapshot,
        providerID: String,
        providerVersion: String,
        language: String,
        code: String,
        now: Date
    ) throws -> Int {
        guard let chunk = try findChunk(id: snapshot.chunkID),
            let task = try findTask(id: snapshot.taskID)
        else {
            return 0
        }
        if try hasReadyTranscript(
            chunkID: chunk.chunkID,
            providerID: providerID,
            providerVersion: providerVersion
        ) {
            task.state = .ready
            task.updatedAt = now
            try modelContext.save()
            return 0
        }

        task.attemptCount += 1
        task.lastErrorCode = code
        task.updatedAt = now
        if task.attemptCount >= Self.maxAttempts {
            task.state = .failed
            task.nextAttemptAt = .distantFuture
        } else {
            task.state = .queued
            task.nextAttemptAt = now.addingTimeInterval(
                Self.retryDelay(forAttempt: task.attemptCount)
            )
        }

        let transcript =
            try findTranscript(
                chunkID: chunk.chunkID,
                providerID: providerID,
                providerVersion: providerVersion
            )
            ?? {
                let record = TranscriptRecord(
                    chunkID: chunk.chunkID,
                    sessionID: chunk.sessionID,
                    providerID: providerID,
                    providerVersion: providerVersion,
                    language: language,
                    text: "",
                    status: .failed,
                    createdAt: now,
                    updatedAt: now
                )
                modelContext.insert(record)
                return record
            }()
        transcript.status = .failed
        transcript.errorCode = code
        if transcript.language.isEmpty {
            transcript.language = language
        }
        transcript.updatedAt = now
        try modelContext.save()
        return task.attemptCount
    }

    /// Resets failed work for one chunk so the next run picks it up.
    func retryFailedTasks(
        chunkID: UUID,
        providerID: String,
        providerVersion: String,
        now: Date
    ) throws {
        let tasks = try modelContext.fetch(
            FetchDescriptor<TranscriptionTaskRecord>(
                predicate: #Predicate { task in
                    task.chunkID == chunkID
                }
            )
        )
        for task in tasks
        where task.providerID == providerID
            && task.providerVersion == providerVersion
            && task.state == .failed
        {
            task.state = .queued
            task.attemptCount = 0
            task.nextAttemptAt = now
            task.lastErrorCode = nil
            task.updatedAt = now
        }

        let transcripts = try modelContext.fetch(
            FetchDescriptor<TranscriptRecord>(
                predicate: #Predicate { transcript in
                    transcript.chunkID == chunkID
                }
            )
        )
        for transcript in transcripts
        where transcript.providerID == providerID
            && transcript.providerVersion == providerVersion
            && transcript.status == .failed
        {
            transcript.status = .pending
            transcript.errorCode = nil
            transcript.updatedAt = now
        }
        try modelContext.save()
    }

    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        guard !retryDelays.isEmpty else {
            return 60
        }
        let index = min(max(attempt - 1, 0), retryDelays.count - 1)
        return retryDelays[index]
    }

    static func transcriptRelativePath(
        chunkStartedAt: Date,
        chunkID: UUID,
        transcriptID: UUID
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: chunkStartedAt
        )
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return
            "transcripts/\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))/\(chunkID.uuidString)/\(transcriptID.uuidString).json"
    }

    private func indexEntries(
        transcript: TranscriptRecord,
        chunk: ReceivedChunkRecord
    ) throws -> [SearchIndexEntry] {
        let transcriptID = transcript.transcriptID
        let segments = try modelContext.fetch(
            FetchDescriptor<TranscriptSegmentRecord>(
                predicate: #Predicate { segment in
                    segment.transcriptID == transcriptID
                },
                sortBy: [SortDescriptor(\.startMs)]
            )
        )
        return segments.map { segment in
            SearchIndexEntry(
                segmentID: segment.segmentID,
                chunkID: chunk.chunkID,
                sessionID: chunk.sessionID,
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                language: transcript.language,
                providerVersion: transcript.providerVersion
            )
        }
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

    private func findTask(id: UUID) throws -> TranscriptionTaskRecord? {
        var descriptor = FetchDescriptor<TranscriptionTaskRecord>(
            predicate: #Predicate { record in
                record.taskID == id
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func findTranscript(
        chunkID: UUID,
        providerID: String,
        providerVersion: String
    ) throws -> TranscriptRecord? {
        var descriptor = FetchDescriptor<TranscriptRecord>(
            predicate: #Predicate { record in
                record.chunkID == chunkID
                    && record.providerID == providerID
                    && record.providerVersion == providerVersion
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
