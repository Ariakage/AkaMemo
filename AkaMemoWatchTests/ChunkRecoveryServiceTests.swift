import AVFoundation
import XCTest

@testable import AkaMemoWatch

private enum RecoveryTestError: Error {
    case bufferAllocationFailed
    case invalidJSON
}

final class ChunkRecoveryServiceTests: XCTestCase {
    private let startMs: Int64 = 1_700_000_000_000

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoRecovery-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSession(
        in root: URL
    ) throws -> (sessionID: UUID, sessionDirectory: URL, partsDirectory: URL) {
        let sessionID = UUID()
        let sessionDirectory = root.appending(
            path: sessionID.uuidString,
            directoryHint: .isDirectory
        )
        let partsDirectory = sessionDirectory.appending(
            path: ".parts",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: partsDirectory,
            withIntermediateDirectories: true
        )
        return (sessionID, sessionDirectory, partsDirectory)
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
            throw RecoveryTestError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw RecoveryTestError.invalidJSON
        }
        return object
    }

    func testRecoverAllFinalizesReadablePartAndRebuildsManifest() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let name = "0000-\(startMs).m4a"
        let partURL = session.partsDirectory.appending(path: name)
        try writeSilentM4A(to: partURL)

        let service = ChunkRecoveryService(audioRoot: root)
        let summary = await service.recoverAll()

        XCTAssertEqual(summary.sessionsScanned, 1)
        XCTAssertEqual(summary.recoveredChunks, 1)
        XCTAssertEqual(summary.quarantinedChunks, 0)
        let finalURL = session.sessionDirectory.appending(path: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: session.sessionDirectory.appending(path: "0000-\(startMs).json").path
            )
        )

        let manifest = try readJSON(
            session.sessionDirectory.appending(path: "manifest.json")
        )
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["localState"] as? String, "present")
        XCTAssertEqual(entries.first?["sequence"] as? Int, 0)
        XCTAssertEqual(entries.first?["startedAtMs"] as? Int64, startMs)

        let second = await service.recoverAll()
        XCTAssertEqual(second.recoveredChunks, 0)
        XCTAssertEqual(second.quarantinedChunks, 0)
        let manifestAgain = try readJSON(
            session.sessionDirectory.appending(path: "manifest.json")
        )
        XCTAssertEqual((manifestAgain["entries"] as? [[String: Any]])?.count, 1)
    }

    func testRecoverAllQuarantinesUnreadablePart() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let name = "0001-\(startMs + 1_000).m4a"
        let partURL = session.partsDirectory.appending(path: name)
        try Data("not audio".utf8).write(to: partURL)

        let service = ChunkRecoveryService(audioRoot: root)
        let summary = await service.recoverAll()

        XCTAssertEqual(summary.quarantinedChunks, 1)
        XCTAssertEqual(summary.recoveredChunks, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: session.sessionDirectory.appending(path: name + ".corrupt").path
            )
        )

        let second = await service.recoverAll()
        XCTAssertEqual(second.quarantinedChunks, 0)
    }

    func testRecoverAllRebuildsMissingSidecarForSealedChunk() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let name = "0002-\(startMs + 2_000).m4a"
        let finalURL = session.sessionDirectory.appending(path: name)
        try writeSilentM4A(to: finalURL)

        let service = ChunkRecoveryService(audioRoot: root)
        let summary = await service.recoverAll()

        XCTAssertEqual(summary.rebuiltSidecars, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: session.sessionDirectory.appending(
                    path: "0002-\(startMs + 2_000).json"
                ).path
            )
        )
        let manifest = try readJSON(
            session.sessionDirectory.appending(path: "manifest.json")
        )
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["sequence"] as? Int, 2)
    }
}
