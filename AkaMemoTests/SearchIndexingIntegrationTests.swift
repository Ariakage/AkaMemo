import AkaMemoCore
import SwiftData
import XCTest

@testable import AkaMemo

final class SearchIndexingIntegrationTests: XCTestCase {
    private struct Environment {
        let root: URL
        let container: ModelContainer
        let store: TranscriptStore
        let index: SQLiteSearchIndex
        let indexer: TranscriptIndexer
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoSearchIntegration-\(UUID().uuidString)",
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
            configurations: configuration
        )
        let store = TranscriptStore(modelContainer: container)
        let index = try SQLiteSearchIndex(
            databaseURL: root.appending(path: "index/search.sqlite")
        )
        return Environment(
            root: root,
            container: container,
            store: store,
            index: index,
            indexer: TranscriptIndexer(index: index)
        )
    }

    private func insertTranscript(in environment: Environment) throws {
        let chunkID = UUID()
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let context = ModelContext(environment.container)
        context.insert(
            ReceivedChunkRecord(
                chunkID: chunkID,
                sessionID: sessionID,
                sessionStartedAt: startedAt,
                sequence: 0,
                startedAt: startedAt,
                durationMs: 12_000,
                byteSize: 5,
                checksumSHA256: String(repeating: "a", count: 64),
                formatVersion: 1,
                sampleRate: 44_100,
                channels: 2,
                bitRate: 96_000,
                relativePath: "audio/2026/10/28/session/0000.m4a",
                receivedAt: startedAt
            )
        )
        let transcript = TranscriptRecord(
            chunkID: chunkID,
            sessionID: sessionID,
            providerID: "fake",
            providerVersion: "1",
            language: "zh-Hans",
            text: "今天开会 整理会议记录",
            status: .ready
        )
        context.insert(transcript)
        context.insert(
            TranscriptSegmentRecord(
                transcriptID: transcript.transcriptID,
                chunkID: chunkID,
                sessionID: sessionID,
                startMs: 1_800_000_000_100,
                endMs: 1_800_000_000_900,
                text: "今天开会"
            )
        )
        context.insert(
            TranscriptSegmentRecord(
                transcriptID: transcript.transcriptID,
                chunkID: chunkID,
                sessionID: sessionID,
                startMs: 1_800_000_001_000,
                endMs: 1_800_000_001_900,
                text: "整理会议记录"
            )
        )
        try context.save()
    }

    func testRebuildFromSwiftDataAndSearch() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try insertTranscript(in: environment)

        let rebuilt = await environment.indexer.rebuild(store: environment.store)
        XCTAssertEqual(rebuilt, 2)

        let short = try await environment.index.search(
            SearchQuery(text: "开会")
        )
        XCTAssertEqual(short.count, 1)
        XCTAssertTrue(short.first?.snippet.contains("开会") ?? false)

        let oneCharacter = try await environment.index.search(
            SearchQuery(text: "会")
        )
        XCTAssertEqual(oneCharacter.count, 2)

        let threeCharacters = try await environment.index.search(
            SearchQuery(text: "会议记")
        )
        XCTAssertEqual(threeCharacters.count, 1)
    }

    func testEnsureIndexedOnlyBuildsWhenEmpty() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try insertTranscript(in: environment)

        await environment.indexer.ensureIndexed(store: environment.store)
        let firstCount = try await environment.index.entryCount()
        XCTAssertEqual(firstCount, 2)

        try await environment.index.deleteAll()
        await environment.indexer.ensureIndexed(store: environment.store)
        let rebuiltCount = try await environment.index.entryCount()
        XCTAssertEqual(rebuiltCount, 2)
    }

    func testReplaceChunkUpdatesIndex() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let chunkID = UUID()
        let sessionID = UUID()
        let entry = SearchIndexEntry(
            segmentID: UUID(),
            chunkID: chunkID,
            sessionID: sessionID,
            startMs: 1_800_000_000_000,
            endMs: 1_800_000_001_000,
            text: "新的检索内容",
            language: "zh-Hans",
            providerVersion: "1"
        )

        await environment.indexer.replaceChunk(chunkID, entries: [entry])
        let hits = try await environment.index.search(
            SearchQuery(text: "检索")
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.chunkID, chunkID)
    }
}
