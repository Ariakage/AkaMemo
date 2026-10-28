import AkaMemoCore
import SwiftData
import XCTest

@testable import AkaMemo

private final class RecordingDeletionSender: DeletionCommandSending, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommands: [DeletionCommand] = []

    var commands: [DeletionCommand] {
        lock.lock()
        defer { lock.unlock() }
        return storedCommands
    }

    func sendDeletion(_ command: DeletionCommand) -> Bool {
        lock.lock()
        storedCommands.append(command)
        lock.unlock()
        return true
    }
}

final class DeletionServiceTests: XCTestCase {
    private struct Environment {
        let root: URL
        let container: ModelContainer
        let deletionStore: DeletionStore
        let index: SQLiteSearchIndex
        let sender: RecordingDeletionSender
        let service: DeletionService
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoDeletionTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ReceivedChunkRecord.self,
            TranscriptRecord.self,
            TranscriptSegmentRecord.self,
            TranscriptionTaskRecord.self,
            DeletionTombstoneRecord.self,
            DataEpochRecord.self,
            LocationTrackRecord.self,
            configurations: configuration
        )
        let deletionStore = DeletionStore(modelContainer: container)
        let index = try SQLiteSearchIndex(
            databaseURL: root.appending(path: "index/search.sqlite")
        )
        let sender = RecordingDeletionSender()
        let service = DeletionService(
            store: deletionStore,
            applicationSupport: root,
            index: index,
            sender: sender
        )
        return Environment(
            root: root,
            container: container,
            deletionStore: deletionStore,
            index: index,
            sender: sender,
            service: service
        )
    }

    @discardableResult
    private func insertChunk(
        in environment: Environment,
        sessionID: UUID,
        sequence: Int,
        text: String,
        startedAtMs: Int64
    ) throws -> ReceivedChunkRecord {
        let chunkID = UUID()
        let startedAt = TimeMath.date(epochMs: startedAtMs)
        let relativePath =
            "audio/2026/10/28/\(sessionID.uuidString)/\(String(format: "%04d", sequence))-\(startedAtMs).m4a"
        let audioURL = environment.root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: audioURL)
        let sidecarURL = audioURL.deletingPathExtension()
            .appendingPathExtension("json")
        try Data("{}".utf8).write(to: sidecarURL)

        let context = ModelContext(environment.container)
        let chunk = ReceivedChunkRecord(
            chunkID: chunkID,
            sessionID: sessionID,
            sessionStartedAt: startedAt,
            sequence: sequence,
            startedAt: startedAt,
            durationMs: 12_000,
            byteSize: 5,
            checksumSHA256: String(repeating: "a", count: 64),
            formatVersion: 1,
            sampleRate: 44_100,
            channels: 2,
            bitRate: 96_000,
            relativePath: relativePath,
            receivedAt: startedAt
        )
        context.insert(chunk)
        let transcript = TranscriptRecord(
            chunkID: chunkID,
            sessionID: sessionID,
            providerID: "fake",
            providerVersion: "1",
            language: "zh-Hans",
            text: text,
            status: .ready
        )
        context.insert(transcript)
        context.insert(
            TranscriptSegmentRecord(
                transcriptID: transcript.transcriptID,
                chunkID: chunkID,
                sessionID: sessionID,
                startMs: startedAtMs + 100,
                endMs: startedAtMs + 900,
                text: text
            )
        )
        try context.save()
        return chunk
    }

    private func index(
        _ chunk: ReceivedChunkRecord,
        text: String,
        in environment: Environment
    ) async throws {
        try await environment.index.replaceChunk(
            chunk.chunkID,
            with: [
                SearchIndexEntry(
                    segmentID: UUID(),
                    chunkID: chunk.chunkID,
                    sessionID: chunk.sessionID,
                    startMs: TimeMath.epochMs(chunk.startedAt),
                    endMs: TimeMath.epochMs(chunk.startedAt) + 1_000,
                    text: text,
                    language: "zh-Hans",
                    providerVersion: "1"
                )
            ]
        )
    }

    private func chunkCount(in environment: Environment) throws -> Int {
        let context = ModelContext(environment.container)
        return try context.fetchCount(
            FetchDescriptor<ReceivedChunkRecord>()
        )
    }

    func testDeleteChunkRemovesOnlyThatChunk() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sessionID = UUID()
        let first = try insertChunk(
            in: environment,
            sessionID: sessionID,
            sequence: 0,
            text: "第一段内容",
            startedAtMs: 1_800_000_000_000
        )
        let second = try insertChunk(
            in: environment,
            sessionID: sessionID,
            sequence: 1,
            text: "第二段内容",
            startedAtMs: 1_800_000_012_000
        )
        try await index(first, text: "第一段内容", in: environment)
        try await index(second, text: "第二段内容", in: environment)

        try await environment.service.deleteChunk(first.chunkID)

        let remainingCount = try chunkCount(in: environment)
        XCTAssertEqual(remainingCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.root.appending(path: first.relativePath).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.root.appending(path: second.relativePath).path
            )
        )
        let removedHits = try await environment.index.search(
            SearchQuery(text: "第一段")
        )
        let keptHits = try await environment.index.search(
            SearchQuery(text: "第二段")
        )
        XCTAssertTrue(removedHits.isEmpty)
        XCTAssertEqual(keptHits.count, 1)
        XCTAssertEqual(environment.sender.commands.last?.scope, .chunk)

        let match = try await environment.deletionStore.matchForInbox(
            chunkID: first.chunkID,
            sessionID: sessionID,
            sessionStartedAtMs: 1_800_000_000_000
        )
        if case .chunk = match {
        } else {
            XCTFail("expected chunk tombstone, got \(match)")
        }
    }

    func testDeleteSessionRemovesAllChunksInThatSession() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let deletedSession = UUID()
        let keptSession = UUID()
        for sequence in 0..<2 {
            let text = "删除会话内容 \(sequence)"
            let chunk = try insertChunk(
                in: environment,
                sessionID: deletedSession,
                sequence: sequence,
                text: text,
                startedAtMs: 1_800_000_000_000 + Int64(sequence) * 12_000
            )
            try await index(chunk, text: text, in: environment)
        }
        let kept = try insertChunk(
            in: environment,
            sessionID: keptSession,
            sequence: 0,
            text: "保留会话内容",
            startedAtMs: 1_800_000_100_000
        )
        try await index(kept, text: "保留会话内容", in: environment)

        try await environment.service.deleteSession(deletedSession)

        let remainingCount = try chunkCount(in: environment)
        XCTAssertEqual(remainingCount, 1)
        let keptHits = try await environment.index.search(
            SearchQuery(text: "保留会话")
        )
        let deletedHits = try await environment.index.search(
            SearchQuery(text: "删除会话")
        )
        XCTAssertEqual(keptHits.count, 1)
        XCTAssertTrue(deletedHits.isEmpty)
        XCTAssertEqual(kept.sessionID, keptSession)
        XCTAssertEqual(environment.sender.commands.last?.scope, .session)
    }

    func testDeleteAllWritesEpochAndRejectsOldSessions() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try insertChunk(
            in: environment,
            sessionID: UUID(),
            sequence: 0,
            text: "旧数据",
            startedAtMs: 1_700_000_000_000
        )

        try await environment.service.deleteAll()

        let remainingCount = try chunkCount(in: environment)
        let indexCount = try await environment.index.entryCount()
        XCTAssertEqual(remainingCount, 0)
        XCTAssertEqual(indexCount, 0)
        let commands = try await environment.deletionStore
            .unacknowledgedCommands()
        XCTAssertEqual(commands.last?.scope, .all)

        let oldMatch = try await environment.deletionStore.matchForInbox(
            chunkID: UUID(),
            sessionID: UUID(),
            sessionStartedAtMs: 1_700_000_000_000
        )
        let newMatch = try await environment.deletionStore.matchForInbox(
            chunkID: UUID(),
            sessionID: UUID(),
            sessionStartedAtMs: TimeMath.epochMs(Date()) + 86_400_000
        )
        if case .epoch = oldMatch {
        } else {
            XCTFail("expected epoch rejection, got \(oldMatch)")
        }
        XCTAssertEqual(newMatch, .none)

        if let command = commands.last {
            try await environment.deletionStore.markAcknowledged(
                tombstoneID: command.tombstoneID,
                now: Date()
            )
            let afterAck = try await environment.deletionStore
                .unacknowledgedCommands()
            XCTAssertTrue(afterAck.isEmpty)
        }
    }

    func testDeleteAllKeepsSessionStartedAfterEpoch() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let futureStart = TimeMath.epochMs(Date()) + 86_400_000
        let oldChunk = try insertChunk(
            in: environment,
            sessionID: UUID(),
            sequence: 0,
            text: "旧会话内容",
            startedAtMs: 1_700_000_000_000
        )
        let newChunk = try insertChunk(
            in: environment,
            sessionID: UUID(),
            sequence: 0,
            text: "新会话内容",
            startedAtMs: futureStart
        )
        try await index(oldChunk, text: "旧会话内容", in: environment)
        try await index(newChunk, text: "新会话内容", in: environment)

        try await environment.service.deleteAll()

        let remainingCount = try chunkCount(in: environment)
        let oldHits = try await environment.index.search(
            SearchQuery(text: "旧会话")
        )
        let newHits = try await environment.index.search(
            SearchQuery(text: "新会话")
        )
        XCTAssertEqual(remainingCount, 1)
        XCTAssertTrue(oldHits.isEmpty)
        XCTAssertEqual(newHits.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.root.appending(path: newChunk.relativePath).path
            )
        )
    }

    private func insertTrack(
        in environment: Environment,
        sessionID: UUID
    ) throws -> LocationTrackRecord {
        let trackID = UUID()
        let now = Date()
        let relativePath =
            "location/2026/10/28/\(sessionID.uuidString).jsonl"
        let url = environment.root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)
        let context = ModelContext(environment.container)
        let track = LocationTrackRecord(
            trackID: trackID,
            sessionID: sessionID,
            sessionStartedAt: now,
            startedAt: now,
            endedAt: now,
            pointCount: 1,
            distanceMeters: nil,
            relativePath: relativePath,
            checksumSHA256: String(repeating: "b", count: 64),
            importedAt: now
        )
        context.insert(track)
        try context.save()
        return track
    }

    func testDeleteTrackKeepsAudioTranscriptsAndIndex() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sessionID = UUID()
        let chunk = try insertChunk(
            in: environment,
            sessionID: sessionID,
            sequence: 0,
            text: "轨迹删除不影响转写",
            startedAtMs: 1_800_000_000_000
        )
        try await index(
            chunk,
            text: "轨迹删除不影响转写",
            in: environment
        )
        let track = try insertTrack(in: environment, sessionID: sessionID)

        try await environment.service.deleteTrack(
            track.trackID,
            sessionID: sessionID
        )

        let context = ModelContext(environment.container)
        let tracks = try context.fetch(
            FetchDescriptor<LocationTrackRecord>()
        )
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.root.appending(
                    path: track.relativePath
                ).path
            )
        )
        XCTAssertEqual(try chunkCount(in: environment), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.root.appending(
                    path: chunk.relativePath
                ).path
            )
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<TranscriptRecord>()),
            1
        )
        let hits = try await environment.index.search(
            SearchQuery(text: "轨迹删除")
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(environment.sender.commands.last?.scope, .location)

        let trackMatch = try await environment.deletionStore.matchForTrack(
            sessionID: sessionID,
            sessionStartedAtMs: TimeMath.epochMs(chunk.startedAt)
        )
        if case .location = trackMatch {
        } else {
            XCTFail("expected location tombstone, got \(trackMatch)")
        }
        let inboxMatch = try await environment.deletionStore.matchForInbox(
            chunkID: UUID(),
            sessionID: sessionID,
            sessionStartedAtMs: TimeMath.epochMs(chunk.startedAt)
        )
        XCTAssertEqual(inboxMatch, .none)
    }

    func testInboxRejectsTombstonedChunk() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let chunkID = UUID()
        let sessionID = UUID()
        _ = try await environment.deletionStore.prepareDeletion(
            scope: .chunk,
            entityID: chunkID,
            sessionID: sessionID,
            reason: "userDelete"
        )

        let memoryStore = MemoryStore(
            modelContainer: environment.container
        )
        let inbox = PhoneInboxService(
            store: memoryStore,
            applicationSupport: environment.root,
            deletionStore: environment.deletionStore
        )
        let incoming = environment.root.appending(
            path: "incoming-\(UUID().uuidString).m4a"
        )
        try Data("data".utf8).write(to: incoming)
        let envelope = ChunkTransferEnvelope(
            chunkID: chunkID,
            sessionID: sessionID,
            sessionStartedAtMs: 1_800_000_000_000,
            sequence: 0,
            startedAtMs: 1_800_000_000_000,
            durationMs: 1_000,
            byteSize: 4,
            checksumSHA256: String(repeating: "a", count: 64),
            formatVersion: 1,
            sampleRate: 44_100,
            channels: 2,
            bitRate: 96_000,
            relativePath: "audio/session/0000-1.m4a"
        )

        let result = await inbox.receive(
            fileURL: incoming,
            envelope: envelope
        )

        XCTAssertEqual(result, .rejected("deletedChunk"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: incoming.path)
        )
        let storedCount = try await memoryStore.count()
        XCTAssertEqual(storedCount, 0)
    }
}
