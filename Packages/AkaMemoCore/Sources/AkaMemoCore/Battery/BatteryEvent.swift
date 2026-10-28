import Foundation

public enum BatteryEventKind: String, Codable, Sendable, Equatable {
    case snapshot
    case alert5
    case alert3
    case reset
}

public enum BatteryChargeState: String, Codable, Sendable, Equatable {
    case unknown
    case unplugged
    case charging
    case full
}

/// Watch -> iPhone battery snapshot or alert. Carries only level/state, never
/// audio, transcripts, or location.
public struct BatteryEvent: Codable, Sendable, Equatable, Identifiable {
    public static let metadataKey = "akamemo.battery"
    public static let defaultAlertTTLMs: Int64 = 5 * 60 * 1_000
    public static let defaultSnapshotTTLMs: Int64 = 10 * 60 * 1_000

    public var id: UUID { eventID }
    public let kind: BatteryEventKind
    public let eventID: UUID
    public let sessionID: UUID?
    public let stateVersion: Int64
    public let batteryLevel: Double
    public let batteryState: BatteryChargeState
    public let recordingState: String
    public let alertLevel: Int?
    public let recordedAtMs: Int64
    public let ttlMs: Int64

    public init(
        kind: BatteryEventKind,
        eventID: UUID = UUID(),
        sessionID: UUID?,
        stateVersion: Int64,
        batteryLevel: Double,
        batteryState: BatteryChargeState,
        recordingState: String,
        alertLevel: Int? = nil,
        recordedAtMs: Int64,
        ttlMs: Int64
    ) {
        self.kind = kind
        self.eventID = eventID
        self.sessionID = sessionID
        self.stateVersion = stateVersion
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.recordingState = recordingState
        self.alertLevel = alertLevel
        self.recordedAtMs = recordedAtMs
        self.ttlMs = ttlMs
    }

    public func isExpired(nowMs: Int64) -> Bool {
        nowMs - recordedAtMs > ttlMs
    }

    public var isCharging: Bool {
        batteryState == .charging || batteryState == .full
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw BatteryEventError.invalidEncoding
        }
        return string
    }

    public static func decode(fromJSON string: String) throws -> BatteryEvent {
        guard let data = string.data(using: .utf8) else {
            throw BatteryEventError.invalidEncoding
        }
        return try JSONDecoder().decode(BatteryEvent.self, from: data)
    }
}

public enum BatteryEventError: Error, Equatable, Sendable {
    case invalidEncoding
}
