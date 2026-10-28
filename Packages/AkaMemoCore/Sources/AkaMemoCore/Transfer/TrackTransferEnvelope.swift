import Foundation

/// Metadata sent with a Watch track file. The file itself stays JSONL; the
/// envelope only carries identifiers, counts, and a checksum.
public struct TrackTransferEnvelope: Codable, Sendable, Equatable {
    public static let metadataKey = "akamemo.track"

    public let trackID: UUID
    public let sessionID: UUID
    public let sessionStartedAtMs: Int64
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let pointCount: Int
    public let checksumSHA256: String
    public let relativePath: String

    public init(
        trackID: UUID,
        sessionID: UUID,
        sessionStartedAtMs: Int64,
        startedAtMs: Int64,
        endedAtMs: Int64,
        pointCount: Int,
        checksumSHA256: String,
        relativePath: String
    ) {
        self.trackID = trackID
        self.sessionID = sessionID
        self.sessionStartedAtMs = sessionStartedAtMs
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.pointCount = pointCount
        self.checksumSHA256 = checksumSHA256
        self.relativePath = relativePath
    }

    public var isValid: Bool {
        pointCount > 0
            && sessionStartedAtMs > 0
            && startedAtMs > 0
            && endedAtMs >= startedAtMs
            && checksumSHA256.count == 64
            && checksumSHA256.allSatisfy { $0.isHexDigit }
            && relativePath.hasPrefix("location/")
            && !relativePath.contains("..")
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw TrackTransferEnvelopeError.invalidEncoding
        }
        return string
    }

    public static func decode(
        fromJSON string: String
    ) throws -> TrackTransferEnvelope {
        guard let data = string.data(using: .utf8) else {
            throw TrackTransferEnvelopeError.invalidEncoding
        }
        return try JSONDecoder().decode(TrackTransferEnvelope.self, from: data)
    }
}

public enum TrackTransferEnvelopeError: Error, Equatable, Sendable {
    case invalidEncoding
}
