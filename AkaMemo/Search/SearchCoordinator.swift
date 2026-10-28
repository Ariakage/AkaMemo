import AkaMemoCore
import Foundation
import Observation

/// Exposes the local search index to SwiftUI. Queries and snippet text never
/// leave the device and are never logged.
@MainActor
@Observable
final class SearchCoordinator {
    private let index: SQLiteSearchIndex?
    private let indexer: TranscriptIndexer?
    private let store: TranscriptStore?
    private(set) var isPreparing = false
    private(set) var indexUnavailable = false

    var isAvailable: Bool {
        index != nil
    }

    init(
        index: SQLiteSearchIndex?,
        indexer: TranscriptIndexer?,
        store: TranscriptStore?
    ) {
        self.index = index
        self.indexer = indexer
        self.store = store
    }

    func prepare() async {
        guard let indexer, let store, !isPreparing else {
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        await indexer.ensureIndexed(store: store)
    }

    func search(_ query: SearchQuery) async -> [SearchHit] {
        guard let index else {
            return []
        }
        do {
            let hits = try await index.search(query)
            indexUnavailable = false
            return hits
        } catch {
            indexUnavailable = true
            return []
        }
    }
}
