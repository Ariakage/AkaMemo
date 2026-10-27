import Foundation

/// The physical, independently finalized unit of audio.
public struct AudioChunk: Identifiable, Codable, Sendable, Equatable {
    public enum TransferState: String, Codable, Sendable {
        case localOnly
        case queued
        case transferring
        case received
        case verified
        case confirmed
        case failed
        case corrupt
    }

    public enum ProcessingState: String, Codable, Sendable {
        case pending
        case transcribing
        case transcribed
        case indexed
        case skipped
        case failed
    }

    public enum LocalState: String, Codable, Sendable {
        case present
        case reclaimed
        case deleted
        case audioPurged
        case missing
    }

    public let id: UUID
    public let sessionID: UUID
    public let sessionStartedAt: Date
    public let sequence: Int
    public let startedAt: Date
    public var durationMs: Int
    public var byteSize: Int
    public var checksumSHA256: String
    public var formatVersion: Int
    public var sampleRate: Int
    public var channels: Int
    public var bitRate: Int
    public var relativePath: String
    public var transferState: TransferState
    public var processingState: ProcessingState
    public var activeTranscriptID: UUID?
    public var receivedAt: Date?
    public var confirmedAt: Date?
    public var deletedAt: Date?
    public var audioPurgedAt: Date?
    public var localState: LocalState
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sessionStartedAt: Date,
        sequence: Int,
        startedAt: Date,
        durationMs: Int = 0,
        byteSize: Int = 0,
        checksumSHA256: String = "",
        formatVersion: Int = 1,
        sampleRate: Int = 44_100,
        channels: Int = 2,
        bitRate: Int = 96_000,
        relativePath: String = "",
        transferState: TransferState = .localOnly,
        processingState: ProcessingState = .pending,
        activeTranscriptID: UUID? = nil,
        receivedAt: Date? = nil,
        confirmedAt: Date? = nil,
        deletedAt: Date? = nil,
        audioPurgedAt: Date? = nil,
        localState: LocalState = .present,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.sequence = sequence
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.byteSize = byteSize
        self.checksumSHA256 = checksumSHA256
        self.formatVersion = formatVersion
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
        self.relativePath = relativePath
        self.transferState = transferState
        self.processingState = processingState
        self.activeTranscriptID = activeTranscriptID
        self.receivedAt = receivedAt
        self.confirmedAt = confirmedAt
        self.deletedAt = deletedAt
        self.audioPurgedAt = audioPurgedAt
        self.localState = localState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
