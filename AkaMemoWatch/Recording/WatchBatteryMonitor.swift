import AkaMemoCore
import Foundation
import OSLog

protocol BatteryEventTransport: AnyObject, Sendable {
    func sendBatteryEvent(_ event: BatteryEvent) -> Bool
}

struct BatteryEvaluation: Sendable, Equatable {
    var band: BatteryBand?
    var shouldStopRecording = false
    var shouldPlayAlertHaptic = false
}

/// Applies the battery policy on the Watch and emits sanitized snapshots and
/// alerts. Snapshots are throttled; alerts are latched once per discharge.
actor WatchBatteryMonitor {
    private let transport: (any BatteryEventTransport)?
    private let policy: BatteryPolicy
    private var state = BatteryAlertState()
    private var lastEvaluationMs: Int64 = 0
    private var lastBatteryState: BatteryChargeState = .unknown
    private var lastRecordingState = "idle"
    private var lastSessionID: UUID?
    private var lastStateVersion: Int64 = -1
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "battery"
    )

    init(
        transport: (any BatteryEventTransport)?,
        policy: BatteryPolicy = .standard
    ) {
        self.transport = transport
        self.policy = policy
    }

    func evaluate(
        level: Double?,
        batteryState: BatteryChargeState,
        sessionID: UUID?,
        stateVersion: Int64,
        recordingState: String,
        now: Date = Date()
    ) async -> BatteryEvaluation {
        guard let level, let band = policy.band(for: level) else {
            return BatteryEvaluation(band: nil)
        }
        let nowMs = TimeMath.epochMs(now)
        let decision = state.update(
            level: level,
            nowMs: nowMs,
            policy: policy
        )
        var evaluation = BatteryEvaluation(band: band)

        if sessionID != nil {
            switch decision {
            case .sendLowBatteryAlert:
                send(
                    kind: .alert5,
                    level: level,
                    batteryState: batteryState,
                    sessionID: sessionID,
                    stateVersion: stateVersion,
                    recordingState: recordingState,
                    alertLevel: 5,
                    ttlMs: BatteryEvent.defaultAlertTTLMs,
                    nowMs: nowMs
                )
                evaluation.shouldPlayAlertHaptic = true
            case .safeStop:
                send(
                    kind: .alert3,
                    level: level,
                    batteryState: batteryState,
                    sessionID: sessionID,
                    stateVersion: stateVersion,
                    recordingState: recordingState,
                    alertLevel: 3,
                    ttlMs: BatteryEvent.defaultAlertTTLMs,
                    nowMs: nowMs
                )
                evaluation.shouldStopRecording = true
                evaluation.shouldPlayAlertHaptic = true
            case .clearAlert:
                send(
                    kind: .reset,
                    level: level,
                    batteryState: batteryState,
                    sessionID: sessionID,
                    stateVersion: stateVersion,
                    recordingState: recordingState,
                    alertLevel: nil,
                    ttlMs: BatteryEvent.defaultAlertTTLMs,
                    nowMs: nowMs
                )
            case .none:
                break
            }
        }

        let stateChanged =
            batteryState != lastBatteryState
            || recordingState != lastRecordingState
            || sessionID != lastSessionID
            || stateVersion != lastStateVersion
        if stateChanged || nowMs - lastEvaluationMs >= 60_000
            || decision != .none
        {
            send(
                kind: .snapshot,
                level: level,
                batteryState: batteryState,
                sessionID: sessionID,
                stateVersion: stateVersion,
                recordingState: recordingState,
                alertLevel: nil,
                ttlMs: BatteryEvent.defaultSnapshotTTLMs,
                nowMs: nowMs
            )
        }

        lastEvaluationMs = nowMs
        lastBatteryState = batteryState
        lastRecordingState = recordingState
        lastSessionID = sessionID
        lastStateVersion = stateVersion
        return evaluation
    }

    private func send(
        kind: BatteryEventKind,
        level: Double,
        batteryState: BatteryChargeState,
        sessionID: UUID?,
        stateVersion: Int64,
        recordingState: String,
        alertLevel: Int?,
        ttlMs: Int64,
        nowMs: Int64
    ) {
        let event = BatteryEvent(
            kind: kind,
            sessionID: sessionID,
            stateVersion: stateVersion,
            batteryLevel: level,
            batteryState: batteryState,
            recordingState: recordingState,
            alertLevel: alertLevel,
            recordedAtMs: nowMs,
            ttlMs: ttlMs
        )
        if transport?.sendBatteryEvent(event) != true {
            logger.info(
                "battery event queued locally, kind \(kind.rawValue, privacy: .public)"
            )
        }
    }
}
