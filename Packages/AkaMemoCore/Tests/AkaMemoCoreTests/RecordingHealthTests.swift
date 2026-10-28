import XCTest

@testable import AkaMemoCore

final class RecordingHealthTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let evaluator = RecordingHealthEvaluator.standard

    private func status(
        at offset: TimeInterval,
        lastBufferOffset: TimeInterval? = nil
    ) -> RecordingHealthStatus {
        let lastBuffer = lastBufferOffset.map { start.addingTimeInterval($0) }
        return evaluator.status(
            now: start.addingTimeInterval(offset),
            lastAudioBufferAt: lastBuffer,
            sessionStartedAt: start
        )
    }

    func testNoBufferIsHealthyForTheFirstTenSeconds() {
        XCTAssertEqual(status(at: 0), .healthy)
        XCTAssertEqual(status(at: 9.999), .healthy)
    }

    func testNoBufferStartsRecoveryAtTenSeconds() {
        XCTAssertEqual(status(at: 10), .recovering)
        XCTAssertEqual(status(at: 29.999), .recovering)
    }

    func testNoBufferBecomesInterruptedAtThirtySeconds() {
        XCTAssertEqual(status(at: 30), .interrupted)
        XCTAssertEqual(status(at: 120), .interrupted)
    }

    func testBufferTimestampResetsTheWatchdog() {
        XCTAssertEqual(status(at: 30, lastBufferOffset: 25), .healthy)
        XCTAssertEqual(status(at: 36, lastBufferOffset: 25), .recovering)
        XCTAssertEqual(status(at: 56, lastBufferOffset: 25), .interrupted)
    }

    func testClockSkewIsHealthy() {
        XCTAssertEqual(status(at: 5, lastBufferOffset: 10), .healthy)
    }

    func testGapMillisecondsUsesLastBuffer() {
        let buffer = start.addingTimeInterval(10)
        let resumed = start.addingTimeInterval(12.5)
        XCTAssertEqual(evaluator.gapMilliseconds(from: buffer, to: resumed), 2_500)
        XCTAssertEqual(evaluator.gapMilliseconds(from: nil, to: resumed), 0)
        XCTAssertEqual(evaluator.gapMilliseconds(from: resumed, to: buffer), 0)
    }
}

final class RecordingRecoveryScheduleTests: XCTestCase {
    func testDelaysFollowOneFiveFifteenSeconds() {
        XCTAssertEqual(
            RecordingRecoverySchedule.decision(completedAttempts: 0), .retry(after: 1, attempt: 1))
        XCTAssertEqual(
            RecordingRecoverySchedule.decision(completedAttempts: 1), .retry(after: 5, attempt: 2))
        XCTAssertEqual(
            RecordingRecoverySchedule.decision(completedAttempts: 2), .retry(after: 15, attempt: 3))
    }

    func testGivesUpAfterThreeAttempts() {
        XCTAssertEqual(RecordingRecoverySchedule.decision(completedAttempts: 3), .giveUp)
        XCTAssertEqual(RecordingRecoverySchedule.decision(completedAttempts: 10), .giveUp)
    }

    func testNegativeAttemptsAreTreatedAsFirstAttempt() {
        XCTAssertEqual(
            RecordingRecoverySchedule.decision(completedAttempts: -1), .retry(after: 1, attempt: 1))
    }

    func testEmptyScheduleGivesUp() {
        XCTAssertEqual(
            RecordingRecoverySchedule.decision(completedAttempts: 0, delays: []),
            .giveUp
        )
    }
}
