import Foundation

/// A single user-initiated recording session.
public struct RecordingSession: Identifiable, Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case recording
        case paused
        case interrupted
        case recovering
        case finalizing
        case completed
        case failed
    }

    public let id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var state: State
    public var sourceDeviceModel: String?
    public var sourceOSVersion: String?
    public var timeZoneIdentifier: String
    public var lastKnownBatteryLevel: Double?
    public var lowBatteryAlertSentAt: Date?
    public var autoPauseReason: String?
    public var lastHeartbeatAt: Date?
    public var lastStateVersion: Int64?
    public var lastAudioBufferAt: Date?
    public var interruptionCount: Int
    public var autoRecoveryEnabled: Bool
    public var recoveryAttemptCount: Int
    public var lastRecoveryAt: Date?
    public var totalGapMs: Int64
    public var corruptSegmentCount: Int
    public var recoveredSegmentCount: Int
    public var integrityState: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        state: State = .recording,
        sourceDeviceModel: String? = nil,
        sourceOSVersion: String? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        lastKnownBatteryLevel: Double? = nil,
        lowBatteryAlertSentAt: Date? = nil,
        autoPauseReason: String? = nil,
        lastHeartbeatAt: Date? = nil,
        lastStateVersion: Int64? = nil,
        lastAudioBufferAt: Date? = nil,
        interruptionCount: Int = 0,
        autoRecoveryEnabled: Bool = true,
        recoveryAttemptCount: Int = 0,
        lastRecoveryAt: Date? = nil,
        totalGapMs: Int64 = 0,
        corruptSegmentCount: Int = 0,
        recoveredSegmentCount: Int = 0,
        integrityState: String = "healthy",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.sourceDeviceModel = sourceDeviceModel
        self.sourceOSVersion = sourceOSVersion
        self.timeZoneIdentifier = timeZoneIdentifier
        self.lastKnownBatteryLevel = lastKnownBatteryLevel
        self.lowBatteryAlertSentAt = lowBatteryAlertSentAt
        self.autoPauseReason = autoPauseReason
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastStateVersion = lastStateVersion
        self.lastAudioBufferAt = lastAudioBufferAt
        self.interruptionCount = interruptionCount
        self.autoRecoveryEnabled = autoRecoveryEnabled
        self.recoveryAttemptCount = recoveryAttemptCount
        self.lastRecoveryAt = lastRecoveryAt
        self.totalGapMs = totalGapMs
        self.corruptSegmentCount = corruptSegmentCount
        self.recoveredSegmentCount = recoveredSegmentCount
        self.integrityState = integrityState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
