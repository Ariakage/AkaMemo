import Foundation

public enum TombstoneEntityType: String, Codable, Sendable {
    case session
    case chunk
    case audio
    case transcript
    case location
}

/// A durable marker that prevents deleted entities from being re-imported.
public struct DeletionTombstone: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let entityType: TombstoneEntityType
    public let entityID: UUID
    public let sessionID: UUID?
    public let deletedAt: Date
    public let source: String
    public var acknowledgedAt: Date?
    public var expiresAt: Date?
    public let reason: String?

    public init(
        id: UUID = UUID(),
        entityType: TombstoneEntityType,
        entityID: UUID,
        sessionID: UUID? = nil,
        deletedAt: Date = Date(),
        source: String = "iphone",
        acknowledgedAt: Date? = nil,
        expiresAt: Date? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.sessionID = sessionID
        self.deletedAt = deletedAt
        self.source = source
        self.acknowledgedAt = acknowledgedAt
        self.expiresAt = expiresAt
        self.reason = reason
    }
}

/// A global deletion boundary used by "delete all data".
public struct DataEpoch: Identifiable, Codable, Sendable, Equatable {
    public var id: Int64 { epoch }
    public let epoch: Int64
    public let createdAt: Date
    public let source: String
    public var watchAckAt: Date?

    public init(
        epoch: Int64,
        createdAt: Date = Date(),
        source: String = "iphone",
        watchAckAt: Date? = nil
    ) {
        self.epoch = epoch
        self.createdAt = createdAt
        self.source = source
        self.watchAckAt = watchAckAt
    }
}
