import AkaMemoCore
import XCTest

@testable import AkaMemo

private actor FakeRecordingNotifier: RecordingNotificationPosting {
    private var interruptedCount = 0
    private var scheduledSessions: [UUID] = []
    private var cancelledSessions: [UUID] = []
    private var cancelAllCount = 0

    func interrupted() -> Int { interruptedCount }
    func scheduled() -> [UUID] { scheduledSessions }
    func cancelled() -> [UUID] { cancelledSessions }
    func cancelAllInvocations() -> Int { cancelAllCount }

    func postInterrupted() async {
        interruptedCount += 1
    }

    func scheduleDeadMan(sessionID: UUID, after: TimeInterval) async {
        scheduledSessions.append(sessionID)
    }

    func cancelDeadMan(sessionID: UUID) async {
        cancelledSessions.append(sessionID)
    }

    func cancelAllDeadMan() async {
        cancelAllCount += 1
    }
}

@MainActor
final class RecordingWatchdogTests: XCTestCase {
    private let sessionID = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeWatchdog() -> (RecordingWatchdog, FakeRecordingNotifier) {
        let notifier = FakeRecordingNotifier()
        return (RecordingWatchdog(notifier: notifier), notifier)
    }

    private func event(
        state: String,
        at date: Date,
        version: Int64,
        storage: Int64? = 2_000_000_000
    ) -> RecordingHealthEvent {
        RecordingHealthEvent(
            sessionID: sessionID,
            stateVersion: version,
            state: state,
            recordingStartedAtMs: TimeMath.epochMs(start),
            recordedAtMs: TimeMath.epochMs(date),
            lastAudioBufferAtMs: TimeMath.epochMs(date),
            chunkSequence: 1,
            bytesWritten: 100,
            batteryLevel: 0.5,
            storageAvailableBytes: storage,
            audioSessionActive: state == "recording"
        )
    }

    func testRecordingSchedulesDeadMan() async {
        let (watchdog, notifier) = makeWatchdog()
        await watchdog.handle(
            event(state: "recording", at: start, version: 1)
        )

        let scheduled = await notifier.scheduled()
        XCTAssertEqual(scheduled, [sessionID])
        XCTAssertNil(watchdog.banner)
        await watchdog.clear()
    }

    func testStaleHeartbeatNotifiesOnce() async {
        let (watchdog, notifier) = makeWatchdog()
        await watchdog.handle(
            event(state: "recording", at: start, version: 1)
        )
        await watchdog.evaluate(
            now: start.addingTimeInterval(46)
        )
        await watchdog.evaluate(
            now: start.addingTimeInterval(50)
        )

        let count = await notifier.interrupted()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(watchdog.banner?.kind, .stale)
        await watchdog.clear()
    }

    func testStopCancelsDeadManAndStopsEvaluation() async {
        let (watchdog, notifier) = makeWatchdog()
        await watchdog.handle(
            event(state: "recording", at: start, version: 1)
        )
        await watchdog.handle(
            event(
                state: "idle",
                at: start.addingTimeInterval(1),
                version: 2
            )
        )
        await watchdog.evaluate(
            now: start.addingTimeInterval(46)
        )

        let cancelled = await notifier.cancelled()
        let interrupted = await notifier.interrupted()
        XCTAssertEqual(cancelled, [sessionID])
        XCTAssertEqual(interrupted, 0)
        XCTAssertNil(watchdog.banner)
        await watchdog.clear()
    }

    func testInterruptedEventNotifiesAndShowsBanner() async {
        let (watchdog, notifier) = makeWatchdog()
        await watchdog.handle(
            event(state: "interrupted", at: start, version: 2)
        )

        let count = await notifier.interrupted()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(watchdog.banner?.kind, .interrupted)
        await watchdog.clear()
    }

    func testStorageCriticalShowsBanner() async {
        let (watchdog, _) = makeWatchdog()
        await watchdog.handle(
            event(
                state: "idle",
                at: start,
                version: 1,
                storage: 400_000_000
            )
        )

        XCTAssertEqual(watchdog.banner?.kind, .storage)
        await watchdog.clear()
    }

    func testOlderStateVersionIsIgnored() async {
        let (watchdog, notifier) = makeWatchdog()
        await watchdog.handle(
            event(state: "recording", at: start, version: 2)
        )
        await watchdog.handle(
            event(
                state: "idle",
                at: start.addingTimeInterval(1),
                version: 1
            )
        )
        await watchdog.evaluate(
            now: start.addingTimeInterval(46)
        )

        let interrupted = await notifier.interrupted()
        XCTAssertEqual(interrupted, 1)
        await watchdog.clear()
    }

    func testClearCancelsAllPendingNotifications() async {
        let (watchdog, notifier) = makeWatchdog()
        await watchdog.handle(
            event(state: "recording", at: start, version: 1)
        )
        await watchdog.clear()

        let count = await notifier.cancelAllInvocations()
        XCTAssertEqual(count, 1)
        XCTAssertNil(watchdog.banner)
    }
}
