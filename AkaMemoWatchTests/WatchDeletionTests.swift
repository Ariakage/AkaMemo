import AkaMemoCore
import XCTest

@testable import AkaMemoWatch

final class WatchDeletionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoWatchDeletion-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSessionDirectory(
        sessionID: UUID,
        startedAtMs: Int64
    ) throws {
        let directory = root.appending(
            path: "audio/\(sessionID.uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let manifest = ChunkManifest(
            sessionID: sessionID,
            sessionStartedAtMs: startedAtMs,
            entries: [
                ChunkManifest.Entry(
                    chunkID: UUID(),
                    sequence: 0,
                    startedAtMs: startedAtMs,
                    updatedAtMs: startedAtMs
                )
            ]
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appending(path: "manifest.json"))
        let audioName = ChunkPath.fileName(
            sequence: 0,
            startEpochMs: startedAtMs,
            kind: .audio
        )
        try Data("audio".utf8).write(
            to: directory.appending(path: audioName)
        )
    }

    private func makeEnvelope(
        chunkID: UUID,
        sessionID: UUID,
        startedAtMs: Int64
    ) -> ChunkTransferEnvelope {
        ChunkTransferEnvelope(
            chunkID: chunkID,
            sessionID: sessionID,
            sessionStartedAtMs: startedAtMs,
            sequence: 0,
            startedAtMs: startedAtMs,
            durationMs: 1_000,
            byteSize: 5,
            checksumSHA256: String(repeating: "a", count: 64),
            formatVersion: 1,
            sampleRate: 44_100,
            channels: 2,
            bitRate: 96_000,
            relativePath:
                "audio/\(sessionID.uuidString)/0000-\(startedAtMs).m4a"
        )
    }

    func testStorePersistsChunkTombstone() async {
        let store = WatchDeletionStore(appSupportRoot: root)
        let chunkID = UUID()
        let sessionID = UUID()
        let command = DeletionCommand(
            scope: .chunk,
            entityID: chunkID,
            sessionID: sessionID,
            deletedAtMs: 1_000
        )

        _ = await store.apply(command)
        let deleted = await store.isDeleted(
            chunkID: chunkID,
            sessionID: sessionID,
            sessionStartedAtMs: 500
        )
        XCTAssertTrue(deleted)

        let reloaded = WatchDeletionStore(appSupportRoot: root)
        let reloadedDeleted = await reloaded.isDeleted(
            chunkID: chunkID,
            sessionID: sessionID,
            sessionStartedAtMs: 500
        )
        XCTAssertTrue(reloadedDeleted)
        let otherDeleted = await reloaded.isDeleted(
            chunkID: UUID(),
            sessionID: sessionID,
            sessionStartedAtMs: 500
        )
        XCTAssertFalse(otherDeleted)
    }

    func testEpochRejectsOlderSessionsOnly() async {
        let store = WatchDeletionStore(appSupportRoot: root)
        _ = await store.apply(
            DeletionCommand(scope: .all, epochMs: 5_000, deletedAtMs: 5_000)
        )

        let old = await store.isDeleted(
            chunkID: nil,
            sessionID: UUID(),
            sessionStartedAtMs: 1_000
        )
        let new = await store.isDeleted(
            chunkID: nil,
            sessionID: UUID(),
            sessionStartedAtMs: 9_000
        )
        XCTAssertTrue(old)
        XCTAssertFalse(new)
    }

    func testQueueDoesNotEnqueueDeletedChunk() async {
        let store = WatchDeletionStore(appSupportRoot: root)
        let chunkID = UUID()
        let sessionID = UUID()
        _ = await store.apply(
            DeletionCommand(
                scope: .chunk,
                entityID: chunkID,
                sessionID: sessionID,
                deletedAtMs: 1_000
            )
        )
        let queue = WatchTransferQueue(
            appSupportRoot: root,
            deletionStore: store
        )
        await queue.enqueue(
            makeEnvelope(
                chunkID: chunkID,
                sessionID: sessionID,
                startedAtMs: 500
            )
        )

        let entries = await queue.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testQueueDropsEntriesOnDeleteAll() async {
        let store = WatchDeletionStore(appSupportRoot: root)
        let queue = WatchTransferQueue(
            appSupportRoot: root,
            deletionStore: store
        )
        let oldChunk = UUID()
        let newChunk = UUID()
        await queue.enqueue(
            makeEnvelope(
                chunkID: oldChunk,
                sessionID: UUID(),
                startedAtMs: 1_000
            )
        )
        await queue.enqueue(
            makeEnvelope(
                chunkID: newChunk,
                sessionID: UUID(),
                startedAtMs: 9_000
            )
        )

        await queue.applyDeletion(
            DeletionCommand(scope: .all, epochMs: 5_000, deletedAtMs: 5_000)
        )

        let entries = await queue.entries()
        XCTAssertEqual(entries.map(\.envelope.chunkID), [newChunk])
    }

    func testHandlerRemovesSessionAndLocation() async throws {
        let sessionID = UUID()
        try makeSessionDirectory(sessionID: sessionID, startedAtMs: 1_000)
        let locationDirectory = root.appending(
            path: "location/2026/10/28",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: locationDirectory,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: locationDirectory.appending(
                path: sessionID.uuidString + ".jsonl"
            )
        )

        let store = WatchDeletionStore(appSupportRoot: root)
        let queue = WatchTransferQueue(
            appSupportRoot: root,
            deletionStore: store
        )
        let handler = WatchDeletionHandler(
            appSupportRoot: root,
            deletionStore: store,
            queue: queue
        )

        await handler.apply(
            DeletionCommand(
                scope: .session,
                entityID: sessionID,
                sessionID: sessionID,
                deletedAtMs: 2_000
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "audio/\(sessionID.uuidString)").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: locationDirectory.appending(
                    path: sessionID.uuidString + ".jsonl"
                ).path
            )
        )
        let deleted = await store.isDeleted(
            chunkID: nil,
            sessionID: sessionID,
            sessionStartedAtMs: 1_000
        )
        XCTAssertTrue(deleted)
    }

    func testDeleteAllKeepsSessionStartedAfterEpoch() async throws {
        let oldSession = UUID()
        let newSession = UUID()
        try makeSessionDirectory(sessionID: oldSession, startedAtMs: 1_000)
        try makeSessionDirectory(sessionID: newSession, startedAtMs: 9_000)

        let store = WatchDeletionStore(appSupportRoot: root)
        let queue = WatchTransferQueue(
            appSupportRoot: root,
            deletionStore: store
        )
        let handler = WatchDeletionHandler(
            appSupportRoot: root,
            deletionStore: store,
            queue: queue
        )

        await handler.apply(
            DeletionCommand(scope: .all, epochMs: 5_000, deletedAtMs: 5_000)
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "audio/\(oldSession.uuidString)").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appending(path: "audio/\(newSession.uuidString)").path
            )
        )
    }
}
