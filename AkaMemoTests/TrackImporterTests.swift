import AkaMemoCore
import SwiftData
import XCTest

@testable import AkaMemo

final class TrackImporterTests: XCTestCase {
    private struct Environment {
        let root: URL
        let container: ModelContainer
        let deletionStore: DeletionStore
        let store: LocationTrackStore
        let importer: TrackImporter
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoTrackTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ReceivedChunkRecord.self,
            TranscriptRecord.self,
            TranscriptSegmentRecord.self,
            TranscriptionTaskRecord.self,
            DeletionTombstoneRecord.self,
            DataEpochRecord.self,
            LocationTrackRecord.self,
            configurations: configuration
        )
        let deletionStore = DeletionStore(modelContainer: container)
        let store = LocationTrackStore(modelContainer: container)
        let importer = TrackImporter(
            store: store,
            applicationSupport: root,
            deletionStore: deletionStore,
            diagnostics: nil
        )
        return Environment(
            root: root,
            container: container,
            deletionStore: deletionStore,
            store: store,
            importer: importer
        )
    }

    private func points(
        sessionStartedAtMs: Int64,
        count: Int = 3
    ) -> [LocationPoint] {
        (0..<count).map { index in
            LocationPoint(
                timestampMs: sessionStartedAtMs + Int64(index) * 300_000,
                latitude: 31.2304 + Double(index) * 0.001,
                longitude: 121.4737 + Double(index) * 0.001,
                altitude: 10,
                horizontalAccuracy: 8
            )
        }
    }

    private func makeUpload(
        in environment: Environment,
        sessionID: UUID,
        sessionStartedAtMs: Int64,
        points: [LocationPoint],
        checksumOverride: String? = nil
    ) throws -> (url: URL, envelope: TrackTransferEnvelope) {
        var data = Data()
        for point in points {
            data.append(try LocationTrackCodec.encodeLine(point))
        }
        let url = environment.root.appending(
            path: "upload-\(UUID().uuidString).jsonl"
        )
        try data.write(to: url)
        let envelope = TrackTransferEnvelope(
            trackID: UUID(),
            sessionID: sessionID,
            sessionStartedAtMs: sessionStartedAtMs,
            startedAtMs: points.first?.timestampMs ?? sessionStartedAtMs,
            endedAtMs: points.last?.timestampMs ?? sessionStartedAtMs,
            pointCount: points.count,
            checksumSHA256: checksumOverride
                ?? AtomicFileWriter.sha256Hex(data),
            relativePath: "location/\(sessionID.uuidString).jsonl"
        )
        return (url, envelope)
    }

    private func records(
        in environment: Environment
    ) throws
        -> [LocationTrackRecord]
    {
        let context = ModelContext(environment.container)
        return try context.fetch(FetchDescriptor<LocationTrackRecord>())
    }

    func testImportAcceptsAndStoresTrack() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sessionID = UUID()
        let sessionStart: Int64 = 1_800_000_000_000
        let upload = try makeUpload(
            in: environment,
            sessionID: sessionID,
            sessionStartedAtMs: sessionStart,
            points: points(sessionStartedAtMs: sessionStart)
        )

        let result = await environment.importer.importFile(
            at: upload.url,
            envelope: upload.envelope
        )

        guard case .accepted(let count) = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(count, 3)
        let stored = try records(in: environment)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.pointCount, 3)
        XCTAssertEqual(stored.first?.sessionID, sessionID)
        XCTAssertGreaterThan(stored.first?.distanceMeters ?? 0, 0)
        guard let relativePath = stored.first?.relativePath else {
            return XCTFail("missing relative path")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.root.appending(path: relativePath).path
            )
        )
    }

    func testDuplicateIsIdempotent() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sessionID = UUID()
        let sessionStart: Int64 = 1_800_000_000_000
        let first = try makeUpload(
            in: environment,
            sessionID: sessionID,
            sessionStartedAtMs: sessionStart,
            points: points(sessionStartedAtMs: sessionStart)
        )
        _ = await environment.importer.importFile(
            at: first.url,
            envelope: first.envelope
        )
        let second = try makeUpload(
            in: environment,
            sessionID: sessionID,
            sessionStartedAtMs: sessionStart,
            points: points(sessionStartedAtMs: sessionStart)
        )
        let envelope = TrackTransferEnvelope(
            trackID: first.envelope.trackID,
            sessionID: first.envelope.sessionID,
            sessionStartedAtMs: first.envelope.sessionStartedAtMs,
            startedAtMs: first.envelope.startedAtMs,
            endedAtMs: first.envelope.endedAtMs,
            pointCount: first.envelope.pointCount,
            checksumSHA256: first.envelope.checksumSHA256,
            relativePath: first.envelope.relativePath
        )

        let result = await environment.importer.importFile(
            at: second.url,
            envelope: envelope
        )

        XCTAssertEqual(result, .duplicate)
        XCTAssertEqual(try records(in: environment).count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: second.url.path)
        )
    }

    func testRejectsNonMonotonicAndBadChecksum() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sessionID = UUID()
        let sessionStart: Int64 = 1_800_000_000_000
        var unordered = points(sessionStartedAtMs: sessionStart)
        unordered.swapAt(1, 2)
        let badOrder = try makeUpload(
            in: environment,
            sessionID: sessionID,
            sessionStartedAtMs: sessionStart,
            points: unordered
        )
        let orderResult = await environment.importer.importFile(
            at: badOrder.url,
            envelope: badOrder.envelope
        )
        XCTAssertEqual(orderResult, .rejected("nonMonotonic"))

        let good = try makeUpload(
            in: environment,
            sessionID: sessionID,
            sessionStartedAtMs: sessionStart,
            points: points(sessionStartedAtMs: sessionStart),
            checksumOverride: String(repeating: "b", count: 64)
        )
        let checksumResult = await environment.importer.importFile(
            at: good.url,
            envelope: good.envelope
        )
        XCTAssertEqual(checksumResult, .rejected("checksumMismatch"))
        XCTAssertTrue(try records(in: environment).isEmpty)
    }

    func testRejectsDeletedSessionAndEpoch() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sessionID = UUID()
        let sessionStart: Int64 = 1_800_000_000_000
        _ = try await environment.deletionStore.prepareDeletion(
            scope: .session,
            entityID: sessionID,
            sessionID: sessionID,
            reason: "userDelete"
        )
        let upload = try makeUpload(
            in: environment,
            sessionID: sessionID,
            sessionStartedAtMs: sessionStart,
            points: points(sessionStartedAtMs: sessionStart)
        )

        let sessionResult = await environment.importer.importFile(
            at: upload.url,
            envelope: upload.envelope
        )
        XCTAssertEqual(sessionResult, .rejected("deletedSession"))
        XCTAssertTrue(try records(in: environment).isEmpty)

        let oldSessionID = UUID()
        let oldStart: Int64 = 1_700_000_000_000
        _ = try await environment.deletionStore.prepareDeletion(
            scope: .all,
            entityID: nil,
            sessionID: nil,
            reason: "allData"
        )
        let oldUpload = try makeUpload(
            in: environment,
            sessionID: oldSessionID,
            sessionStartedAtMs: oldStart,
            points: points(sessionStartedAtMs: oldStart)
        )
        let epochResult = await environment.importer.importFile(
            at: oldUpload.url,
            envelope: oldUpload.envelope
        )
        XCTAssertEqual(epochResult, .rejected("deletedSession"))
    }
}
