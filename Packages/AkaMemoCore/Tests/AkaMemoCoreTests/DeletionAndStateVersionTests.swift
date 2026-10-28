import XCTest

@testable import AkaMemoCore

final class DataEpochPolicyTests: XCTestCase {
    func testSessionIsDeletedOnlyWhenStartIsBeforeEpoch() {
        let policy = DataEpochPolicy(epochMs: 2_000)
        XCTAssertTrue(policy.isDeleted(sessionStartedAtMs: 1_999))
        XCTAssertFalse(policy.isDeleted(sessionStartedAtMs: 2_000))
        XCTAssertFalse(policy.isDeleted(sessionStartedAtMs: 2_001))
    }

    func testSessionPolicyUsesStartedAt() {
        let session = RecordingSession(startedAt: TimeMath.date(epochMs: 1_000))
        let policy = DataEpochPolicy(epochMs: 2_000)
        XCTAssertTrue(policy.isDeleted(session: session))
    }

    func testChunkIsRejectedBySessionStartEvenAfterEpoch() {
        let chunk = AudioChunk(
            sessionID: UUID(),
            sessionStartedAt: TimeMath.date(epochMs: 1_000),
            sequence: 3,
            startedAt: TimeMath.date(epochMs: 5_000)
        )
        let policy = DataEpochPolicy(epochMs: 2_000)
        XCTAssertTrue(policy.shouldReject(chunk: chunk))
    }

    func testChunkFromANewSessionIsAccepted() {
        let chunk = AudioChunk(
            sessionID: UUID(),
            sessionStartedAt: TimeMath.date(epochMs: 3_000),
            sequence: 0,
            startedAt: TimeMath.date(epochMs: 3_100)
        )
        let policy = DataEpochPolicy(epochMs: 2_000)
        XCTAssertFalse(policy.shouldReject(chunk: chunk))
    }

    func testTimeMathRoundTripsMilliseconds() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let milliseconds = TimeMath.epochMs(date)
        XCTAssertEqual(milliseconds, 1_700_000_000_123)
        XCTAssertEqual(
            TimeMath.date(epochMs: milliseconds).timeIntervalSince1970,
            1_700_000_000.123,
            accuracy: 0.001
        )
    }
}

final class StateVersionTests: XCTestCase {
    func testNewSessionStartsAtOne() {
        XCTAssertEqual(StateVersion.initial, 1)
    }

    func testNextUsesTheLargerOfIncrementAndClock() {
        XCTAssertEqual(StateVersion.next(lastKnown: 1, nowMs: 5), 5)
        XCTAssertEqual(StateVersion.next(lastKnown: 10, nowMs: 5), 11)
    }

    func testRestartKeepsIncreasing() {
        XCTAssertEqual(StateVersion.next(lastKnown: 1_000, nowMs: 50), 1_001)
    }

    func testPersistenceLossJumpsToNow() {
        XCTAssertEqual(
            StateVersion.afterPersistenceLoss(nowMs: 1_700_000_000_000), 1_700_000_000_000)
        XCTAssertEqual(StateVersion.afterPersistenceLoss(nowMs: 0), 1)
    }

    func testMaxValueDoesNotOverflow() {
        XCTAssertEqual(StateVersion.next(lastKnown: Int64.max, nowMs: 5), Int64.max)
    }
}
