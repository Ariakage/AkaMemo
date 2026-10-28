import AkaMemoCore
import SwiftData
import XCTest

@testable import AkaMemo

private actor FakeTranscriptionProvider: TranscriptionProvider {
    enum Outcome: Sendable {
        case success(TranscriptDraft)
        case failure(TranscriptionErrorCode)
    }

    nonisolated let id = "fake"
    nonisolated let version = "1"
    nonisolated let supportedLanguages = ["zh-Hans", "en-US"]

    private var outcomes: [Outcome]
    private(set) var callCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func enqueue(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions
    ) async throws -> TranscriptDraft {
        callCount += 1
        guard !outcomes.isEmpty else {
            throw TranscriptionFailure(code: .engineUnavailable)
        }
        switch outcomes.removeFirst() {
        case .success(let draft):
            return draft
        case .failure(let code):
            throw TranscriptionFailure(code: code)
        }
    }
}

final class TranscriptionServiceTests: XCTestCase {
    private struct Environment {
        let root: URL
        let container: ModelContainer
        let provider: FakeTranscriptionProvider
        let service: TranscriptionService
    }

    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEnvironment(
        outcomes: [FakeTranscriptionProvider.Outcome]
    ) throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "AkaMemoTranscriptionTests-\(UUID().uuidString)",
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
        let provider = FakeTranscriptionProvider(outcomes: outcomes)
        let service = TranscriptionService(
            store: store,
            provider: provider,
            applicationSupport: root
        )
        return Environment(
            root: root,
            container: container,
            provider: provider,
            service: service
        )
    }

    @discardableResult
    private func insertChunk(
        in environment: Environment,
        relativePath: String = "audio/2026/10/28/session/0000-1.m4a",
        writeAudio: Bool = true
    ) throws -> ReceivedChunkRecord {
        let context = ModelContext(environment.container)
        let record = ReceivedChunkRecord(
            chunkID: UUID(),
            sessionID: UUID(),
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
            relativePath: relativePath,
            receivedAt: startedAt
        )
        context.insert(record)
        try context.save()
        if writeAudio {
            let url = environment.root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("audio".utf8).write(to: url)
        }
        return record
    }

    private func draft(startedAtMs: Int64) -> TranscriptDraft {
        TranscriptDraft(
            providerID: "fake",
            providerVersion: "1",
            language: "zh-Hans",
            text: "你好 世界",
            segments: [
                SegmentDraft(
                    startMs: startedAtMs + 100,
                    endMs: startedAtMs + 900,
                    text: "你好",
                    confidence: 0.9
                ),
                SegmentDraft(
                    startMs: startedAtMs + 1_000,
                    endMs: startedAtMs + 1_800,
                    text: "世界",
                    confidence: 0.8
                ),
            ]
        )
    }

    @MainActor
    func testRunProducesReadyTranscriptAndIsIdempotent() async throws {
        let environment = try makeEnvironment(
            outcomes: [.success(draft(startedAtMs: 1_800_000_000_000))]
        )
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try insertChunk(in: environment)

        let first = await environment.service.runDueTasks(now: startedAt)
        XCTAssertEqual(first.processed, 1)
        XCTAssertEqual(first.succeeded, 1)
        XCTAssertEqual(first.failed, 0)

        let context = ModelContext(environment.container)
        let transcripts = try context.fetch(
            FetchDescriptor<TranscriptRecord>()
        )
        XCTAssertEqual(transcripts.count, 1)
        XCTAssertEqual(transcripts.first?.status, .ready)
        XCTAssertEqual(transcripts.first?.text, "你好 世界")
        let segments = try context.fetch(
            FetchDescriptor<TranscriptSegmentRecord>(
                sortBy: [SortDescriptor(\.startMs)]
            )
        )
        XCTAssertEqual(segments.map(\.text), ["你好", "世界"])
        XCTAssertEqual(segments.first?.startMs, 1_800_000_000_100)

        guard let stored = transcripts.first else {
            return XCTFail("missing transcript")
        }
        let documentURL = environment.root.appending(
            path: TranscriptStore.transcriptRelativePath(
                chunkStartedAt: startedAt,
                chunkID: stored.chunkID,
                transcriptID: stored.transcriptID
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: documentURL.path)
        )

        let second = await environment.service.runDueTasks(
            now: startedAt.addingTimeInterval(3_600)
        )
        XCTAssertEqual(second.processed, 0)
        let callCount = await environment.provider.callCount
        XCTAssertEqual(callCount, 1)
        let afterCount = try context.fetchCount(
            FetchDescriptor<TranscriptRecord>()
        )
        XCTAssertEqual(afterCount, 1)
    }

    @MainActor
    func testFailuresBackOffThenManualRetrySucceeds() async throws {
        let environment = try makeEnvironment(
            outcomes: [
                .failure(.engineUnavailable),
                .failure(.engineUnavailable),
                .failure(.engineUnavailable),
            ]
        )
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let chunk = try insertChunk(in: environment)

        let first = await environment.service.runDueTasks(now: startedAt)
        XCTAssertEqual(first.failed, 1)
        let context = ModelContext(environment.container)
        let transcripts = try context.fetch(
            FetchDescriptor<TranscriptRecord>()
        )
        XCTAssertEqual(transcripts.first?.status, .failed)
        XCTAssertEqual(
            transcripts.first?.errorCode,
            TranscriptionErrorCode.engineUnavailable.rawValue
        )

        let immediate = await environment.service.runDueTasks(
            now: startedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(immediate.processed, 0)

        let second = await environment.service.runDueTasks(
            now: startedAt.addingTimeInterval(31)
        )
        XCTAssertEqual(second.failed, 1)
        let third = await environment.service.runDueTasks(
            now: startedAt.addingTimeInterval(31 + 121)
        )
        XCTAssertEqual(third.failed, 1)

        let tasks = try context.fetch(
            FetchDescriptor<TranscriptionTaskRecord>()
        )
        XCTAssertEqual(tasks.first?.state, .failed)
        XCTAssertEqual(tasks.first?.attemptCount, 3)

        await environment.provider.enqueue(
            .success(draft(startedAtMs: 1_800_000_000_000))
        )
        await environment.service.retry(chunkID: chunk.chunkID)
        let retried = await environment.service.runDueTasks(
            now: startedAt.addingTimeInterval(600)
        )
        XCTAssertEqual(retried.succeeded, 1)

        let afterTranscripts = try context.fetch(
            FetchDescriptor<TranscriptRecord>()
        )
        XCTAssertEqual(afterTranscripts.count, 1)
        XCTAssertEqual(afterTranscripts.first?.status, .ready)
        XCTAssertEqual(afterTranscripts.first?.errorCode, nil)
    }

    @MainActor
    func testMissingAudioFailsWithoutCallingProvider() async throws {
        let environment = try makeEnvironment(outcomes: [])
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try insertChunk(in: environment, writeAudio: false)

        let summary = await environment.service.runDueTasks(now: startedAt)
        XCTAssertEqual(summary.failed, 1)
        let callCount = await environment.provider.callCount
        XCTAssertEqual(callCount, 0)

        let context = ModelContext(environment.container)
        let transcripts = try context.fetch(
            FetchDescriptor<TranscriptRecord>()
        )
        XCTAssertEqual(transcripts.first?.status, .failed)
        XCTAssertEqual(
            transcripts.first?.errorCode,
            TranscriptionErrorCode.audioMissing.rawValue
        )
    }
}
