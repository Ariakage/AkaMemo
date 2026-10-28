import AkaMemoCore
import XCTest

@testable import AkaMemoWatch

final class AkaMemoWatchTests: XCTestCase {
    func testWatchTargetLoads() {
        XCTAssertTrue(true)
    }

    func testWatchHealthSnapshotRoundTrips() throws {
        let snapshot = WatchHealthSnapshot(
            sessionID: UUID(),
            sessionStartedAtMs: 1_000,
            endedAtMs: nil,
            lastAudioBufferAtMs: 2_000,
            lastHeartbeatAtMs: 3_000,
            chunkSequence: 4,
            bytesWritten: 5_000,
            audioSessionActive: true,
            batteryLevel: 0.42,
            state: "recording",
            stateVersion: 6,
            totalGapMs: 7,
            interruptionCount: 1
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }

    @MainActor
    func testRecordingSettingsDefaultOnAndPersist() {
        let suite = "akamemo.watch.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = WatchRecordingSettings(defaults: defaults)
        XCTAssertTrue(settings.autoResume)
        XCTAssertTrue(settings.silentResume)

        settings.setAutoResume(false)
        settings.setSilentResume(false)

        let reloaded = WatchRecordingSettings(defaults: defaults)
        XCTAssertFalse(reloaded.autoResume)
        XCTAssertFalse(reloaded.silentResume)
    }

    @MainActor
    func testResumeSettingsUseNewestTimestamp() {
        let suite = "akamemo.watch.resume.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WatchRecordingSettings(defaults: defaults)

        XCTAssertTrue(
            settings.apply(
                ResumeSettingsCommand(
                    autoResume: false,
                    silentResume: false,
                    updatedAtMs: 50
                )
            )
        )
        XCTAssertFalse(settings.autoResume)
        XCTAssertFalse(
            settings.apply(
                ResumeSettingsCommand(
                    autoResume: true,
                    silentResume: true,
                    updatedAtMs: 40
                )
            )
        )
        XCTAssertFalse(settings.autoResume)

        settings.setSilentResume(true)
        XCTAssertTrue(settings.silentResume)
        XCTAssertGreaterThan(settings.updatedAtMs, 50)

        let reloaded = WatchRecordingSettings(defaults: defaults)
        XCTAssertFalse(reloaded.autoResume)
        XCTAssertTrue(reloaded.silentResume)
    }
}
