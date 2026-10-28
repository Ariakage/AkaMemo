import XCTest

@testable import AkaMemoCore

final class AkaMemoCoreTests: XCTestCase {
    func testAudioChunkDefaultsMatchADR0011() {
        let startedAt = Date()
        let session = RecordingSession(startedAt: startedAt)
        let chunk = AudioChunk(
            sessionID: session.id,
            sessionStartedAt: session.startedAt,
            sequence: 0,
            startedAt: startedAt,
            checksumSHA256: "test",
            relativePath: "audio/test.m4a"
        )

        XCTAssertEqual(chunk.sampleRate, 44_100)
        XCTAssertEqual(chunk.channels, 2)
        XCTAssertEqual(chunk.bitRate, 96_000)
        XCTAssertEqual(chunk.formatVersion, 1)
        XCTAssertEqual(chunk.localState, .present)
        XCTAssertEqual(chunk.transferState, .localOnly)
        XCTAssertEqual(chunk.processingState, .pending)
    }

    func testDataEpochUsesEpochAsIdentity() {
        let epoch = DataEpoch(epoch: 1_761_700_000_000)
        XCTAssertEqual(epoch.id, 1_761_700_000_000)
    }
}
