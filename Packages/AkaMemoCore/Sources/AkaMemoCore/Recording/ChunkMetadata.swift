import Foundation

/// The JSON sidecar written next to every sealed audio chunk.
///
/// The sidecar is a compatibility contract: every field required by
/// `docs/specs/recording.md` §5.2 is present and timestamps are UTC
/// milliseconds so they are stable across time zones.
public struct ChunkMetadataSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public enum ValidationIssue: String, Codable, Sendable, Equatable {
        case invalidSequence
        case nonPositiveDuration
        case byteSizeMismatch
        case checksumMismatch
    }

    public let schemaVersion: Int
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
    public let createdAtMs: Int64

    public init(
        schemaVersion: Int = ChunkMetadataSnapshot.currentSchemaVersion,
        chunkID: UUID,
        sessionID: UUID,
        sessionStartedAtMs: Int64,
        sequence: Int,
        startedAtMs: Int64,
        durationMs: Int,
        byteSize: Int,
        checksumSHA256: String,
        formatVersion: Int = RecordingConfiguration.audioFormatVersion,
        sampleRate: Int = RecordingConfiguration.sampleRate,
        channels: Int = RecordingConfiguration.defaultChannelCount,
        bitRate: Int = RecordingConfiguration.bitRatePerChannel,
        relativePath: String,
        createdAtMs: Int64
    ) {
        self.schemaVersion = schemaVersion
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
        self.createdAtMs = createdAtMs
    }

    /// Returns every integrity problem found when comparing the sidecar with
    /// the sealed audio file. An empty array means the metadata is usable.
    public func validationIssues(
        fileByteSize: Int,
        checksumSHA256: String
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if sequence < 0 {
            issues.append(.invalidSequence)
        }
        if durationMs <= 0 {
            issues.append(.nonPositiveDuration)
        }
        if byteSize != fileByteSize {
            issues.append(.byteSizeMismatch)
        }
        if self.checksumSHA256.caseInsensitiveCompare(checksumSHA256) != .orderedSame {
            issues.append(.checksumMismatch)
        }
        return issues
    }
}
