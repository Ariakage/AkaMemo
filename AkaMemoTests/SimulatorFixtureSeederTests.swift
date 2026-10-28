import AkaMemoCore
import SwiftData
import XCTest

@testable import AkaMemo

final class SimulatorFixtureSeederTests: XCTestCase {
    private struct Environment {
        let root: URL
        let container: ModelContainer
        let store: MemoryStore
        let seeder: SimulatorFixtureSeeder
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoSeedTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ReceivedChunkRecord.self,
            configurations: configuration
        )
        let store = MemoryStore(modelContainer: container)
        let inbox = PhoneInboxService(store: store, applicationSupport: root)
        let seeder = SimulatorFixtureSeeder(inbox: inbox, store: store)
        return Environment(
            root: root,
            container: container,
            store: store,
            seeder: seeder
        )
    }

    func testSeedInsertsSyntheticChunks() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }

        let report = await environment.seeder.seedIfNeeded(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(report.accepted, SimulatorFixtureSeeder.chunkCount)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertEqual(report.rejected, 0)
        XCTAssertEqual(report.skipped, 0)
        let storedCount = try await environment.store.count()
        XCTAssertEqual(storedCount, SimulatorFixtureSeeder.chunkCount)
    }

    @MainActor
    func testSeedGroupsSessionsAndIsIdempotent() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }

        let first = await environment.seeder.seedIfNeeded(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let second = await environment.seeder.seedIfNeeded(
            now: Date(timeIntervalSince1970: 1_800_100_000)
        )

        XCTAssertEqual(first.accepted, SimulatorFixtureSeeder.chunkCount)
        XCTAssertEqual(second.accepted, 0)
        XCTAssertEqual(second.duplicates, 0)
        XCTAssertEqual(second.skipped, SimulatorFixtureSeeder.chunkCount)

        let context = ModelContext(environment.container)
        let records = try context.fetch(FetchDescriptor<ReceivedChunkRecord>())
        XCTAssertEqual(records.count, SimulatorFixtureSeeder.chunkCount)

        let sessions = SessionAggregator.group(records.map(\.summary))
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.first?.chunkCount, 2)

        for record in records {
            XCTAssertEqual(record.checksumSHA256.count, 64)
            let url = environment.root.appending(path: record.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
