import Foundation

public enum BatteryBand: String, Codable, Sendable, Equatable {
    case normal
    case advisory
    case low
    case critical
    case shutdown
}

/// Battery thresholds from `docs/specs/battery-alerting.md`.
///
/// Values are fractions between 0 and 1, matching the watch battery level.
public struct BatteryPolicy: Sendable, Equatable {
    public static let standard = BatteryPolicy()

    public let advisoryLevel: Double
    public let lowLevel: Double
    public let criticalAlertLevel: Double
    public let criticalStopLevel: Double
    public let alertResetLevel: Double

    public init(
        advisoryLevel: Double = 0.20,
        lowLevel: Double = 0.10,
        criticalAlertLevel: Double = 0.05,
        criticalStopLevel: Double = 0.03,
        alertResetLevel: Double = 0.10
    ) {
        self.advisoryLevel = advisoryLevel
        self.lowLevel = lowLevel
        self.criticalAlertLevel = criticalAlertLevel
        self.criticalStopLevel = criticalStopLevel
        self.alertResetLevel = alertResetLevel
    }

    public func band(for level: Double) -> BatteryBand? {
        guard level.isFinite, (0...1).contains(level) else {
            return nil
        }
        if level <= criticalStopLevel {
            return .shutdown
        }
        if level <= criticalAlertLevel {
            return .critical
        }
        if level <= lowLevel {
            return .low
        }
        if level <= advisoryLevel {
            return .advisory
        }
        return .normal
    }
}

/// Latches the 5% alert and the 3% safe stop for one recording session.
///
/// The alert is sent once per discharge; charging above 10% clears the latch,
/// but never resumes a session that was stopped at 3%.
public struct BatteryAlertState: Codable, Sendable, Equatable {
    public static let lowBatteryStopReason = "lowBattery3Percent"

    public enum Decision: String, Codable, Sendable, Equatable {
        case none
        case sendLowBatteryAlert
        case safeStop
        case clearAlert
    }

    public var lastKnownLevel: Double?
    public var lowBatteryAlertSentAtMs: Int64?
    public var autoPauseReason: String?

    public init(
        lastKnownLevel: Double? = nil,
        lowBatteryAlertSentAtMs: Int64? = nil,
        autoPauseReason: String? = nil
    ) {
        self.lastKnownLevel = lastKnownLevel
        self.lowBatteryAlertSentAtMs = lowBatteryAlertSentAtMs
        self.autoPauseReason = autoPauseReason
    }

    public mutating func update(
        level: Double,
        nowMs: Int64,
        policy: BatteryPolicy = .standard
    ) -> Decision {
        guard let band = policy.band(for: level) else {
            return .none
        }
        lastKnownLevel = level

        var didClearAlert = false
        if level > policy.alertResetLevel, lowBatteryAlertSentAtMs != nil {
            lowBatteryAlertSentAtMs = nil
            didClearAlert = true
        }

        guard autoPauseReason == nil else {
            return didClearAlert ? .clearAlert : .none
        }

        switch band {
        case .shutdown:
            autoPauseReason = Self.lowBatteryStopReason
            return .safeStop
        case .critical:
            guard lowBatteryAlertSentAtMs == nil else {
                return didClearAlert ? .clearAlert : .none
            }
            lowBatteryAlertSentAtMs = nowMs
            return .sendLowBatteryAlert
        default:
            return didClearAlert ? .clearAlert : .none
        }
    }
}
