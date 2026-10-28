import Foundation

enum RecordingEngineState: String, Sendable, Equatable {
    case idle
    case preparing
    case recording
    case paused
    case recovering
    case interrupted
    case finalizing
    case failed
}

enum RecordingEngineError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case audioSessionFailed(String)
    case recorderFailed(String)
    case storageUnavailable
    case chunkFinalizeFailed(String)
    case notRecording
}

struct RecordingSnapshot: Sendable, Equatable {
    var state: RecordingEngineState = .idle
    var sessionID: UUID?
    var sessionStartedAt: Date?
    var sessionEndedAt: Date?
    var currentSequence: Int?
    var sealedChunkCount: Int = 0
    var totalBytes: Int64 = 0
    var batteryLevel: Double?
    var error: RecordingEngineError?
    var totalGapMs: Int64 = 0
    var interruptionCount: Int = 0
    var stateVersion: Int64 = 0
    var lastAudioBufferAt: Date?
}

/// The on-disk heartbeat described by `docs/specs/recording-health.md` §3.1.
struct WatchHealthSnapshot: Codable, Sendable, Equatable {
    let sessionID: UUID
    let sessionStartedAtMs: Int64
    let endedAtMs: Int64?
    let lastAudioBufferAtMs: Int64?
    let lastHeartbeatAtMs: Int64
    let chunkSequence: Int?
    let bytesWritten: Int64
    let audioSessionActive: Bool
    let batteryLevel: Double?
    let state: String
    let stateVersion: Int64
    let totalGapMs: Int64
    let interruptionCount: Int
}
