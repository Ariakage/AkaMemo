import AkaMemoCore
import XCTest

@testable import AkaMemo

private final class FakeLocationSender: LocationSettingSending,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: [LocationSetting] = []

    var sentSettings: [LocationSetting] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func sendLocationSetting(_ setting: LocationSetting) -> Bool {
        lock.lock()
        stored.append(setting)
        lock.unlock()
        return true
    }
}

@MainActor
final class PhoneSettingsModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "akamemo.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func event(
        enabled: Bool,
        updatedAtMs: Int64,
        authorization: String = "authorized",
        trackBytes: Int64 = 1_024
    ) -> RecordingHealthEvent {
        RecordingHealthEvent(
            sessionID: UUID(),
            stateVersion: 1,
            state: "idle",
            recordingStartedAtMs: nil,
            recordedAtMs: updatedAtMs,
            lastAudioBufferAtMs: nil,
            chunkSequence: nil,
            bytesWritten: 0,
            batteryLevel: nil,
            storageAvailableBytes: nil,
            audioSessionActive: false,
            locationEnabled: enabled,
            locationAuthorization: authorization,
            locationTrackBytes: trackBytes,
            locationSettingUpdatedAtMs: updatedAtMs
        )
    }

    func testDefaultsToEnabled() {
        let model = PhoneSettingsModel(defaults: defaults)

        XCTAssertTrue(model.isLocationEnabled)
        XCTAssertNil(model.watchLocationEnabled)
        XCTAssertNil(model.watchAuthorization)
    }

    func testTogglePersistsAndSends() {
        let sender = FakeLocationSender()
        let model = PhoneSettingsModel(defaults: defaults)
        model.attach(sender: sender)

        model.setLocationEnabled(false)

        XCTAssertFalse(model.isLocationEnabled)
        XCTAssertEqual(sender.sentSettings.map(\.enabled), [false])
        let reloaded = PhoneSettingsModel(defaults: defaults)
        XCTAssertFalse(reloaded.isLocationEnabled)
    }

    func testNewerWatchSettingIsAdopted() {
        let sender = FakeLocationSender()
        let model = PhoneSettingsModel(defaults: defaults)
        model.attach(sender: sender)
        model.setLocationEnabled(false)

        model.handle(event(enabled: true, updatedAtMs: Int64.max))
        XCTAssertTrue(model.isLocationEnabled)
        XCTAssertEqual(model.watchLocationEnabled, true)
        XCTAssertEqual(model.watchAuthorization, "authorized")
        XCTAssertEqual(model.watchTrackBytes, 1_024)
    }

    func testOlderWatchSettingDoesNotOverrideLocalToggle() {
        let model = PhoneSettingsModel(defaults: defaults)
        model.handle(event(enabled: false, updatedAtMs: 9_000))
        XCTAssertFalse(model.isLocationEnabled)

        model.setLocationEnabled(true)
        model.handle(event(enabled: false, updatedAtMs: 1))

        XCTAssertTrue(model.isLocationEnabled)
    }
}
