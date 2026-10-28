import XCTest

@testable import AkaMemoCore

final class ChunkPolicyTests: XCTestCase {
    func testShouldSeal_whenDurationReached() {
        let policy = ChunkPolicy(duration: 60, maximumBytes: 2_000_000)
        XCTAssertFalse(policy.shouldSeal(elapsed: 59.999, byteCount: 0))
        XCTAssertTrue(policy.shouldSeal(elapsed: 60, byteCount: 0))
    }

    func testShouldSeal_whenByteLimitReached() {
        let policy = ChunkPolicy(duration: 60, maximumBytes: 2_000_000)
        XCTAssertFalse(policy.shouldSeal(elapsed: 0, byteCount: 1_999_999))
        XCTAssertTrue(policy.shouldSeal(elapsed: 0, byteCount: 2_000_000))
    }

    func testStandardPolicyMatchesRecordingDefaults() {
        XCTAssertEqual(ChunkPolicy.standard.duration, 60)
        XCTAssertEqual(ChunkPolicy.standard.maximumBytes, 2 * 1024 * 1024)
    }
}

final class ChunkPathTests: XCTestCase {
    func testFileNameUsesZeroPaddedSequenceAndEpochMilliseconds() {
        let name = ChunkPath.fileName(
            sequence: 7,
            startEpochMs: 1_700_000_000_000,
            kind: .audio
        )
        XCTAssertEqual(name, "0007-1700000000000.m4a")
    }

    func testFileNameSupportsPartAndCorruptSuffixes() {
        XCTAssertEqual(
            ChunkPath.fileName(
                sequence: 1,
                startEpochMs: 1_000,
                kind: .metadata,
                suffix: .part
            ),
            "0001-1000.json.part"
        )
        XCTAssertEqual(
            ChunkPath.fileName(
                sequence: 1,
                startEpochMs: 1_000,
                kind: .audio,
                suffix: .corrupt
            ),
            "0001-1000.m4a.corrupt"
        )
    }

    func testParseFileNameRoundTripsEveryKindAndSuffix() throws {
        for kind in ChunkFileKind.allCases {
            for suffix in [ChunkFileSuffix.final, .part, .corrupt] {
                let name = ChunkPath.fileName(
                    sequence: 42,
                    startEpochMs: 1_700_000_123_456,
                    kind: kind,
                    suffix: suffix
                )
                let parsed = try XCTUnwrap(ChunkPath.parseFileName(name))
                XCTAssertEqual(parsed.sequence, 42)
                XCTAssertEqual(parsed.startEpochMs, 1_700_000_123_456)
                XCTAssertEqual(parsed.kind, kind)
                XCTAssertEqual(parsed.suffix, suffix)
            }
        }
    }

    func testParseFileNameRejectsUserContentAndMalformedNames() {
        let invalidNames = [
            "meeting-with-alice.m4a",
            "0001.m4a",
            "-1-1000.m4a",
            "0001--1000.m4a",
            "0001-abc.m4a",
            "0001-0.m4a",
            "0001-1000.wav",
            "0001-1000.m4a.backup",
        ]
        for name in invalidNames {
            XCTAssertNil(ChunkPath.parseFileName(name), "expected \(name) to be rejected")
        }
    }

    func testSessionRelativePathContainsOnlyUUIDAndChunkName() throws {
        let sessionID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")
        )
        let path = ChunkPath.sessionRelativePath(
            sessionID: sessionID,
            sequence: 3,
            startEpochMs: 1_000,
            kind: .audio
        )
        XCTAssertEqual(
            path,
            "audio/00000000-0000-4000-8000-000000000001/0003-1000.m4a"
        )
    }
}

final class ChunkMetadataTests: XCTestCase {
    private func makeSnapshot(
        sequence: Int = 0,
        durationMs: Int = 60_000,
        byteSize: Int = 1_440_000,
        checksum: String = "abcd"
    ) -> ChunkMetadataSnapshot {
        ChunkMetadataSnapshot(
            chunkID: UUID(),
            sessionID: UUID(),
            sessionStartedAtMs: 1_000,
            sequence: sequence,
            startedAtMs: 1_000,
            durationMs: durationMs,
            byteSize: byteSize,
            checksumSHA256: checksum,
            relativePath: "audio/session/0000-1000.m4a",
            createdAtMs: 2_000
        )
    }

    func testValidMetadataHasNoIssues() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(
            snapshot.validationIssues(fileByteSize: 1_440_000, checksumSHA256: "abcd"),
            []
        )
    }

    func testChecksumComparisonIsCaseInsensitive() {
        let snapshot = makeSnapshot(checksum: "ABCD")
        XCTAssertEqual(
            snapshot.validationIssues(fileByteSize: 1_440_000, checksumSHA256: "abcd"),
            []
        )
    }

    func testMismatchesAndInvalidFieldsAreReported() {
        let snapshot = makeSnapshot(sequence: -1, durationMs: 0, checksum: "abcd")
        let issues = snapshot.validationIssues(fileByteSize: 1, checksumSHA256: "ffff")
        XCTAssertEqual(
            issues,
            [.invalidSequence, .nonPositiveDuration, .byteSizeMismatch, .checksumMismatch]
        )
    }
}
