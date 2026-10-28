import AkaMemoCore
import XCTest

@testable import AkaMemo

private actor FakeBatteryNotifier: BatteryNotificationPosting {
    private var storedLevels: [Int] = []
    private var authorizationGranted = true

    func setAuthorizationGranted(_ granted: Bool) {
        authorizationGranted = granted
    }

    func levels() -> [Int] {
        storedLevels
    }

    func requestAuthorization() async -> Bool {
        authorizationGranted
    }

    func postBatteryAlert(level: Int) async {
        storedLevels.append(level)
    }
}

private actor FakeBatteryActivity: BatteryActivityControlling {
    private var storedStartLevels: [Double] = []
    private var storedEndCount = 0

    func startLevels() -> [Double] {
        storedStartLevels
    }

    func endCount() -> Int {
        storedEndCount
    }

    func startOrUpdate(
        sessionID: UUID,
        level: Double,
        batteryState: String,
        recordingState: String,
        now: Date
    ) async {
        storedStartLevels.append(level)
    }

    func end() async {
        storedEndCount += 1
    }
}

@MainActor
final class BatteryAlertCoordinatorTests: XCTestCase {
    private let sessionID = UUID()

    private func makeCoordinator() -> (
        BatteryAlertCoordinator, FakeBatteryNotifier, FakeBatteryActivity
    ) {
        let notifier = FakeBatteryNotifier()
        let activity = FakeBatteryActivity()
        let coordinator = BatteryAlertCoordinator(
            notifier: notifier,
            activity: activity
        )
        return (coordinator, notifier, activity)
    }

    private func event(
        kind: BatteryEventKind,
        level: Double,
        recordedAtMs: Int64,
        sessionID: UUID? = nil,
        batteryState: BatteryChargeState = .unplugged,
        recordingState: String = "recording"
    ) -> BatteryEvent {
        BatteryEvent(
            kind: kind,
            sessionID: sessionID ?? self.sessionID,
            stateVersion: Int64(recordedAtMs),
            batteryLevel: level,
            batteryState: batteryState,
            recordingState: recordingState,
            alertLevel: kind == .alert5 ? 5 : (kind == .alert3 ? 3 : nil),
            recordedAtMs: recordedAtMs,
            ttlMs: BatteryEvent.defaultAlertTTLMs
        )
    }

    func testFivePercentPostsOnceAndStartsActivityWhenForeground() async {
        let (coordinator, notifier, activity) = makeCoordinator()
        await coordinator.setForeground(true)
        let nowMs = TimeMath.epochMs(Date())
        let alert = event(kind: .alert5, level: 0.05, recordedAtMs: nowMs)

        await coordinator.handle(alert, now: Date())
        await coordinator.handle(alert, now: Date())

        let levels = await notifier.levels()
        XCTAssertEqual(levels, [5])
        let starts = await activity.startLevels()
        XCTAssertEqual(starts, [0.05])
        XCTAssertEqual(coordinator.banner?.kind, .low)
    }

    func testExpiredAlertIsIgnored() async {
        let (coordinator, notifier, _) = makeCoordinator()
        let now = Date()
        let old = event(
            kind: .alert5,
            level: 0.05,
            recordedAtMs: TimeMath.epochMs(now) - 600_000
        )

        await coordinator.handle(old, now: now)

        let levels = await notifier.levels()
        XCTAssertTrue(levels.isEmpty)
        XCTAssertNil(coordinator.banner)
    }

    func testChargingSnapshotClearsBannerAndEndsActivity() async {
        let (coordinator, _, activity) = makeCoordinator()
        await coordinator.setForeground(true)
        let now = Date()
        let nowMs = TimeMath.epochMs(now)
        await coordinator.handle(
            event(kind: .alert5, level: 0.05, recordedAtMs: nowMs),
            now: now
        )
        XCTAssertEqual(coordinator.banner?.kind, .low)

        await coordinator.handle(
            event(
                kind: .snapshot,
                level: 0.15,
                recordedAtMs: nowMs + 1_000,
                batteryState: .charging
            ),
            now: now.addingTimeInterval(1)
        )

        XCTAssertNil(coordinator.banner)
        let ends = await activity.endCount()
        XCTAssertGreaterThanOrEqual(ends, 1)
    }

    func testThreePercentPostsStopAndEndsActivity() async {
        let (coordinator, notifier, activity) = makeCoordinator()
        await coordinator.setForeground(true)
        let now = Date()
        let nowMs = TimeMath.epochMs(now)

        await coordinator.handle(
            event(kind: .alert3, level: 0.03, recordedAtMs: nowMs),
            now: now
        )

        let levels = await notifier.levels()
        XCTAssertEqual(levels, [3])
        XCTAssertEqual(coordinator.banner?.kind, .stopped)
        let ends = await activity.endCount()
        XCTAssertGreaterThanOrEqual(ends, 1)
    }

    func testThreePercentStillNotifiesAfterStoppedSnapshot() async {
        let (coordinator, notifier, _) = makeCoordinator()
        let now = Date()
        let nowMs = TimeMath.epochMs(now)

        await coordinator.handle(
            event(
                kind: .snapshot,
                level: 0.03,
                recordedAtMs: nowMs + 1_000,
                recordingState: "idle"
            ),
            now: now
        )
        await coordinator.handle(
            event(kind: .alert3, level: 0.03, recordedAtMs: nowMs),
            now: now
        )

        let levels = await notifier.levels()
        XCTAssertEqual(levels, [3])
    }

    func testNewerChargingSnapshotSuppressesLateAlert() async {
        let (coordinator, notifier, _) = makeCoordinator()
        let now = Date()
        let nowMs = TimeMath.epochMs(now)

        await coordinator.handle(
            event(
                kind: .snapshot,
                level: 0.20,
                recordedAtMs: nowMs + 5_000,
                batteryState: .charging
            ),
            now: now
        )
        await coordinator.handle(
            event(kind: .alert5, level: 0.05, recordedAtMs: nowMs),
            now: now
        )

        let levels = await notifier.levels()
        XCTAssertTrue(levels.isEmpty)
    }

    func testAuthorizationDeniedIsVisible() async {
        let (coordinator, notifier, _) = makeCoordinator()
        await notifier.setAuthorizationGranted(false)

        await coordinator.requestAuthorizationIfNeeded()

        XCTAssertTrue(coordinator.notificationsDenied)
    }
}
