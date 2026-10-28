import AkaMemoCore
import XCTest

@testable import AkaMemoWatch

private final class FakeHealthTransport: HealthEventTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedContextStates: [String] = []
    private var storedEventStates: [String] = []

    var contextStates: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedContextStates
    }

    var eventStates: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEventStates
    }

    func updateHealthContext(_ event: RecordingHealthEvent) -> Bool {
        lock.lock()
        storedContextStates.append(event.state)
        lock.unlock()
        return true
    }

    func sendHealthEvent(_ event: RecordingHealthEvent) -> Bool {
        lock.lock()
        storedEventStates.append(event.state)
        lock.unlock()
        return true
    }
}

final class WatchHealthPublisherTests: XCTestCase {
    private let sessionID = UUID()

    private func event(
        state: String,
        atMs: Int64
    ) -> RecordingHealthEvent {
        RecordingHealthEvent(
            sessionID: sessionID,
            stateVersion: atMs,
            state: state,
            recordingStartedAtMs: 1_800_000_000_000,
            recordedAtMs: atMs,
            lastAudioBufferAtMs: atMs,
            chunkSequence: 1,
            bytesWritten: 100,
            batteryLevel: 0.5,
            storageAvailableBytes: 2_000_000_000,
            audioSessionActive: state == "recording"
        )
    }

    func testContextIsThrottledButStateChangesAreImmediate() async {
        let transport = FakeHealthTransport()
        let publisher = WatchHealthPublisher(
            transport: transport,
            intervalMs: 10_000
        )

        await publisher.publish(event(state: "recording", atMs: 1_800_000_000_000))
        await publisher.publish(
            event(state: "recording", atMs: 1_800_000_005_000)
        )
        await publisher.publish(
            event(state: "recording", atMs: 1_800_000_010_000)
        )
        await publisher.publish(event(state: "paused", atMs: 1_800_000_011_000))

        XCTAssertEqual(transport.contextStates, ["recording", "recording", "paused"])
        XCTAssertEqual(transport.eventStates, ["recording", "paused"])
    }
}
