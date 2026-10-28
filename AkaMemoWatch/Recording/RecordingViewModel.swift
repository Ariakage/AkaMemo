import AkaMemoCore
import Foundation
import Observation
import WatchKit

@MainActor
@Observable
final class RecordingViewModel {
    private let engine: RecordingEngine
    private let connectivity: WatchConnectivityService?
    private let batteryMonitor: WatchBatteryMonitor?
    private(set) var snapshot = RecordingSnapshot()
    private(set) var batteryWarning: String?
    private(set) var batteryMonitoringUnavailable = false
    private(set) var now = Date()
    private(set) var batteryLevel: Double?

    init() {
        do {
            let root = try WatchPaths.applicationSupport()
            let deletionStore = WatchDeletionStore(appSupportRoot: root)
            let queue = WatchTransferQueue(
                appSupportRoot: root,
                deletionStore: deletionStore
            )
            let handler = WatchDeletionHandler(
                appSupportRoot: root,
                deletionStore: deletionStore,
                queue: queue
            )
            let service = WatchConnectivityService(
                queue: queue,
                deletionHandler: handler
            )
            self.engine = RecordingEngine(transferQueue: queue)
            self.connectivity = service
            self.batteryMonitor = WatchBatteryMonitor(transport: service)
            Task {
                await handler.setStopSessionHandler {
                    [weak self] sessionID, epochMs in
                    await self?.stopIfDeleted(
                        sessionID: sessionID,
                        epochMs: epochMs
                    )
                }
            }
            service.activate()
        } catch {
            self.engine = RecordingEngine()
            self.connectivity = nil
            self.batteryMonitor = nil
        }
    }

    /// Stops the recorder only when the deleted session is the one currently
    /// being recorded. A session started after the epoch keeps running.
    private func stopIfDeleted(sessionID: UUID?, epochMs: Int64?) async {
        guard let startedAt = snapshot.sessionStartedAt else {
            return
        }
        let isCurrentSession =
            sessionID != nil && sessionID == snapshot.sessionID
        let startedBeforeEpoch =
            epochMs.map { TimeMath.epochMs(startedAt) < $0 } ?? false
        guard isCurrentSession || startedBeforeEpoch else {
            return
        }
        await stop()
    }

    var elapsed: TimeInterval {
        guard let start = snapshot.sessionStartedAt else { return 0 }
        let reference = snapshot.sessionEndedAt ?? now
        return max(0, reference.timeIntervalSince(start))
    }

    var elapsedText: String {
        let milliseconds = Int64((elapsed * 1000).rounded())
        return Duration.milliseconds(milliseconds)
            .formatted(.time(pattern: .hourMinuteSecond))
    }

    var batteryText: String? {
        guard let batteryLevel, batteryLevel >= 0 else { return nil }
        return "\(Int((batteryLevel * 100).rounded()))%"
    }

    var stateKey: String {
        switch snapshot.state {
        case .idle:
            "recording.state.idle"
        case .preparing:
            "recording.state.preparing"
        case .recording:
            "recording.state.recording"
        case .paused:
            "recording.state.paused"
        case .recovering:
            "recording.state.recovering"
        case .interrupted:
            "recording.state.interrupted"
        case .finalizing:
            "recording.state.finalizing"
        case .failed:
            "recording.state.failed"
        }
    }

    var errorMessage: String? {
        guard let error = snapshot.error else { return nil }
        return Self.message(for: error)
    }

    func recoverPendingChunks() async {
        await engine.recoverPendingChunks()
        await refresh()
    }

    func observe() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func refresh() async {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let rawLevel = device.batteryLevel
        let normalized: Double? = rawLevel >= 0 ? Double(rawLevel) : nil
        await engine.updateBatteryLevel(normalized)
        snapshot = await engine.currentSnapshot()
        batteryLevel = normalized
        batteryMonitoringUnavailable = normalized == nil

        if let batteryMonitor {
            let evaluation = await batteryMonitor.evaluate(
                level: normalized,
                batteryState: chargeState(device.batteryState),
                sessionID: snapshot.sessionID,
                stateVersion: snapshot.stateVersion,
                recordingState: recordingStateName(snapshot.state),
                now: Date()
            )
            batteryWarning = warningKey(for: evaluation.band)
            if evaluation.shouldPlayAlertHaptic {
                device.play(.notification)
            }
            if evaluation.shouldStopRecording {
                await engine.stop()
                snapshot = await engine.currentSnapshot()
                batteryWarning = "battery.warning.3"
            }
        }
        now = Date()
    }

    private func chargeState(
        _ state: WKInterfaceDeviceBatteryState
    ) -> BatteryChargeState {
        switch state {
        case .charging: .charging
        case .full: .full
        case .unplugged: .unplugged
        default: .unknown
        }
    }

    private func recordingStateName(_ state: RecordingEngineState) -> String {
        switch state {
        case .idle: "idle"
        case .preparing: "preparing"
        case .recording: "recording"
        case .paused: "paused"
        case .recovering: "recovering"
        case .interrupted: "interrupted"
        case .finalizing: "finalizing"
        case .failed: "failed"
        }
    }

    private func warningKey(for band: BatteryBand?) -> String? {
        switch band {
        case .advisory: "battery.warning.20"
        case .low: "battery.warning.10"
        case .critical: "battery.warning.5"
        case .shutdown: "battery.warning.3"
        case .normal, .none: nil
        }
    }

    func start() async {
        let device = WKInterfaceDevice.current()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        await engine.start(deviceModel: device.model, osVersion: osVersion)
        await refresh()
    }

    func stop() async {
        await engine.stop()
        await refresh()
    }

    func pause() async {
        await engine.pause()
        await refresh()
    }

    func resume() async {
        await engine.resume()
        await refresh()
    }

    private static func message(for error: RecordingEngineError) -> String {
        switch error {
        case .microphonePermissionDenied:
            String(localized: "recording.error.permission")
        case .audioSessionFailed, .recorderFailed:
            String(localized: "recording.error.audio")
        case .storageUnavailable, .chunkFinalizeFailed:
            String(localized: "recording.error.storage")
        case .notRecording:
            String(localized: "recording.error.generic")
        }
    }
}
