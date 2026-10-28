import XCTest

@testable import AkaMemoCore

final class DeletionCommandTests: XCTestCase {
    func testCommandRoundTripsThroughJSON() throws {
        let chunkID = UUID()
        let sessionID = UUID()
        let command = DeletionCommand(
            scope: .chunk,
            entityID: chunkID,
            sessionID: sessionID,
            deletedAtMs: 1_700_000_000_000
        )

        let decoded = try DeletionCommand.decode(
            fromJSON: try command.jsonString()
        )

        XCTAssertEqual(decoded, command)
        XCTAssertTrue(decoded.isValid)
    }

    func testValidationByScope() {
        XCTAssertFalse(
            DeletionCommand(scope: .chunk, deletedAtMs: 1).isValid
        )
        XCTAssertFalse(
            DeletionCommand(scope: .session, deletedAtMs: 1).isValid
        )
        XCTAssertFalse(
            DeletionCommand(scope: .all, deletedAtMs: 1).isValid
        )
        XCTAssertTrue(
            DeletionCommand(
                scope: .chunk,
                entityID: UUID(),
                deletedAtMs: 1
            ).isValid
        )
        XCTAssertTrue(
            DeletionCommand(
                scope: .session,
                entityID: UUID(),
                deletedAtMs: 1
            ).isValid
        )
        XCTAssertTrue(
            DeletionCommand(scope: .all, epochMs: 2, deletedAtMs: 1).isValid
        )
    }
}
