import AkaMemoCore
import Foundation
import OSLog

/// Keeps the FTS5 sidecar in step with SwiftData transcripts.
///
/// Index failures are logged and never roll back the transcript; the index can
/// be rebuilt from SwiftData at any time.
actor TranscriptIndexer {
    private let index: SQLiteSearchIndex
    private let diagnostics: AppDiagnostics?
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "storage"
    )

    init(
        index: SQLiteSearchIndex,
        diagnostics: AppDiagnostics? = nil
    ) {
        self.index = index
        self.diagnostics = diagnostics
    }

    func replaceChunk(_ chunkID: UUID, entries: [SearchIndexEntry]) async {
        do {
            try await index.replaceChunk(chunkID, with: entries)
        } catch {
            logger.error(
                "search index update failed: \(String(describing: error), privacy: .public)"
            )
            await diagnostics?.log(
                level: .warning,
                category: .storage,
                message: "search index update failed",
                metadata: ["errorCode": "indexWriteFailed"]
            )
        }
    }

    /// Builds the index from SwiftData when it is empty. Existing entries are
    /// left alone; `rebuild` is the explicit repair path.
    func ensureIndexed(store: TranscriptStore) async {
        do {
            if try await index.entryCount() > 0 {
                return
            }
            let entries = try await store.indexEntries()
            guard !entries.isEmpty else {
                return
            }
            try await index.replaceAll(entries)
            logger.info(
                "search index rebuilt with \(entries.count, privacy: .public) entries"
            )
            await diagnostics?.log(
                level: .info,
                category: .storage,
                message: "search index built",
                metadata: ["count": "\(entries.count)"]
            )
        } catch {
            logger.error(
                "search index rebuild failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    @discardableResult
    func rebuild(store: TranscriptStore) async -> Int {
        do {
            let entries = try await store.indexEntries()
            try await index.replaceAll(entries)
            logger.info(
                "search index repaired with \(entries.count, privacy: .public) entries"
            )
            return entries.count
        } catch {
            logger.error(
                "search index repair failed: \(String(describing: error), privacy: .public)"
            )
            return 0
        }
    }
}
