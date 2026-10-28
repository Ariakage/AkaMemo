import XCTest

@testable import AkaMemoCore

final class BatteryEventTests: XCTestCase {
    func testEventRoundTripsAndExpires() throws {
        let event = BatteryEvent(
            kind: .alert5,
            sessionID: UUID(),
            stateVersion: 7,
            batteryLevel: 0.05,
            batteryState: .unplugged,
            recordingState: "recording",
            alertLevel: 5,
            recordedAtMs: 1_700_000_000_000,
            ttlMs: 300_000
        )

        let decoded = try BatteryEvent.decode(
            fromJSON: try event.jsonString()
        )
        XCTAssertEqual(decoded, event)
        XCTAssertFalse(decoded.isExpired(nowMs: 1_700_000_200_000))
        XCTAssertTrue(decoded.isExpired(nowMs: 1_700_000_400_000))
        XCTAssertFalse(decoded.isCharging)
        XCTAssertTrue(
            BatteryEvent(
                kind: .snapshot,
                sessionID: nil,
                stateVersion: 1,
                batteryLevel: 0.5,
                batteryState: .charging,
                recordingState: "recording",
                recordedAtMs: 1,
                ttlMs: 1
            ).isCharging
        )
    }
}
