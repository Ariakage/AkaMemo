#if DEBUG
    import AkaMemoCore
    import Foundation
    import OSLog
    import SwiftData

    /// Adds synthetic, clearly labeled transcripts to the demo chunks so the
    /// search screen can be tested in the simulator without a Watch recording.
    ///
    /// Only runs in Debug builds when `-AkaMemoSeedDemoChunks` is passed, and
    /// skips chunks that already have a transcript. The text is fixture data,
    /// never a real recording.
    actor SimulatorTranscriptSeeder {
        private let container: ModelContainer
        private let indexer: TranscriptIndexer?
        private let logger = Logger(
            subsystem: "com.ariakage.AkaMemo",
            category: "storage"
        )

        init(container: ModelContainer, indexer: TranscriptIndexer?) {
            self.container = container
            self.indexer = indexer
        }

        func seedIfNeeded(now: Date = Date()) async {
            let context = ModelContext(container)
            let chunks: [ReceivedChunkRecord]
            let existing: [TranscriptRecord]
            do {
                chunks = try context.fetch(
                    FetchDescriptor<ReceivedChunkRecord>(
                        sortBy: [
                            SortDescriptor(\.startedAt),
                            SortDescriptor(\.sequence),
                        ]
                    )
                )
                existing = try context.fetch(
                    FetchDescriptor<TranscriptRecord>()
                )
            } catch {
                logger.error(
                    "simulator transcript seed read failed: \(String(describing: error), privacy: .public)"
                )
                return
            }

            let chunksWithTranscripts = Set(existing.map(\.chunkID))
            let fixtures = Dictionary(
                uniqueKeysWithValues: SimulatorFixtureSeeder.transcriptFixtures()
                    .map { ($0.chunkID, $0.text) }
            )
            var indexed: [(chunkID: UUID, entries: [SearchIndexEntry])] = []

            for chunk in chunks
            where !chunksWithTranscripts.contains(chunk.chunkID) {
                guard let text = fixtures[chunk.chunkID] else {
                    continue
                }
                let transcript = TranscriptRecord(
                    chunkID: chunk.chunkID,
                    sessionID: chunk.sessionID,
                    providerID: "simulator-fixture",
                    providerVersion: "1",
                    language: "zh-Hans",
                    text: text,
                    status: .ready,
                    createdAt: now,
                    updatedAt: now
                )
                context.insert(transcript)

                let startMs = TimeMath.epochMs(chunk.startedAt) + 500
                let parts = Self.split(text)
                var entries: [SearchIndexEntry] = []
                for (offset, part) in parts.enumerated() {
                    let segmentStart = startMs + Int64(offset) * 2_500
                    let segment = TranscriptSegmentRecord(
                        transcriptID: transcript.transcriptID,
                        chunkID: chunk.chunkID,
                        sessionID: chunk.sessionID,
                        startMs: segmentStart,
                        endMs: segmentStart + 2_000,
                        text: part
                    )
                    context.insert(segment)
                    entries.append(
                        SearchIndexEntry(
                            segmentID: segment.segmentID,
                            chunkID: chunk.chunkID,
                            sessionID: chunk.sessionID,
                            startMs: segmentStart,
                            endMs: segmentStart + 2_000,
                            text: part,
                            language: "zh-Hans",
                            providerVersion: "1"
                        )
                    )
                }
                indexed.append((chunk.chunkID, entries))
            }

            guard !indexed.isEmpty else {
                return
            }
            do {
                try context.save()
            } catch {
                logger.error(
                    "simulator transcript seed save failed: \(String(describing: error), privacy: .public)"
                )
                return
            }
            if let indexer {
                for item in indexed {
                    await indexer.replaceChunk(
                        item.chunkID,
                        entries: item.entries
                    )
                }
            }
            logger.info(
                "simulator transcript seed inserted \(indexed.count, privacy: .public) transcripts"
            )
        }

        private static func split(_ text: String) -> [String] {
            for separator in ["，", "。", ","] {
                if let range = text.range(of: separator) {
                    let first = String(text[..<range.lowerBound])
                    let second = String(text[range.upperBound...])
                    if !first.isEmpty, !second.isEmpty {
                        return [first, second]
                    }
                }
            }
            return [text]
        }
    }
#endif
