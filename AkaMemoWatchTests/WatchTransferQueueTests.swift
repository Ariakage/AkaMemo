import AkaMemoCore
import XCTest

@testable import AkaMemoWatch

private final class FakeTransferTransport: ChunkTransferTransport, @unchecked Sendable {
    var result = true
    private(set) var transfers: [(url: URL, metadata: [String: String])] = []

    func transferFile(at url: URL, metadata: [String: String]) -> Bool {
        transfers.append((url, metadata))
        return result
    }
}

final class WatchTransferQueueTests: XCTestCase {
    private let startMs: Int64 = 1_700_000_000_000

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoTransferTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeEnvelope(
        sessionID: UUID,
        sequence: Int = 0
    ) -> ChunkTransferEnvelope {
        ChunkTransferEnvelope(
            chunkID: UUID(),
            sessionID: sessionID,
            sessionStartedAtMs: startMs,
            sequence: sequence,
            startedAtMs: startMs,
            durationMs: 60_000,
            byteSize: 5,
            checksumSHA256: String(repeating: "a", count: 64),
            formatVersion: 1,
            sampleRate: 44_100,
            channels: 2,
            bitRate: 96_000,
            relativePath: "audio/\(sessionID.uuidString)/0000-\(startMs).m4a"
        )
    }

    private func writeAudioFile(for envelope: ChunkTransferEnvelope, in root: URL) throws {
        let url = root.appending(path: envelope.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: url)
    }

    func testEnqueueTransfersAndConfirms() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let envelope = makeEnvelope(sessionID: sessionID)
        try writeAudioFile(for: envelope, in: root)
        let transport = FakeTransferTransport()
        let queue = WatchTransferQueue(appSupportRoot: root)
        await queue.setTransport(transport)

        await queue.enqueue(
            envelope,
            now: Date(timeIntervalSince1970: TimeInterval(startMs) / 1000)
        )

        var entries = await queue.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.state, .transferring)
        XCTAssertEqual(transport.transfers.count, 1)
        XCTAssertEqual(
            transport.transfers.first?.metadata["chunkID"],
            envelope.chunkID.uuidString
        )

        await queue.handleTransferFinished(
            chunkID: envelope.chunkID,
            errorCode: nil,
            now: Date(timeIntervalSince1970: TimeInterval(startMs) / 1000 + 1)
        )
        entries = await queue.entries()
        XCTAssertEqual(entries.first?.state, .received)

        await queue.handleConfirmation(
            chunkID: envelope.chunkID,
            checksum: envelope.checksumSHA256,
            now: Date(timeIntervalSince1970: TimeInterval(startMs) / 1000 + 2)
        )
        entries = await queue.entries()
        XCTAssertEqual(entries.first?.state, .confirmed)

        let reloaded = WatchTransferQueue(appSupportRoot: root)
        let reloadedEntries = await reloaded.entries()
        XCTAssertEqual(reloadedEntries.first?.state, .confirmed)
    }

    func testFailedTransferSchedulesBackoff() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let envelope = makeEnvelope(sessionID: sessionID)
        try writeAudioFile(for: envelope, in: root)
        let transport = FakeTransferTransport()
        transport.result = false
        let queue = WatchTransferQueue(appSupportRoot: root)
        await queue.setTransport(transport)
        let now = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000)

        await queue.enqueue(envelope, now: now)

        var entries = await queue.entries()
        XCTAssertEqual(entries.first?.state, .failed)
        XCTAssertEqual(entries.first?.attemptCount, 1)
        XCTAssertEqual(
            entries.first?.nextAttemptAtMs,
            startMs + 5_000
        )

        transport.result = true
        await queue.tick(
            now: Date(timeIntervalSince1970: TimeInterval(startMs) / 1000 + 6)
        )
        entries = await queue.entries()
        XCTAssertEqual(entries.first?.state, .transferring)
        XCTAssertEqual(transport.transfers.count, 2)
    }

    func testAcknowledgementTimeoutResendsChunk() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let envelope = makeEnvelope(sessionID: sessionID)
        try writeAudioFile(for: envelope, in: root)
        let transport = FakeTransferTransport()
        let queue = WatchTransferQueue(appSupportRoot: root)
        await queue.setTransport(transport)
        let start = TimeInterval(startMs) / 1000

        await queue.enqueue(envelope, now: Date(timeIntervalSince1970: start))
        await queue.handleTransferFinished(
            chunkID: envelope.chunkID,
            errorCode: nil,
            now: Date(timeIntervalSince1970: start + 1)
        )
        await queue.tick(now: Date(timeIntervalSince1970: start + 100))
        XCTAssertEqual(transport.transfers.count, 1)

        await queue.tick(now: Date(timeIntervalSince1970: start + 602))
        XCTAssertEqual(transport.transfers.count, 2)
        let entries = await queue.entries()
        XCTAssertEqual(entries.first?.state, .transferring)
    }

    func testEnqueueSealedChunksNotInQueueAddsExistingChunk() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let audioDirectory = root.appending(
            path: "audio/\(sessionID.uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
        let audioURL = audioDirectory.appending(path: "0000-\(startMs).m4a")
        try Data("audio".utf8).write(to: audioURL)
        let metadata = ChunkMetadataSnapshot(
            chunkID: UUID(),
            sessionID: sessionID,
            sessionStartedAtMs: startMs,
            sequence: 0,
            startedAtMs: startMs,
            durationMs: 60_000,
            byteSize: 5,
            checksumSHA256: String(repeating: "a", count: 64),
            relativePath: "audio/\(sessionID.uuidString)/0000-\(startMs).m4a",
            createdAtMs: startMs
        )
        let encoder = JSONEncoder()
        try encoder.encode(metadata).write(
            to: audioDirectory.appending(path: "0000-\(startMs).json")
        )
        let manifest = ChunkManifest(
            sessionID: sessionID,
            sessionStartedAtMs: startMs,
            entries: [
                ChunkManifest.Entry(
                    chunkID: metadata.chunkID,
                    sequence: 0,
                    startedAtMs: startMs,
                    localState: .present,
                    checksumSHA256: metadata.checksumSHA256,
                    byteSize: metadata.byteSize,
                    updatedAtMs: startMs
                )
            ]
        )
        try encoder.encode(manifest).write(
            to: audioDirectory.appending(path: "manifest.json")
        )

        let queue = WatchTransferQueue(appSupportRoot: root)
        let now = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000)
        await queue.enqueueSealedChunksNotInQueue(now: now)
        let entries = await queue.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.envelope.chunkID, metadata.chunkID)
        XCTAssertEqual(entries.first?.state, .queued)

        await queue.enqueueSealedChunksNotInQueue(now: now)
        let secondEntries = await queue.entries()
        XCTAssertEqual(secondEntries.count, 1)
    }

    func testMissingFileFailsWithoutTransfer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let envelope = makeEnvelope(sessionID: UUID())
        let transport = FakeTransferTransport()
        let queue = WatchTransferQueue(appSupportRoot: root)
        await queue.setTransport(transport)

        await queue.enqueue(
            envelope,
            now: Date(timeIntervalSince1970: TimeInterval(startMs) / 1000)
        )

        let entries = await queue.entries()
        XCTAssertEqual(entries.first?.state, .failed)
        XCTAssertEqual(entries.first?.lastErrorCode, "fileMissing")
        XCTAssertEqual(transport.transfers.count, 0)
    }
}
