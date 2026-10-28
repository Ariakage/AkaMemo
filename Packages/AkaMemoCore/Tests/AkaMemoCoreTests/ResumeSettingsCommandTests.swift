import XCTest

@testable import AkaMemoCore

final class ResumeSettingsCommandTests: XCTestCase {
    func testRoundTripsAndComparesTimestamps() throws {
        let older = ResumeSettingsCommand(
            autoResume: true,
            silentResume: true,
            updatedAtMs: 10
        )
        let newer = ResumeSettingsCommand(
            autoResume: false,
            silentResume: false,
            updatedAtMs: 11
        )

        let decoded = try ResumeSettingsCommand.decode(
            fromJSON: try newer.jsonString()
        )

        XCTAssertEqual(decoded, newer)
        XCTAssertTrue(newer.isNewer(than: older))
        XCTAssertFalse(older.isNewer(than: newer))
        XCTAssertFalse(older.isNewer(than: older))
        XCTAssertTrue(older.isNewer(than: nil))
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(
            try ResumeSettingsCommand.decode(fromJSON: "nope")
        )
    }
}
