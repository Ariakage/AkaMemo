import Foundation

public enum DeletionScope: String, Codable, Sendable, Equatable {
    case chunk
    case session
    case all
}

/// A deletion instruction sent from iPhone to Watch.
///
/// `tombstoneID` is also the acknowledgement key. `entityID` is the chunk or
/// session being deleted; `epochMs` is set only for `scope == .all`.
public struct DeletionCommand: Codable, Sendable, Equatable, Identifiable {
    public static let metadataKey = "akamemo.deletion"

    public var id: UUID { tombstoneID }
    public let tombstoneID: UUID
    public let scope: DeletionScope
    public let entityID: UUID?
    public let sessionID: UUID?
    public let epochMs: Int64?
    public let deletedAtMs: Int64

    public init(
        tombstoneID: UUID = UUID(),
        scope: DeletionScope,
        entityID: UUID? = nil,
        sessionID: UUID? = nil,
        epochMs: Int64? = nil,
        deletedAtMs: Int64
    ) {
        self.tombstoneID = tombstoneID
        self.scope = scope
        self.entityID = entityID
        self.sessionID = sessionID
        self.epochMs = epochMs
        self.deletedAtMs = deletedAtMs
    }

    public var isValid: Bool {
        switch scope {
        case .chunk:
            return entityID != nil
        case .session:
            return entityID != nil
        case .all:
            return epochMs != nil
        }
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DeletionCommandError.invalidEncoding
        }
        return string
    }

    public static func decode(fromJSON string: String) throws -> DeletionCommand {
        guard let data = string.data(using: .utf8) else {
            throw DeletionCommandError.invalidEncoding
        }
        return try JSONDecoder().decode(DeletionCommand.self, from: data)
    }
}

public enum DeletionCommandError: Error, Equatable, Sendable {
    case invalidEncoding
}

public struct DeletionAcknowledgement: Codable, Sendable, Equatable {
    public let tombstoneID: UUID
    public let appliedAtMs: Int64

    public init(tombstoneID: UUID, appliedAtMs: Int64) {
        self.tombstoneID = tombstoneID
        self.appliedAtMs = appliedAtMs
    }
}
