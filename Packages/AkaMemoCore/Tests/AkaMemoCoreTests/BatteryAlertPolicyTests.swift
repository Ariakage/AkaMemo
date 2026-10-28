import XCTest

@testable import AkaMemoCore

final class BatteryAlertPolicyTests: XCTestCase {
    private let policy = BatteryPolicy.standard

    func testBandsFollowDocumentedThresholds() {
        XCTAssertEqual(policy.band(for: 1.0), .normal)
        XCTAssertEqual(policy.band(for: 0.21), .normal)
        XCTAssertEqual(policy.band(for: 0.20), .advisory)
        XCTAssertEqual(policy.band(for: 0.11), .advisory)
        XCTAssertEqual(policy.band(for: 0.10), .low)
        XCTAssertEqual(policy.band(for: 0.06), .low)
        XCTAssertEqual(policy.band(for: 0.05), .critical)
        XCTAssertEqual(policy.band(for: 0.04), .critical)
        XCTAssertEqual(policy.band(for: 0.03), .shutdown)
        XCTAssertEqual(policy.band(for: 0.0), .shutdown)
    }

    func testInvalidLevelsAreIgnored() {
        XCTAssertNil(policy.band(for: -0.1))
        XCTAssertNil(policy.band(for: 1.1))
        XCTAssertNil(policy.band(for: .nan))

        var state = BatteryAlertState()
        XCTAssertEqual(state.update(level: 1.5, nowMs: 1_000), .none)
        XCTAssertNil(state.lastKnownLevel)
    }

    func testFivePercentAlertIsSentOnlyOnce() {
        var state = BatteryAlertState()
        XCTAssertEqual(state.update(level: 0.50, nowMs: 1_000), .none)
        XCTAssertEqual(state.update(level: 0.05, nowMs: 2_000), .sendLowBatteryAlert)
        XCTAssertEqual(state.lowBatteryAlertSentAtMs, 2_000)
        XCTAssertEqual(state.update(level: 0.049, nowMs: 3_000), .none)
        XCTAssertEqual(state.update(level: 0.041, nowMs: 4_000), .none)
    }

    func testThreePercentStopsOnceAndRecordsReason() {
        var state = BatteryAlertState()
        _ = state.update(level: 0.05, nowMs: 2_000)

        XCTAssertEqual(state.update(level: 0.03, nowMs: 3_000), .safeStop)
        XCTAssertEqual(state.autoPauseReason, BatteryAlertState.lowBatteryStopReason)
        XCTAssertEqual(state.update(level: 0.02, nowMs: 4_000), .none)
        XCTAssertEqual(state.autoPauseReason, BatteryAlertState.lowBatteryStopReason)
    }

    func testChargingAboveTenPercentClearsAlertLatch() {
        var state = BatteryAlertState()
        _ = state.update(level: 0.05, nowMs: 2_000)

        XCTAssertEqual(state.update(level: 0.11, nowMs: 3_000), .clearAlert)
        XCTAssertNil(state.lowBatteryAlertSentAtMs)
        XCTAssertEqual(state.update(level: 0.05, nowMs: 4_000), .sendLowBatteryAlert)
    }

    func testClearingAlertDoesNotResumeAfterSafeStop() {
        var state = BatteryAlertState()
        _ = state.update(level: 0.05, nowMs: 1_000)
        _ = state.update(level: 0.03, nowMs: 2_000)

        XCTAssertEqual(state.update(level: 0.50, nowMs: 3_000), .clearAlert)
        XCTAssertEqual(state.autoPauseReason, BatteryAlertState.lowBatteryStopReason)
    }

    func testAlertStateRoundTripsThroughCodable() throws {
        var state = BatteryAlertState()
        _ = state.update(level: 0.05, nowMs: 2_000)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BatteryAlertState.self, from: data)
        XCTAssertEqual(decoded, state)
    }
}
