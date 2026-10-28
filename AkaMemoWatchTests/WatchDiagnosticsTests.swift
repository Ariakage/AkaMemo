import AkaMemoCore
import XCTest

@testable import AkaMemoWatch

private final class FakeDiagnosticsTransport: DiagnosticsTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: [DiagnosticsBatch] = []
    private var available = true

    var batches: [DiagnosticsBatch] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func setAvailable(_ value: Bool) {
        lock.lock()
        available = value
        lock.unlock()
    }

    func sendDiagnostics(_ batch: DiagnosticsBatch) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else {
            return false
        }
        stored.append(batch)
        return true
    }
}

final class WatchDiagnosticsTests: XCTestCase {
    func testFlushSendsBatchesAndEmptiesBuffer() async {
        let transport = FakeDiagnosticsTransport()
        let diagnostics = WatchDiagnostics(transport: transport)

        for index in 0..<120 {
            await diagnostics.log(
                level: .info,
                category: .recording,
                message: "event",
                metadata: ["count": "\(index)"]
            )
        }
        await diagnostics.flush()

        let remaining = await diagnostics.snapshot()
        XCTAssertTrue(remaining.isEmpty)
        let batches = transport.batches
        XCTAssertEqual(
            batches.reduce(0) { $0 + $1.entries.count },
            120
        )
        XCTAssertTrue(
            batches.allSatisfy {
                $0.entries.count <= DiagnosticsBatch.maximumEntryCount
            }
        )
        XCTAssertTrue(
            batches.allSatisfy {
                $0.entries.allSatisfy { $0.source == .watch }
            }
        )
    }

    func testOfflineEntriesStayBufferedUntilTransportReturns() async {
        let transport = FakeDiagnosticsTransport()
        transport.setAvailable(false)
        let diagnostics = WatchDiagnostics(transport: transport)

        for _ in 0..<5 {
            await diagnostics.log(
                level: .warning,
                category: .storage,
                message: "storage band changed",
                metadata: ["state": "warning"]
            )
        }
        await diagnostics.flush()
        let buffered = await diagnostics.snapshot()
        XCTAssertEqual(buffered.count, 5)
        XCTAssertTrue(transport.batches.isEmpty)

        transport.setAvailable(true)
        await diagnostics.flush()
        let after = await diagnostics.snapshot()
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(
            transport.batches.reduce(0) { $0 + $1.entries.count },
            5
        )
    }

    func testBufferIsBoundedAndSanitized() async {
        let transport = FakeDiagnosticsTransport()
        transport.setAvailable(false)
        let diagnostics = WatchDiagnostics(transport: transport)

        for _ in 0..<(WatchDiagnostics.capacity + 20) {
            await diagnostics.log(
                level: .info,
                category: .location,
                message: "location setting changed",
                metadata: [
                    "state": "enabled",
                    "path": "/private/secret",
                ]
            )
        }

        let snapshot = await diagnostics.snapshot()
        XCTAssertEqual(snapshot.count, WatchDiagnostics.capacity)
        let dropped = await diagnostics.dropped()
        XCTAssertEqual(dropped, 20)
        XCTAssertNil(snapshot.first?.metadata["path"])
        XCTAssertEqual(snapshot.first?.metadata["state"], "enabled")
    }
}
