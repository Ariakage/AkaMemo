import XCTest

@testable import AkaMemoCore

final class RecordingStorageAndHealthTests: XCTestCase {
    func testStorageBands() {
        let policy = RecordingStoragePolicy.standard

        XCTAssertEqual(policy.band(forAvailableBytes: nil), .unknown)
        XCTAssertEqual(
            policy.band(forAvailableBytes: 400_000_000),
            .critical
        )
        XCTAssertEqual(
            policy.band(forAvailableBytes: 800_000_000),
            .warning
        )
        XCTAssertEqual(
            policy.band(forAvailableBytes: 2_000_000_000),
            .normal
        )
    }

    func testHealthEventRoundTripsAndExpires() throws {
        let sessionID = UUID()
        let event = RecordingHealthEvent(
            sessionID: sessionID,
            stateVersion: 7,
            state: "recording",
            recordingStartedAtMs: 1_700_000_000_000,
            recordedAtMs: 1_700_000_600_000,
            lastAudioBufferAtMs: 1_700_000_599_000,
            chunkSequence: 3,
            bytesWritten: 1_234,
            batteryLevel: 0.5,
            storageAvailableBytes: 2_000_000_000,
            audioSessionActive: true
        )

        let decoded = try RecordingHealthEvent.decode(
            fromJSON: try event.jsonString()
        )
        XCTAssertEqual(decoded, event)
        XCTAssertTrue(decoded.isRecording)
        XCTAssertFalse(decoded.isExpired(nowMs: 1_700_000_700_000))
        XCTAssertTrue(decoded.isExpired(nowMs: 1_700_000_900_000))
    }
}
