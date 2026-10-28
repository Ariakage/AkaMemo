import AkaMemoCore
import Foundation
import SwiftData

/// The iPhone-side transcript for one chunk and one engine version.
///
/// A failed attempt is stored as a `.failed` row so the UI can show the error
/// and offer a retry. A successful retry updates the same row instead of
/// creating a second one, which keeps `chunkID + providerID + providerVersion`
/// unique in practice.
@Model
final class TranscriptRecord {
    var transcriptID: UUID
    var chunkID: UUID
    var sessionID: UUID
    var providerID: String
    var providerVersion: String
    var language: String
    var text: String
    var statusRaw: String
    var errorCode: String?
    var createdAt: Date
    var updatedAt: Date

    var status: TranscriptStatus {
        get { TranscriptStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        transcriptID: UUID = UUID(),
        chunkID: UUID,
        sessionID: UUID,
        providerID: String,
        providerVersion: String,
        language: String,
        text: String,
        status: TranscriptStatus,
        errorCode: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.transcriptID = transcriptID
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.language = language
        self.text = text
        self.statusRaw = status.rawValue
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class TranscriptSegmentRecord {
    var segmentID: UUID
    var transcriptID: UUID
    var chunkID: UUID
    var sessionID: UUID
    var startMs: Int64
    var endMs: Int64
    var text: String
    var confidence: Double?
    var isFinal: Bool

    init(
        segmentID: UUID = UUID(),
        transcriptID: UUID,
        chunkID: UUID,
        sessionID: UUID,
        startMs: Int64,
        endMs: Int64,
        text: String,
        confidence: Double? = nil,
        isFinal: Bool = true
    ) {
        self.segmentID = segmentID
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

enum TranscriptionTaskState: String, Sendable {
    case queued
    case running
    case failed
    case ready
}

/// Persisted transcription queue entry. One row per chunk and engine version.
@Model
final class TranscriptionTaskRecord {
    var taskID: UUID
    var chunkID: UUID
    var sessionID: UUID
    var providerID: String
    var providerVersion: String
    var stateRaw: String
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date

    var state: TranscriptionTaskState {
        get { TranscriptionTaskState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    init(
        taskID: UUID = UUID(),
        chunkID: UUID,
        sessionID: UUID,
        providerID: String,
        providerVersion: String,
        state: TranscriptionTaskState = .queued,
        attemptCount: Int = 0,
        nextAttemptAt: Date = Date(),
        lastErrorCode: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.taskID = taskID
        self.chunkID = chunkID
        self.sessionID = sessionID
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.stateRaw = state.rawValue
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastErrorCode = lastErrorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
