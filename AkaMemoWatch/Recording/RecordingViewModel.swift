import Foundation
import Observation
import WatchKit

@MainActor
@Observable
final class RecordingViewModel {
    private let engine: RecordingEngine
    private(set) var snapshot = RecordingSnapshot()
    private(set) var now = Date()
    private(set) var batteryLevel: Double?

    init(engine: RecordingEngine = RecordingEngine()) {
        self.engine = engine
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

    func observe() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func refresh() async {
        let level = WKInterfaceDevice.current().batteryLevel
        let normalized: Double? = level >= 0 ? Double(level) : nil
        await engine.updateBatteryLevel(normalized)
        snapshot = await engine.currentSnapshot()
        batteryLevel = normalized
        now = Date()
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
