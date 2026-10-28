import AkaMemoCore
import XCTest

@testable import AkaMemoWatch

final class LocationFileWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoLocationWriter-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func point(_ offset: Int64) -> LocationPoint {
        LocationPoint(
            timestampMs: 1_800_000_000_000 + offset,
            latitude: 31.2304,
            longitude: 121.4737,
            altitude: 10,
            horizontalAccuracy: 8
        )
    }

    func testAppendFinalizeWritesJSONL() async throws {
        let fileURL = root.appending(path: "track.jsonl")
        let writer = try LocationFileWriter(fileURL: fileURL)

        try await writer.append(point(0))
        try await writer.append(point(300_000))
        let result = try await writer.finalize()

        XCTAssertEqual(result.pointCount, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fileURL.appendingPathExtension("part").path
            )
        )
        let data = try Data(contentsOf: fileURL)
        let decoded = LocationTrackCodec.decode(data)
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.invalidLineCount, 0)
    }

    func testEmptyFinalizeRemovesPartFile() async throws {
        let fileURL = root.appending(path: "empty.jsonl")
        let writer = try LocationFileWriter(fileURL: fileURL)

        let result = try await writer.finalize()

        XCTAssertEqual(result.pointCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path)
        )
    }
}
