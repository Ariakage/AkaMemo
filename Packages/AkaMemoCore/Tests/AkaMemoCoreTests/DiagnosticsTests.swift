import XCTest

@testable import AkaMemoCore

final class DiagnosticsTests: XCTestCase {
    func testSanitizerStripsControlCharactersAndTruncates() {
        let message = String(repeating: "a", count: 300) + "\n\t"
        let sanitized = LogSanitizer.message(message)

        XCTAssertEqual(sanitized.count, LogSanitizer.maxMessageLength)
        XCTAssertFalse(sanitized.contains("\n"))
    }

    func testSanitizerKeepsOnlyWhitelistedMetadata() {
        let sanitized = LogSanitizer.metadata([
            "errorCode": "engineUnavailable",
            "chunkSeq": "3",
            "badKey": "value",
            "path": "/Users/private/audio.m4a",
            "state": String(repeating: "x", count: 100),
        ])

        XCTAssertEqual(sanitized["errorCode"], "engineUnavailable")
        XCTAssertEqual(sanitized["chunkSeq"], "3")
        XCTAssertNil(sanitized["badKey"])
        XCTAssertNil(sanitized["path"])
        XCTAssertEqual(
            sanitized["state"]?.count,
            LogSanitizer.maxMetadataValueLength
        )
    }

    func testRedactedIDKeepsEightCharacters() throws {
        let id = try XCTUnwrap(
            UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")
        )
        XCTAssertEqual(LogSanitizer.redactedID(id), "12345678")
    }

    func testRingBufferDropsOldestAndCounts() {
        var buffer = LogRingBuffer(capacity: 2)
        for index in 0..<4 {
            buffer.append(
                LogEntry(
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    level: .info,
                    category: .recording,
                    message: "event",
                    source: .iphone
                )
            )
        }

        XCTAssertEqual(buffer.entries.map(\.message), ["event", "event"])
        XCTAssertEqual(buffer.droppedCount, 2)
        buffer.removeAll()
        XCTAssertTrue(buffer.entries.isEmpty)
        XCTAssertEqual(buffer.droppedCount, 0)
    }

    func testFileLogWritesJSONLinesAndRotates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoDiagnosticsTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsFileLog(root: root, maxFileBytes: 240)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<12 {
            try await log.append(
                LogEntry(
                    timestamp: now,
                    level: .info,
                    category: .storage,
                    message: String(repeating: "x", count: 60),
                    source: .iphone
                ),
                now: now
            )
        }

        let urls = await log.fileURLs()
        XCTAssertGreaterThan(urls.count, 1)
        guard let first = urls.first else {
            return XCTFail("missing log file")
        }
        let text = try String(contentsOf: first, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(
            LogEntry.self,
            from: Data(lines[0].utf8)
        )
        XCTAssertEqual(decoded.category, .storage)

        try await log.clear()
        let afterClear = await log.fileURLs()
        XCTAssertTrue(afterClear.isEmpty)
    }
}
