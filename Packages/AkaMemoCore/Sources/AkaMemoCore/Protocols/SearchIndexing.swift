import Foundation

public enum SearchSort: String, Codable, Sendable, Equatable {
    case relevance
    case newest
}

public struct SearchQuery: Sendable, Codable, Equatable {
    public var text: String
    public var limit: Int
    public var startMs: Int64?
    public var endMs: Int64?
    public var sort: SearchSort

    public init(
        text: String,
        limit: Int = 50,
        startMs: Int64? = nil,
        endMs: Int64? = nil,
        sort: SearchSort = .relevance
    ) {
        self.text = text
        self.limit = limit
        self.startMs = startMs
        self.endMs = endMs
        self.sort = sort
    }
}

/// One searchable transcript segment. Only the active transcript version of a
/// chunk is indexed; re-indexing a chunk replaces all of its previous entries.
public struct SearchIndexEntry: Sendable, Codable, Equatable {
    public let segmentID: UUID
    public let chunkID: UUID
    public let sessionID: UUID
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let language: String
    public let providerVersion: String

    public init(
        segmentID: UUID,
        chunkID: UUID,
        sessionID: UUID,
        startMs: Int64,
        endMs: Int64,
        text: String,
        language: String,
        providerVersion: String
    ) {
        self.segmentID = segmentID
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.language = language
        self.providerVersion = providerVersion
    }
}

public struct SearchHit: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID { segmentID }
    public let segmentID: UUID
    public let chunkID: UUID
    public let sessionID: UUID
    public let startMs: Int64
    public let endMs: Int64
    public let snippet: String
    public let score: Double

    public init(
        segmentID: UUID,
        chunkID: UUID,
        sessionID: UUID,
        startMs: Int64,
        endMs: Int64,
        snippet: String,
        score: Double
    ) {
        self.segmentID = segmentID
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.startMs = startMs
        self.endMs = endMs
        self.snippet = snippet
        self.score = score
    }
}

/// Local full-text index. SwiftData remains the source of truth; the index can
/// always be rebuilt from it, and an index failure never rolls back transcripts.
public protocol SearchIndexing: Sendable {
    func replaceChunk(_ chunkID: UUID, with entries: [SearchIndexEntry]) async throws
    func replaceAll(_ entries: [SearchIndexEntry]) async throws
    func deleteChunk(_ chunkID: UUID) async throws
    func deleteSession(_ sessionID: UUID) async throws
    func search(_ query: SearchQuery) async throws -> [SearchHit]
    func entryCount() async throws -> Int
    func deleteAll() async throws
}
