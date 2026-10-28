import XCTest

@testable import AkaMemoCore

final class DiagnosticsBatchTests: XCTestCase {
    private func entry(_ index: Int) -> LogEntry {
        LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
            level: .info,
            category: .recording,
            message: "watch event",
            metadata: ["state": "recording"],
            source: .watch
        )
    }

    func testRoundTripsThroughJSON() throws {
        let batch = DiagnosticsBatch(
            entries: [entry(0), entry(1)],
            sentAtMs: 1_800_000_100_000
        )

        let decoded = try DiagnosticsBatch.decode(
            fromJSON: try batch.jsonString()
        )

        XCTAssertEqual(decoded, batch)
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.entries.first?.source, .watch)
    }

    func testEmptyAndOversizedBatchesAreInvalid() {
        let empty = DiagnosticsBatch(entries: [], sentAtMs: 1)
        XCTAssertFalse(empty.isValid)

        let oversized = DiagnosticsBatch(
            entries: (0...DiagnosticsBatch.maximumEntryCount).map(entry),
            sentAtMs: 1
        )
        XCTAssertFalse(oversized.isValid)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(
            try DiagnosticsBatch.decode(fromJSON: "not json")
        )
    }
}
