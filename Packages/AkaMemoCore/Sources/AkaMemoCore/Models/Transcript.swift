import Foundation

public enum TranscriptStatus: String, Codable, Sendable {
    case pending
    case ready
    case failed
}

public struct Transcript: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let chunkID: UUID
    public let providerID: String
    public let providerVersion: String
    public let language: String
    public var text: String
    public var status: TranscriptStatus
    public var errorCode: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        chunkID: UUID,
        providerID: String,
        providerVersion: String,
        language: String,
        text: String,
        status: TranscriptStatus = .pending,
        errorCode: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.chunkID = chunkID
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.language = language
        self.text = text
        self.status = status
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let transcriptID: UUID
    public let chunkID: UUID
    public let sessionID: UUID
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let confidence: Double?
    public let isFinal: Bool

    public init(
        id: UUID = UUID(),
        transcriptID: UUID,
        chunkID: UUID,
        sessionID: UUID,
        startMs: Int64,
        endMs: Int64,
        text: String,
        confidence: Double? = nil,
        isFinal: Bool = true
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
    }
}
