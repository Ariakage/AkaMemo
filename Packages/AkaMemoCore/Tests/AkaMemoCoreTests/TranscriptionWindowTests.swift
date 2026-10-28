import XCTest

@testable import AkaMemoCore

final class TranscriptionWindowTests: XCTestCase {
    func testPlanReturnsSingleWindowWhenWithinLimit() {
        let windows = TranscriptionWindowPlanner.plan(
            durationMs: 12_000,
            maxWindowMs: 50_000
        )

        XCTAssertEqual(
            windows,
            [TranscriptionWindow(offsetMs: 0, durationMs: 12_000)]
        )
    }

    func testPlanSplitsLongChunkIntoConsecutiveWindows() {
        let windows = TranscriptionWindowPlanner.plan(
            durationMs: 120_000,
            maxWindowMs: 50_000
        )

        XCTAssertEqual(
            windows,
            [
                TranscriptionWindow(offsetMs: 0, durationMs: 50_000),
                TranscriptionWindow(offsetMs: 50_000, durationMs: 50_000),
                TranscriptionWindow(offsetMs: 100_000, durationMs: 20_000),
            ]
        )
        XCTAssertEqual(windows.last?.endMs, 120_000)
    }

    func testPlanHandlesExactMultipleAndTinyRemainder() {
        let exact = TranscriptionWindowPlanner.plan(
            durationMs: 100_000,
            maxWindowMs: 50_000
        )
        let remainder = TranscriptionWindowPlanner.plan(
            durationMs: 100_500,
            maxWindowMs: 50_000
        )

        XCTAssertEqual(exact.count, 2)
        XCTAssertEqual(remainder.count, 3)
        XCTAssertEqual(remainder.last?.durationMs, 500)
        XCTAssertEqual(remainder.last?.endMs, 100_500)
    }

    func testPlanRejectsNonPositiveInput() {
        XCTAssertTrue(
            TranscriptionWindowPlanner.plan(durationMs: 0, maxWindowMs: 50_000)
                .isEmpty
        )
        XCTAssertTrue(
            TranscriptionWindowPlanner.plan(durationMs: 10_000, maxWindowMs: 0)
                .isEmpty
        )
    }

    func testAbsoluteTimestampUsesChunkStartAndWindowOffset() {
        let start = TranscriptionWindowPlanner.absoluteStartMs(
            chunkStartedAtMs: 1_700_000_000_000,
            windowOffsetMs: 50_000,
            segmentOffsetMs: 1_250
        )

        XCTAssertEqual(start, 1_700_000_051_250)
    }
}
