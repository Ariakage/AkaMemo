import XCTest

@testable import AkaMemoCore

final class SearchIndexTests: XCTestCase {
    private var directory: URL!
    private var index: SQLiteSearchIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoSearchTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        index = try SQLiteSearchIndex(
            databaseURL: directory.appending(path: "search.sqlite")
        )
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(
        text: String,
        startMs: Int64,
        chunkID: UUID = UUID(),
        sessionID: UUID = UUID(),
        language: String = "zh-Hans"
    ) -> SearchIndexEntry {
        SearchIndexEntry(
            segmentID: UUID(),
            chunkID: chunkID,
            sessionID: sessionID,
            startMs: startMs,
            endMs: startMs + 2_000,
            text: text,
            language: language,
            providerVersion: "1"
        )
    }

    private func search(
        _ text: String,
        limit: Int = 50,
        startMs: Int64? = nil,
        endMs: Int64? = nil,
        sort: SearchSort = .relevance
    ) async throws -> [SearchHit] {
        try await index.search(
            SearchQuery(
                text: text,
                limit: limit,
                startMs: startMs,
                endMs: endMs,
                sort: sort
            )
        )
    }

    func testChineseOneTwoAndThreeCharacterQueries() async throws {
        let chunk = UUID()
        try await index.replaceChunk(
            chunk,
            with: [
                entry(text: "今天下午三点开会讨论项目进度", startMs: 1_000),
                entry(text: "明天上午整理会议记录", startMs: 2_000),
            ]
        )

        let one = try await search("会")
        XCTAssertEqual(one.count, 2)

        let two = try await search("开会")
        XCTAssertEqual(two.count, 1)
        XCTAssertTrue(two.first?.snippet.contains("开会") ?? false)

        let three = try await search("开会讨")
        XCTAssertEqual(three.count, 1)

        let meeting = try await search("会议")
        XCTAssertEqual(meeting.count, 1)
        XCTAssertTrue(meeting.first?.snippet.contains("会议") ?? false)
    }

    func testEnglishQueriesAreCaseInsensitive() async throws {
        try await index.replaceChunk(
            UUID(),
            with: [
                entry(
                    text: "Meeting notes about the AkaMemo project",
                    startMs: 1_000,
                    language: "en-US"
                )
            ]
        )

        let lower = try await search("meeting")
        let upper = try await search("MEETING")
        let mixedCase = try await search("AkaMemo")
        XCTAssertEqual(lower.count, 1)
        XCTAssertEqual(upper.count, 1)
        XCTAssertEqual(mixedCase.count, 1)
    }

    func testTwoCharacterEnglishQueryUsesShortIndex() async throws {
        try await index.replaceChunk(
            UUID(),
            with: [entry(text: "ab testing", startMs: 1_000, language: "en-US")]
        )

        let lower = try await search("ab")
        let upper = try await search("AB")
        XCTAssertEqual(lower.count, 1)
        XCTAssertEqual(upper.count, 1)
    }

    func testEmptyAndPunctuationQueriesReturnNothing() async throws {
        try await index.replaceChunk(
            UUID(),
            with: [entry(text: "你好，世界", startMs: 1_000)]
        )

        let empty = try await search("")
        let whitespace = try await search("   ")
        let punctuation = try await search("，。")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(whitespace.isEmpty)
        XCTAssertTrue(punctuation.isEmpty)
    }

    func testTimeRangeFilter() async throws {
        try await index.replaceChunk(
            UUID(),
            with: [
                entry(text: "项目进度讨论", startMs: 1_000),
                entry(text: "项目进度复盘", startMs: 10_000),
            ]
        )

        let filtered = try await search(
            "项目",
            startMs: 5_000,
            endMs: 20_000
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.startMs, 10_000)
    }

    func testNewestSortOrdersByTime() async throws {
        try await index.replaceChunk(
            UUID(),
            with: [
                entry(text: "项目进度", startMs: 1_000),
                entry(text: "项目进度", startMs: 9_000),
            ]
        )

        let newest = try await search("项目", sort: .newest)
        XCTAssertEqual(newest.map(\.startMs), [9_000, 1_000])
    }

    func testReplaceChunkDropsOldSegments() async throws {
        let chunk = UUID()
        try await index.replaceChunk(
            chunk,
            with: [entry(text: "旧的内容", startMs: 1_000, chunkID: chunk)]
        )
        let initialCount = try await index.entryCount()
        XCTAssertEqual(initialCount, 1)

        try await index.replaceChunk(
            chunk,
            with: [entry(text: "新的内容", startMs: 2_000, chunkID: chunk)]
        )

        let finalCount = try await index.entryCount()
        let old = try await search("旧的")
        let new = try await search("新的")
        XCTAssertEqual(finalCount, 1)
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new.count, 1)
    }

    func testDeleteChunkAndSession() async throws {
        let chunkA = UUID()
        let chunkB = UUID()
        let session = UUID()
        try await index.replaceChunk(
            chunkA,
            with: [
                entry(
                    text: "第一段内容",
                    startMs: 1_000,
                    chunkID: chunkA,
                    sessionID: session
                )
            ]
        )
        try await index.replaceChunk(
            chunkB,
            with: [
                entry(
                    text: "第二段内容",
                    startMs: 2_000,
                    chunkID: chunkB,
                    sessionID: session
                )
            ]
        )

        try await index.deleteChunk(chunkA)
        let first = try await search("第一段")
        let second = try await search("第二段")
        let countAfterChunkDelete = try await index.entryCount()
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(countAfterChunkDelete, 1)

        try await index.deleteSession(session)
        let countAfterSessionDelete = try await index.entryCount()
        XCTAssertEqual(countAfterSessionDelete, 0)
    }

    func testDeleteAllAllowsRebuild() async throws {
        try await index.replaceChunk(
            UUID(),
            with: [entry(text: "可以重建的内容", startMs: 1_000)]
        )
        try await index.deleteAll()
        let emptyCount = try await index.entryCount()
        XCTAssertEqual(emptyCount, 0)

        try await index.replaceChunk(
            UUID(),
            with: [entry(text: "可以重建的内容", startMs: 1_000)]
        )
        let rebuilt = try await search("重建")
        XCTAssertEqual(rebuilt.count, 1)
    }

    func testLimitIsRespected() async throws {
        let entries = (0..<8).map { offset in
            entry(
                text: "重复的检索词 \(offset)",
                startMs: Int64(1_000 + offset)
            )
        }
        try await index.replaceChunk(UUID(), with: entries)

        let limited = try await search("检索词", limit: 3)
        XCTAssertEqual(limited.count, 3)
    }
}
