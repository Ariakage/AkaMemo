import Foundation
import SwiftData

/// Durable record that prevents a deleted chunk or session from being
/// re-imported. Kept until the Watch acknowledges it (plus a grace period).
@Model
final class DeletionTombstoneRecord {
    var tombstoneID: UUID
    var entityTypeRaw: String
    var entityID: UUID
    var sessionID: UUID?
    var deletedAt: Date
    var source: String
    var acknowledgedAt: Date?
    var expiresAt: Date?
    var reason: String?

    init(
        tombstoneID: UUID = UUID(),
        entityTypeRaw: String,
        entityID: UUID,
        sessionID: UUID? = nil,
        deletedAt: Date,
        source: String = "iphone",
        acknowledgedAt: Date? = nil,
        expiresAt: Date? = nil,
        reason: String? = nil
    ) {
        self.tombstoneID = tombstoneID
        self.entityTypeRaw = entityTypeRaw
        self.entityID = entityID
        self.sessionID = sessionID
        self.deletedAt = deletedAt
        self.source = source
        self.acknowledgedAt = acknowledgedAt
        self.expiresAt = expiresAt
        self.reason = reason
    }
}

/// The "delete all data" boundary. Stored separately so the epoch survives
/// even after every tombstone row has been cleaned up.
@Model
final class DataEpochRecord {
    var tombstoneID: UUID
    var epochMs: Int64
    var createdAt: Date
    var source: String
    var watchAckAt: Date?

    init(
        tombstoneID: UUID = UUID(),
        epochMs: Int64,
        createdAt: Date,
        source: String = "iphone",
        watchAckAt: Date? = nil
    ) {
        self.tombstoneID = tombstoneID
        self.epochMs = epochMs
        self.createdAt = createdAt
        self.source = source
        self.watchAckAt = watchAckAt
    }
}
