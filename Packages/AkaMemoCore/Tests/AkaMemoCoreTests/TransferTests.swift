import XCTest

@testable import AkaMemoCore

final class ChunkTransferEnvelopeTests: XCTestCase {
    private func makeEnvelope(sequence: Int = 0) -> ChunkTransferEnvelope {
        ChunkTransferEnvelope(
            chunkID: UUID(),
            sessionID: UUID(),
            sessionStartedAtMs: 1_700_000_000_000,
            sequence: sequence,
            startedAtMs: 1_700_000_000_000,
            durationMs: 60_000,
            byteSize: 1_440_000,
            checksumSHA256: String(repeating: "a", count: 64),
            formatVersion: 1,
            sampleRate: 44_100,
            channels: 2,
            bitRate: 96_000,
            relativePath: "audio/session/0000-1700000000000.m4a"
        )
    }

    func testJSONRoundTrip() throws {
        let envelope = makeEnvelope()
        let json = try envelope.jsonString()
        let decoded = try ChunkTransferEnvelope.decode(fromJSON: json)
        XCTAssertEqual(decoded, envelope)
    }

    func testDecodeRejectsInvalidJSON() {
        XCTAssertThrowsError(try ChunkTransferEnvelope.decode(fromJSON: "not-json"))
    }
}

final class TransferRetryPolicyTests: XCTestCase {
    func testDelaysFollowDocumentedBackoff() {
        XCTAssertEqual(TransferRetryPolicy.delay(forAttempt: 0), 5)
        XCTAssertEqual(TransferRetryPolicy.delay(forAttempt: 1), 5)
        XCTAssertEqual(TransferRetryPolicy.delay(forAttempt: 2), 30)
        XCTAssertEqual(TransferRetryPolicy.delay(forAttempt: 3), 120)
        XCTAssertEqual(TransferRetryPolicy.delay(forAttempt: 4), 600)
        XCTAssertEqual(TransferRetryPolicy.delay(forAttempt: 5), 3_600)
        XCTAssertEqual(TransferRetryPolicy.delay(forAttempt: 99), 3_600)
    }

    func testNextAttemptUsesMilliseconds() {
        XCTAssertEqual(
            TransferRetryPolicy.nextAttemptAtMs(attempt: 1, nowMs: 1_000),
            6_000
        )
        XCTAssertEqual(
            TransferRetryPolicy.nextAttemptAtMs(attempt: 2, nowMs: 1_000),
            31_000
        )
    }

    func testAcknowledgementDeadline() {
        XCTAssertEqual(
            TransferRetryPolicy.acknowledgementDeadlineMs(nowMs: 1_000),
            601_000
        )
    }
}

final class ChunkTransferQueueDocumentTests: XCTestCase {
    private func makeEntry(sequence: Int) -> ChunkTransferQueueEntry {
        ChunkTransferQueueEntry(
            envelope: ChunkTransferEnvelope(
                chunkID: UUID(),
                sessionID: UUID(),
                sessionStartedAtMs: 1_000,
                sequence: sequence,
                startedAtMs: Int64(1_000 + sequence * 60_000),
                durationMs: 60_000,
                byteSize: 1_000,
                checksumSHA256: "abc",
                formatVersion: 1,
                sampleRate: 44_100,
                channels: 2,
                bitRate: 96_000,
                relativePath: "audio/session/\(sequence).m4a"
            ),
            state: .queued,
            attemptCount: 0,
            nextAttemptAtMs: 0,
            updatedAtMs: 0
        )
    }

    func testUpsertSortsAndReplaces() {
        let entry0 = makeEntry(sequence: 0)
        let entry1 = makeEntry(sequence: 1)
        let entry2 = makeEntry(sequence: 2)
        var document = ChunkTransferQueueDocument()
        document.upsert(entry2)
        document.upsert(entry0)
        document.upsert(entry1)
        XCTAssertEqual(document.entries.map(\.envelope.sequence), [0, 1, 2])

        var replacement = entry1
        replacement.state = .confirmed
        document.upsert(replacement)
        XCTAssertEqual(document.entries.count, 3)
        XCTAssertEqual(document.entries[1].state, .confirmed)
    }

    func testEntryLookupByChunkID() {
        var document = ChunkTransferQueueDocument()
        let entry = makeEntry(sequence: 0)
        document.upsert(entry)
        XCTAssertEqual(document.entry(chunkID: entry.envelope.chunkID), entry)
        XCTAssertNil(document.entry(chunkID: UUID()))
    }
}
