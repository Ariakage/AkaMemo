import AVFoundation
import AkaMemoCore
import SwiftData
import XCTest

@testable import AkaMemo

private enum InboxTestError: Error {
    case bufferAllocationFailed
}

final class PhoneInboxServiceTests: XCTestCase {
    private func makeEnvironment() throws -> (
        root: URL, inbox: PhoneInboxService, store: MemoryStore
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoInboxTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ReceivedChunkRecord.self,
            configurations: configuration
        )
        let store = MemoryStore(modelContainer: container)
        let inbox = PhoneInboxService(store: store, applicationSupport: root)
        return (root, inbox, store)
    }

    private func writeSilentM4A(to url: URL, seconds: Double = 1) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRatePerChannelKey: 96_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount((format.sampleRate * seconds).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw InboxTestError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }

    private func makeEnvelope(
        for data: Data,
        sequence: Int = 0,
        durationMs: Int = 1_000,
        checksumOverride: String? = nil,
        byteSizeOverride: Int? = nil,
        chunkID: UUID? = nil,
        sessionID: UUID? = nil
    ) -> ChunkTransferEnvelope {
        let startMs: Int64 = 1_700_000_000_000
        return ChunkTransferEnvelope(
            chunkID: chunkID ?? UUID(),
            sessionID: sessionID ?? UUID(),
            sessionStartedAtMs: startMs,
            sequence: sequence,
            startedAtMs: startMs,
            durationMs: durationMs,
            byteSize: byteSizeOverride ?? data.count,
            checksumSHA256: checksumOverride ?? AtomicFileWriter.sha256Hex(data),
            formatVersion: 1,
            sampleRate: 44_100,
            channels: 1,
            bitRate: 96_000,
            relativePath: "audio/session/0000-\(startMs).m4a"
        )
    }

    private func makeIncomingAudio(in root: URL) throws -> (url: URL, data: Data) {
        let url = root.appending(path: "incoming-\(UUID().uuidString).m4a")
        try writeSilentM4A(to: url)
        return (url, try Data(contentsOf: url))
    }

    func testReceiveAcceptsAndStoresChunk() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let incoming = try makeIncomingAudio(in: environment.root)
        let envelope = makeEnvelope(for: incoming.data)

        let result = await environment.inbox.receive(
            fileURL: incoming.url,
            envelope: envelope,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertEqual(result, .accepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.url.path))
        let storedCount = try await environment.store.count()
        XCTAssertEqual(storedCount, 1)
        let files = try FileManager.default.subpathsOfDirectory(
            atPath: environment.root.path
        )
        XCTAssertTrue(files.contains { $0.hasSuffix(".m4a") })
        XCTAssertTrue(files.contains { $0.hasSuffix(".json") })
    }

    func testReceiveIsIdempotentForSameChunk() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let first = try makeIncomingAudio(in: environment.root)
        let envelope = makeEnvelope(for: first.data)
        let secondURL = environment.root.appending(
            path: "incoming-\(UUID().uuidString).m4a"
        )
        try first.data.write(to: secondURL)

        let firstResult = await environment.inbox.receive(
            fileURL: first.url,
            envelope: envelope
        )
        let secondResult = await environment.inbox.receive(
            fileURL: secondURL,
            envelope: envelope
        )

        XCTAssertEqual(firstResult, .accepted)
        XCTAssertEqual(secondResult, .duplicate)
        let storedCount = try await environment.store.count()
        XCTAssertEqual(storedCount, 1)
    }

    func testReceiveRejectsInvalidEnvelope() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let incoming = try makeIncomingAudio(in: environment.root)
        let envelope = makeEnvelope(for: incoming.data, sequence: -1)

        let result = await environment.inbox.receive(
            fileURL: incoming.url,
            envelope: envelope
        )

        XCTAssertEqual(result, .rejected("invalidEnvelope"))
        let storedCount = try await environment.store.count()
        XCTAssertEqual(storedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.url.path))
    }

    func testReceiveRejectsChunkIDReuseWithDifferentChecksum() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let first = try makeIncomingAudio(in: environment.root)
        let firstEnvelope = makeEnvelope(for: first.data)
        let firstResult = await environment.inbox.receive(
            fileURL: first.url,
            envelope: firstEnvelope
        )
        XCTAssertEqual(firstResult, .accepted)

        let secondURL = environment.root.appending(
            path: "conflict-\(UUID().uuidString).m4a"
        )
        try writeSilentM4A(to: secondURL, seconds: 0.5)
        let secondData = try Data(contentsOf: secondURL)
        let secondEnvelope = makeEnvelope(
            for: secondData,
            sequence: 1,
            durationMs: 500,
            chunkID: firstEnvelope.chunkID,
            sessionID: firstEnvelope.sessionID
        )

        let secondResult = await environment.inbox.receive(
            fileURL: secondURL,
            envelope: secondEnvelope
        )

        XCTAssertEqual(secondResult, .rejected("chunkIDConflict"))
        let storedCount = try await environment.store.count()
        XCTAssertEqual(storedCount, 1)
    }

    func testReceiveRejectsChecksumMismatch() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let incoming = try makeIncomingAudio(in: environment.root)
        let envelope = makeEnvelope(
            for: incoming.data,
            checksumOverride: String(repeating: "b", count: 64)
        )

        let result = await environment.inbox.receive(
            fileURL: incoming.url,
            envelope: envelope
        )

        XCTAssertEqual(result, .rejected("checksumMismatch"))
        let storedCount = try await environment.store.count()
        XCTAssertEqual(storedCount, 0)
    }

    func testReceiveRejectsSizeMismatch() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let incoming = try makeIncomingAudio(in: environment.root)
        let envelope = makeEnvelope(
            for: incoming.data,
            byteSizeOverride: incoming.data.count - 1
        )

        let result = await environment.inbox.receive(
            fileURL: incoming.url,
            envelope: envelope
        )

        XCTAssertEqual(result, .rejected("sizeMismatch"))
        let storedCount = try await environment.store.count()
        XCTAssertEqual(storedCount, 0)
    }

    func testReceiveRejectsDurationMismatch() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let incoming = try makeIncomingAudio(in: environment.root)
        let envelope = makeEnvelope(for: incoming.data, durationMs: 5_000)

        let result = await environment.inbox.receive(
            fileURL: incoming.url,
            envelope: envelope
        )

        XCTAssertEqual(result, .rejected("durationMismatch"))
        let storedCount = try await environment.store.count()
        XCTAssertEqual(storedCount, 0)
    }
}
