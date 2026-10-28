import AkaMemoCore
import XCTest

@testable import AkaMemoWatch

private final class FakeBatteryTransport: BatteryEventTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BatteryEvent] = []

    var events: [BatteryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func sendBatteryEvent(_ event: BatteryEvent) -> Bool {
        lock.lock()
        storage.append(event)
        lock.unlock()
        return true
    }
}

final class WatchBatteryMonitorTests: XCTestCase {
    private let sessionID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFivePercentAlertsOnceAndThreePercentStops() async {
        let transport = FakeBatteryTransport()
        let monitor = WatchBatteryMonitor(transport: transport)

        let normal = await monitor.evaluate(
            level: 0.15,
            batteryState: .unplugged,
            sessionID: sessionID,
            stateVersion: 1,
            recordingState: "recording",
            now: now
        )
        XCTAssertEqual(normal.band, .advisory)
        XCTAssertFalse(normal.shouldStopRecording)

        let critical = await monitor.evaluate(
            level: 0.05,
            batteryState: .unplugged,
            sessionID: sessionID,
            stateVersion: 2,
            recordingState: "recording",
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(critical.band, .critical)
        XCTAssertTrue(critical.shouldPlayAlertHaptic)
        XCTAssertFalse(critical.shouldStopRecording)
        XCTAssertEqual(
            transport.events.filter { $0.kind == .alert5 }.count,
            1
        )

        let repeated = await monitor.evaluate(
            level: 0.04,
            batteryState: .unplugged,
            sessionID: sessionID,
            stateVersion: 3,
            recordingState: "recording",
            now: now.addingTimeInterval(120)
        )
        XCTAssertFalse(repeated.shouldStopRecording)
        XCTAssertEqual(
            transport.events.filter { $0.kind == .alert5 }.count,
            1
        )

        let shutdown = await monitor.evaluate(
            level: 0.03,
            batteryState: .unplugged,
            sessionID: sessionID,
            stateVersion: 4,
            recordingState: "recording",
            now: now.addingTimeInterval(180)
        )
        XCTAssertTrue(shutdown.shouldStopRecording)
        XCTAssertTrue(shutdown.shouldPlayAlertHaptic)
        XCTAssertEqual(
            transport.events.filter { $0.kind == .alert3 }.count,
            1
        )
    }

    func testChargingAboveTenPercentResetsAlert() async {
        let transport = FakeBatteryTransport()
        let monitor = WatchBatteryMonitor(transport: transport)
        _ = await monitor.evaluate(
            level: 0.05,
            batteryState: .unplugged,
            sessionID: sessionID,
            stateVersion: 1,
            recordingState: "recording",
            now: now
        )
        _ = await monitor.evaluate(
            level: 0.15,
            batteryState: .charging,
            sessionID: sessionID,
            stateVersion: 2,
            recordingState: "recording",
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(
            transport.events.filter { $0.kind == .reset }.count,
            1
        )

        _ = await monitor.evaluate(
            level: 0.05,
            batteryState: .unplugged,
            sessionID: sessionID,
            stateVersion: 3,
            recordingState: "recording",
            now: now.addingTimeInterval(120)
        )
        XCTAssertEqual(
            transport.events.filter { $0.kind == .alert5 }.count,
            2
        )
    }
}
