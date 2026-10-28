import Foundation

/// A combined heartbeat/battery/storage/recording snapshot. The Watch sends it
/// as `applicationContext` every 10 seconds and as an immediate event when the
/// recording state changes.
public struct RecordingHealthEvent: Codable, Sendable, Equatable, Identifiable {
    public static let metadataKey = "akamemo.health"
    public static let defaultTTLMs: Int64 = 120_000

    public var id: UUID { eventID }
    public let eventID: UUID
    public let sessionID: UUID?
    public let stateVersion: Int64
    public let state: String
    public let recordingStartedAtMs: Int64?
    public let recordedAtMs: Int64
    public let lastAudioBufferAtMs: Int64?
    public let chunkSequence: Int?
    public let bytesWritten: Int64
    public let batteryLevel: Double?
    public let storageAvailableBytes: Int64?
    public let audioSessionActive: Bool
    /// Location settings/status sent so the iPhone settings screen can show the
    /// Watch's effective state. Optional so older heartbeats still decode.
    public let locationEnabled: Bool?
    public let locationAuthorization: String?
    public let locationTrackBytes: Int64?
    public let locationSettingUpdatedAtMs: Int64?

    public init(
        eventID: UUID = UUID(),
        sessionID: UUID?,
        stateVersion: Int64,
        state: String,
        recordingStartedAtMs: Int64?,
        recordedAtMs: Int64,
        lastAudioBufferAtMs: Int64?,
        chunkSequence: Int?,
        bytesWritten: Int64,
        batteryLevel: Double?,
        storageAvailableBytes: Int64?,
        audioSessionActive: Bool,
        locationEnabled: Bool? = nil,
        locationAuthorization: String? = nil,
        locationTrackBytes: Int64? = nil,
        locationSettingUpdatedAtMs: Int64? = nil
    ) {
        self.eventID = eventID
        self.sessionID = sessionID
        self.stateVersion = stateVersion
        self.state = state
        self.recordingStartedAtMs = recordingStartedAtMs
        self.recordedAtMs = recordedAtMs
        self.lastAudioBufferAtMs = lastAudioBufferAtMs
        self.chunkSequence = chunkSequence
        self.bytesWritten = bytesWritten
        self.batteryLevel = batteryLevel
        self.storageAvailableBytes = storageAvailableBytes
        self.audioSessionActive = audioSessionActive
        self.locationEnabled = locationEnabled
        self.locationAuthorization = locationAuthorization
        self.locationTrackBytes = locationTrackBytes
        self.locationSettingUpdatedAtMs = locationSettingUpdatedAtMs
    }

    public var isRecording: Bool {
        state == "recording"
    }

    public func isExpired(
        nowMs: Int64,
        ttlMs: Int64 = RecordingHealthEvent.defaultTTLMs
    ) -> Bool {
        nowMs - recordedAtMs > ttlMs
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RecordingHealthEventError.invalidEncoding
        }
        return string
    }

    public static func decode(
        fromJSON string: String
    ) throws -> RecordingHealthEvent {
        guard let data = string.data(using: .utf8) else {
            throw RecordingHealthEventError.invalidEncoding
        }
        return try JSONDecoder().decode(RecordingHealthEvent.self, from: data)
    }
}

public enum RecordingHealthEventError: Error, Equatable, Sendable {
    case invalidEncoding
}
