import XCTest

@testable import AkaMemoCore

final class SessionAggregatorTests: XCTestCase {
    private func makeChunk(
        sessionID: UUID,
        chunkID: UUID = UUID(),
        sessionStartedAtMs: Int64,
        sequence: Int,
        startedAtMs: Int64? = nil,
        durationMs: Int = 60_000,
        byteSize: Int = 1_000
    ) -> ChunkSummary {
        ChunkSummary(
            chunkID: chunkID,
            sessionID: sessionID,
            sessionStartedAtMs: sessionStartedAtMs,
            sequence: sequence,
            startedAtMs: startedAtMs ?? sessionStartedAtMs + Int64(sequence) * 60_000,
            durationMs: durationMs,
            byteSize: byteSize,
            relativePath: "audio/session/\(sequence).m4a"
        )
    }

    func testEmptyInputProducesNoSessions() {
        XCTAssertEqual(SessionAggregator.group([]), [])
    }

    func testGroupsChunksAndComputesTotals() {
        let older = UUID()
        let newer = UUID()
        let chunks = [
            makeChunk(
                sessionID: older,
                sessionStartedAtMs: 1_000,
                sequence: 1,
                durationMs: 30_000,
                byteSize: 2_000
            ),
            makeChunk(
                sessionID: older,
                sessionStartedAtMs: 1_000,
                sequence: 0,
                durationMs: 60_000,
                byteSize: 1_000
            ),
            makeChunk(
                sessionID: newer,
                sessionStartedAtMs: 2_000,
                sequence: 0
            ),
        ]

        let sessions = SessionAggregator.group(chunks)

        XCTAssertEqual(sessions.map(\.sessionID), [newer, older])
        let olderSession = sessions[1]
        XCTAssertEqual(olderSession.chunks.map(\.sequence), [0, 1])
        XCTAssertEqual(olderSession.chunkCount, 2)
        XCTAssertEqual(olderSession.totalBytes, 3_000)
        XCTAssertEqual(olderSession.totalDurationMs, 90_000)
        XCTAssertEqual(olderSession.startedAtMs, 1_000)
    }

    func testDuplicateChunkIDIsCountedOnce() {
        let sessionID = UUID()
        let chunkID = UUID()
        let chunk = makeChunk(
            sessionID: sessionID,
            chunkID: chunkID,
            sessionStartedAtMs: 1_000,
            sequence: 0
        )

        let sessions = SessionAggregator.group([chunk, chunk])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.chunkCount, 1)
        XCTAssertEqual(sessions.first?.totalBytes, 1_000)
    }

    func testChunksAreOrderedBySequenceNotArrival() {
        let sessionID = UUID()
        let chunks = [
            makeChunk(sessionID: sessionID, sessionStartedAtMs: 1_000, sequence: 2),
            makeChunk(sessionID: sessionID, sessionStartedAtMs: 1_000, sequence: 0),
            makeChunk(sessionID: sessionID, sessionStartedAtMs: 1_000, sequence: 1),
        ]

        let session = SessionAggregator.group(chunks).first

        XCTAssertEqual(session?.chunks.map(\.sequence), [0, 1, 2])
    }

    func testSessionStartUsesEarliestChunkTimestamp() {
        let sessionID = UUID()
        let chunks = [
            makeChunk(
                sessionID: sessionID,
                sessionStartedAtMs: 2_000,
                sequence: 0,
                startedAtMs: 2_000
            ),
            makeChunk(
                sessionID: sessionID,
                sessionStartedAtMs: 1_000,
                sequence: 1,
                startedAtMs: 3_000
            ),
        ]

        let session = SessionAggregator.group(chunks).first

        XCTAssertEqual(session?.startedAtMs, 1_000)
    }
}
