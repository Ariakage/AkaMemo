import AkaMemoCore
import Foundation
import OSLog

/// Runs the persistent transcription queue one chunk at a time.
///
/// Queue rows, retry backoff, and transcripts live in SwiftData via
/// `TranscriptStore`; a crash resumes from those rows instead of an in-memory
/// queue. Failures are stored as `.failed` transcripts so the UI can offer a
/// manual retry.
actor TranscriptionService {
    struct RunSummary: Sendable, Equatable {
        var processed = 0
        var succeeded = 0
        var failed = 0
        var skipped = 0
    }

    private struct TranscriptDocument: Codable, Sendable {
        let transcriptID: UUID
        let chunkID: UUID
        let sessionID: UUID
        let providerID: String
        let providerVersion: String
        let language: String
        let text: String
        let status: String
        let createdAtMs: Int64
        let updatedAtMs: Int64
        let segments: [SegmentDocument]

        struct SegmentDocument: Codable, Sendable {
            let segmentID: UUID
            let startMs: Int64
            let endMs: Int64
            let text: String
            let confidence: Double?
            let isFinal: Bool
        }
    }

    private let store: TranscriptStore
    private let provider: any TranscriptionProvider
    private let applicationSupport: URL
    private let indexer: TranscriptIndexer?
    private let fileManager = FileManager.default
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "transcription"
    )
    private let batchLimit = 20

    init(
        store: TranscriptStore,
        provider: any TranscriptionProvider,
        applicationSupport: URL,
        indexer: TranscriptIndexer? = nil
    ) {
        self.store = store
        self.provider = provider
        self.applicationSupport = applicationSupport
        self.indexer = indexer
    }

    func runDueTasks(now: Date = Date()) async -> RunSummary {
        var summary = RunSummary()
        do {
            let tasks = try await store.prepareDueTasks(
                providerID: provider.id,
                providerVersion: provider.version,
                now: now
            )
            for snapshot in tasks.prefix(batchLimit) {
                summary.processed += 1
                if try await store.hasReadyTranscript(
                    chunkID: snapshot.chunkID,
                    providerID: provider.id,
                    providerVersion: provider.version
                ) {
                    summary.skipped += 1
                    continue
                }

                let audioURL = applicationSupport.appending(
                    path: snapshot.relativePath
                )
                guard fileManager.fileExists(atPath: audioURL.path) else {
                    summary.failed += 1
                    await recordFailure(
                        snapshot: snapshot,
                        code: TranscriptionErrorCode.audioMissing.rawValue,
                        now: now
                    )
                    continue
                }

                do {
                    let draft = try await provider.transcribe(
                        audioURL: audioURL,
                        options: TranscriptionOptions(
                            startedAtMs: snapshot.startedAtMs
                        )
                    )
                    guard
                        let saved = try await store.saveTranscript(
                            snapshot: snapshot,
                            draft: draft,
                            now: now
                        )
                    else {
                        summary.skipped += 1
                        continue
                    }
                    await writeDocument(
                        draft: draft,
                        result: saved,
                        snapshot: snapshot,
                        now: now
                    )
                    await indexer?.replaceChunk(
                        snapshot.chunkID,
                        entries: saved.entries
                    )
                    summary.succeeded += 1
                } catch {
                    summary.failed += 1
                    let code =
                        (error as? TranscriptionFailure)?.code
                        .rawValue ?? TranscriptionErrorCode.unknown.rawValue
                    await recordFailure(
                        snapshot: snapshot,
                        code: code,
                        now: now
                    )
                }
            }
        } catch {
            logger.error(
                "transcription queue failed: \(String(describing: error), privacy: .public)"
            )
        }
        logger.info(
            "transcription run: processed \(summary.processed, privacy: .public), succeeded \(summary.succeeded, privacy: .public), failed \(summary.failed, privacy: .public), skipped \(summary.skipped, privacy: .public)"
        )
        return summary
    }

    func retry(chunkID: UUID, now: Date = Date()) async {
        do {
            try await store.retryFailedTasks(
                chunkID: chunkID,
                providerID: provider.id,
                providerVersion: provider.version,
                now: now
            )
        } catch {
            logger.error(
                "transcription retry failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func recordFailure(
        snapshot: TranscriptionTaskSnapshot,
        code: String,
        now: Date
    ) async {
        do {
            let attempts = try await store.recordFailure(
                snapshot: snapshot,
                providerID: provider.id,
                providerVersion: provider.version,
                language: "",
                code: code,
                now: now
            )
            logger.info(
                "transcription failed with \(code, privacy: .public), attempt \(attempts, privacy: .public)"
            )
        } catch {
            logger.error(
                "could not record transcription failure: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Writes a JSON snapshot next to the archive. A failed write does not
    /// roll back the SwiftData transcript.
    private func writeDocument(
        draft: TranscriptDraft,
        result: TranscriptSaveResult,
        snapshot: TranscriptionTaskSnapshot,
        now: Date
    ) async {
        let document = TranscriptDocument(
            transcriptID: result.transcriptID,
            chunkID: snapshot.chunkID,
            sessionID: snapshot.sessionID,
            providerID: draft.providerID,
            providerVersion: draft.providerVersion,
            language: draft.language,
            text: draft.text,
            status: TranscriptStatus.ready.rawValue,
            createdAtMs: TimeMath.epochMs(now),
            updatedAtMs: TimeMath.epochMs(now),
            segments: draft.segments.map { segment in
                TranscriptDocument.SegmentDocument(
                    segmentID: UUID(),
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    confidence: segment.confidence,
                    isFinal: true
                )
            }
        )
        let destination = applicationSupport.appending(path: result.relativePath)
        let directory = destination.deletingLastPathComponent()
        let writer = AtomicFileWriter(directory: directory)
        do {
            _ = try await writer.writeJSON(
                document,
                fileName: destination.lastPathComponent,
                overwrite: true
            )
        } catch {
            logger.error(
                "could not write transcript file: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
