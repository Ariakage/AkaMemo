import Foundation

public struct SearchQuery: Sendable, Codable, Equatable {
    public var text: String
    public var limit: Int
    public var startMs: Int64?
    public var endMs: Int64?

    public init(
        text: String,
        limit: Int = 50,
        startMs: Int64? = nil,
        endMs: Int64? = nil
    ) {
        self.text = text
        self.limit = limit
        self.startMs = startMs
        self.endMs = endMs
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

public protocol SearchIndexing: Sendable {
    func index(_ segments: [TranscriptSegment], in chunk: AudioChunk) async throws
    func search(_ query: SearchQuery) async throws -> [SearchHit]
    func removeChunk(id: UUID) async throws
}
