import Foundation

/// The metadata sent alongside a chunk file over WatchConnectivity.
///
/// WatchConnectivity metadata must be property-list compatible, so the
/// envelope travels as a JSON string under `metadataKey`.
public struct ChunkTransferEnvelope: Codable, Sendable, Equatable {
    public static let metadataKey = "akamemo.chunk"

    public let chunkID: UUID
    public let sessionID: UUID
    public let sessionStartedAtMs: Int64
    public let sequence: Int
    public let startedAtMs: Int64
    public let durationMs: Int
    public let byteSize: Int
    public let checksumSHA256: String
    public let formatVersion: Int
    public let sampleRate: Int
    public let channels: Int
    public let bitRate: Int
    public let relativePath: String

    public init(
        chunkID: UUID,
        sessionID: UUID,
        sessionStartedAtMs: Int64,
        sequence: Int,
        startedAtMs: Int64,
        durationMs: Int,
        byteSize: Int,
        checksumSHA256: String,
        formatVersion: Int,
        sampleRate: Int,
        channels: Int,
        bitRate: Int,
        relativePath: String
    ) {
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.sessionStartedAtMs = sessionStartedAtMs
        self.sequence = sequence
        self.startedAtMs = startedAtMs
        self.durationMs = durationMs
        self.byteSize = byteSize
        self.checksumSHA256 = checksumSHA256
        self.formatVersion = formatVersion
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
        self.relativePath = relativePath
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ChunkTransferEnvelopeError.invalidEncoding
        }
        return string
    }

    public static func decode(fromJSON string: String) throws -> ChunkTransferEnvelope {
        guard let data = string.data(using: .utf8) else {
            throw ChunkTransferEnvelopeError.invalidEncoding
        }
        return try JSONDecoder().decode(ChunkTransferEnvelope.self, from: data)
    }
}

public enum ChunkTransferEnvelopeError: Error, Equatable, Sendable {
    case invalidEncoding
}

public enum TransferRetryPolicy {
    /// 5 秒、30 秒、2 分钟、10 分钟，之后按 1 小时上限重试。
    public static let delays: [TimeInterval] = [5, 30, 120, 600, 3_600]
    public static let acknowledgementTimeout: TimeInterval = 10 * 60

    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard !delays.isEmpty else {
            return 60
        }
        let index = min(max(attempt - 1, 0), delays.count - 1)
        return delays[index]
    }

    public static func nextAttemptAtMs(attempt: Int, nowMs: Int64) -> Int64 {
        nowMs + Int64((delay(forAttempt: attempt) * 1000).rounded())
    }

    public static func acknowledgementDeadlineMs(nowMs: Int64) -> Int64 {
        nowMs + Int64((acknowledgementTimeout * 1000).rounded())
    }
}
