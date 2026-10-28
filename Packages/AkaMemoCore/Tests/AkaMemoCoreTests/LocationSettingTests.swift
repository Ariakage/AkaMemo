import XCTest

@testable import AkaMemoCore

final class LocationSettingTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let setting = LocationSetting(enabled: false, updatedAtMs: 1_700_000_000_000)

        let decoded = try LocationSetting.decode(
            fromJSON: try setting.jsonString()
        )

        XCTAssertEqual(decoded, setting)
    }

    func testNewerComparison() {
        let older = LocationSetting(enabled: true, updatedAtMs: 10)
        let newer = LocationSetting(enabled: false, updatedAtMs: 11)

        XCTAssertTrue(newer.isNewer(than: older))
        XCTAssertFalse(older.isNewer(than: newer))
        XCTAssertFalse(older.isNewer(than: older))
        XCTAssertTrue(older.isNewer(than: nil))
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(
            try LocationSetting.decode(fromJSON: "not json")
        )
    }

    func testHealthEventWithoutLocationFieldsStillDecodes() throws {
        let event = RecordingHealthEvent(
            sessionID: UUID(),
            stateVersion: 1,
            state: "recording",
            recordingStartedAtMs: 1_000,
            recordedAtMs: 2_000,
            lastAudioBufferAtMs: 2_000,
            chunkSequence: 0,
            bytesWritten: 100,
            batteryLevel: 0.5,
            storageAvailableBytes: 2_000_000_000,
            audioSessionActive: true
        )

        let decoded = try RecordingHealthEvent.decode(
            fromJSON: try event.jsonString()
        )

        XCTAssertEqual(decoded, event)
        XCTAssertNil(decoded.locationEnabled)
        XCTAssertNil(decoded.locationAuthorization)
        XCTAssertNil(decoded.locationTrackBytes)
        XCTAssertNil(decoded.locationSettingUpdatedAtMs)
    }

    func testHealthEventCarriesLocationStatus() throws {
        let event = RecordingHealthEvent(
            sessionID: UUID(),
            stateVersion: 1,
            state: "recording",
            recordingStartedAtMs: 1_000,
            recordedAtMs: 2_000,
            lastAudioBufferAtMs: 2_000,
            chunkSequence: 0,
            bytesWritten: 100,
            batteryLevel: 0.5,
            storageAvailableBytes: 2_000_000_000,
            audioSessionActive: true,
            locationEnabled: true,
            locationAuthorization: "authorized",
            locationTrackBytes: 4_096,
            locationSettingUpdatedAtMs: 1_500
        )

        let decoded = try RecordingHealthEvent.decode(
            fromJSON: try event.jsonString()
        )

        XCTAssertEqual(decoded.locationEnabled, true)
        XCTAssertEqual(decoded.locationAuthorization, "authorized")
        XCTAssertEqual(decoded.locationTrackBytes, 4_096)
        XCTAssertEqual(decoded.locationSettingUpdatedAtMs, 1_500)
    }
}
