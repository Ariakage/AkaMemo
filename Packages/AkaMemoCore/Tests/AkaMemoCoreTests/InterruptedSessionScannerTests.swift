import XCTest

@testable import AkaMemoCore

final class InterruptedSessionScannerTests: XCTestCase {
    private var root: URL!
    private var audioRoot: URL!
    private var healthURL: URL!
    private let sessionID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "AkaMemoScannerTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        audioRoot = root.appending(path: "audio", directoryHint: .isDirectory)
        healthURL = root.appending(path: "health.json")
        try FileManager.default.createDirectory(
            at: audioRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(
        state: String,
        endedAtMs: Int64? = nil,
        chunkSequence: Int? = 1,
        lastAudioBufferAtMs: Int64? = 2_000,
        lastHeartbeatAtMs: Int64 = 3_000,
        totalGapMs: Int64 = 500,
        interruptionCount: Int = 1,
        stateVersion: Int64 = 9
    ) -> RecordingHealthSnapshot {
        RecordingHealthSnapshot(
            sessionID: sessionID,
            sessionStartedAtMs: 1_000,
            endedAtMs: endedAtMs,
            lastAudioBufferAtMs: lastAudioBufferAtMs,
            lastHeartbeatAtMs: lastHeartbeatAtMs,
            chunkSequence: chunkSequence,
            bytesWritten: 300,
            audioSessionActive: state == "recording",
            batteryLevel: 0.5,
            state: state,
            stateVersion: stateVersion,
            totalGapMs: totalGapMs,
            interruptionCount: interruptionCount
        )
    }

    private func writeHealth(_ snapshot: RecordingHealthSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: healthURL)
    }

    private func makeSessionDirectory() throws -> URL {
        let directory = audioRoot.appending(
            path: sessionID.uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeManifest(at directory: URL) throws {
        var manifest = ChunkManifest(
            sessionID: sessionID,
            sessionStartedAtMs: 1_000
        )
        manifest.upsert(
            .init(
                sequence: 0,
                startedAtMs: 1_000,
                localState: .present,
                byteSize: 100,
                updatedAtMs: 3_000
            )
        )
        manifest.upsert(
            .init(
                sequence: 1,
                startedAtMs: 61_000,
                localState: .present,
                byteSize: 200,
                updatedAtMs: 3_000
            )
        )
        manifest.upsert(
            .init(
                sequence: 2,
                startedAtMs: 121_000,
                localState: .missing,
                byteSize: nil,
                updatedAtMs: 3_000
            )
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appending(path: "manifest.json"))
    }

    private func makeScanner() -> InterruptedSessionScanner {
        InterruptedSessionScanner(
            audioRoot: audioRoot,
            healthFileURL: healthURL
        )
    }

    func testScanFindsResumableSession() throws {
        let directory = try makeSessionDirectory()
        try writeHealth(snapshot(state: "recording"))
        try writeManifest(at: directory)

        let info = try XCTUnwrap(makeScanner().scan())

        XCTAssertEqual(info.sessionID, sessionID)
        XCTAssertEqual(info.sessionStartedAtMs, 1_000)
        XCTAssertEqual(info.nextSequence, 3)
        XCTAssertEqual(info.sealedChunkCount, 2)
        XCTAssertEqual(info.totalBytes, 300)
        XCTAssertEqual(info.totalGapMs, 500)
        XCTAssertEqual(info.interruptionCount, 1)
        XCTAssertEqual(info.lastStateVersion, 9)
    }

    func testCompletedSessionIsIgnored() throws {
        _ = try makeSessionDirectory()
        try writeHealth(snapshot(state: "completed", endedAtMs: 4_000))

        XCTAssertNil(makeScanner().scan())
    }

    func testPausedSessionIsIgnored() throws {
        _ = try makeSessionDirectory()
        try writeHealth(snapshot(state: "paused"))

        XCTAssertNil(makeScanner().scan())
    }

    func testMissingSessionDirectoryIsIgnored() throws {
        try writeHealth(snapshot(state: "recording"))

        XCTAssertNil(makeScanner().scan())
    }

    func testMalformedHealthIsIgnored() throws {
        try Data("not json".utf8).write(to: healthURL)

        XCTAssertNil(makeScanner().scan())
    }

    func testNextSequenceFallsBackToHeartbeatWithoutManifest() throws {
        _ = try makeSessionDirectory()
        try writeHealth(snapshot(state: "interrupted", chunkSequence: 4))

        let info = try XCTUnwrap(makeScanner().scan())

        XCTAssertEqual(info.nextSequence, 5)
        XCTAssertEqual(info.sealedChunkCount, 0)
        XCTAssertEqual(info.totalBytes, 0)
    }

    func testMarkCompletedClearsPendingPrompt() throws {
        _ = try makeSessionDirectory()
        try writeHealth(snapshot(state: "recording"))
        let scanner = makeScanner()
        XCTAssertNotNil(scanner.scan())

        try scanner.markCompleted(sessionID: sessionID, nowMs: 10_000)

        XCTAssertNil(scanner.scan())
        let data = try Data(contentsOf: healthURL)
        let health = try JSONDecoder().decode(
            RecordingHealthSnapshot.self,
            from: data
        )
        XCTAssertEqual(health.state, "completed")
        XCTAssertEqual(health.endedAtMs, 10_000)
        XCTAssertGreaterThan(health.stateVersion, 9)
    }

    func testMarkCompletedRejectsAnotherSession() throws {
        _ = try makeSessionDirectory()
        try writeHealth(snapshot(state: "recording"))

        XCTAssertThrowsError(
            try makeScanner().markCompleted(
                sessionID: UUID(),
                nowMs: 10_000
            )
        ) { error in
            XCTAssertEqual(
                error as? InterruptedSessionScannerError,
                .sessionMismatch
            )
        }
    }

    func testRecoveryGapUsesLastAudioBuffer() {
        let info = InterruptedSessionInfo(
            sessionID: sessionID,
            sessionStartedAtMs: 1_000,
            lastAudioBufferAtMs: 2_000,
            lastHeartbeatAtMs: 9_000,
            lastStateVersion: 1,
            totalGapMs: 0,
            interruptionCount: 0,
            nextSequence: 1,
            sealedChunkCount: 0,
            totalBytes: 0
        )

        XCTAssertEqual(info.recoveryGapMs(nowMs: 12_000), 10_000)
    }
}
