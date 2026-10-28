import Foundation
import SwiftData

/// The iPhone-side metadata record for a verified chunk.
@Model
final class ReceivedChunkRecord {
    var chunkID: UUID
    var sessionID: UUID
    var sessionStartedAt: Date
    var sequence: Int
    var startedAt: Date
    var durationMs: Int
    var byteSize: Int
    var checksumSHA256: String
    var formatVersion: Int
    var sampleRate: Int
    var channels: Int
    var bitRate: Int
    var relativePath: String
    var receivedAt: Date

    init(
        chunkID: UUID,
        sessionID: UUID,
        sessionStartedAt: Date,
        sequence: Int,
        startedAt: Date,
        durationMs: Int,
        byteSize: Int,
        checksumSHA256: String,
        formatVersion: Int,
        sampleRate: Int,
        channels: Int,
        bitRate: Int,
        relativePath: String,
        receivedAt: Date
    ) {
        self.chunkID = chunkID
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
        self.receivedAt = receivedAt
    }
}
