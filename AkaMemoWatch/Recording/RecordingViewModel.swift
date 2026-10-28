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
    private let locationRecorder: LocationRecorder
    private let healthPublisher: WatchHealthPublisher
    private let settings: WatchRecordingSettings
    private(set) var snapshot = RecordingSnapshot()
    private(set) var storageWarning: String?
    private var lastStorageCheckAt = Date.distantPast
    private var lastStorageBytes: Int64?
    private var previousStateForHaptic: RecordingEngineState?
    private(set) var batteryWarning: String?
    private(set) var batteryMonitoringUnavailable = false
    private(set) var locationStatus: LocationRecorder.Status = .idle
    private(set) var locationEnabled: Bool
    private(set) var locationPointCount = 0
    private(set) var now = Date()
    private(set) var batteryLevel: Double?
    private(set) var pendingRecovery: InterruptedSessionInfo?
    private(set) var resumeCountdownSeconds: Int?
    private(set) var recoveryNoticeSeconds: Int?
    private(set) var isForeground = true
    private var resumeCountdown = ResumeCountdown()
    private var countdownTask: Task<Void, Never>?
    private var resumeCountdownCancelled = false

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
            self.locationRecorder = LocationRecorder()
            self.healthPublisher = WatchHealthPublisher(transport: service)
            self.settings = WatchRecordingSettings()
            self.locationEnabled = self.locationRecorder.isEnabled
            Task {
                await handler.setStopSessionHandler {
                    [weak self] sessionID, epochMs in
                    await self?.stopIfDeleted(
                        sessionID: sessionID,
                        epochMs: epochMs
                    )
                }
            }
            Task {
                await handler.setStopLocationSessionHandler {
                    [weak self] sessionID in
                    await self?.stopLocationIfDeleted(sessionID: sessionID)
                }
            }
            service.setLocationSettingHandler { [weak self] setting in
                Task { @MainActor in
                    self?.applyRemoteLocationSetting(setting)
                }
            }
            service.activate()
        } catch {
            self.engine = RecordingEngine()
            self.connectivity = nil
            self.batteryMonitor = nil
            self.locationRecorder = LocationRecorder()
            self.healthPublisher = WatchHealthPublisher(transport: nil)
            self.settings = WatchRecordingSettings()
            self.locationEnabled = self.locationRecorder.isEnabled
        }
    }

    /// Stops only the location writer when the current session's track is
    /// deleted; audio recording continues.
    private func stopLocationIfDeleted(sessionID: UUID) async {
        await locationRecorder.cancelSession(matching: sessionID)
        syncLocationState()
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
        await engine.stop()
        await locationRecorder.cancelSession()
        await refresh()
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
                let upload = await locationRecorder.stopSession()
                sendTrackIfAvailable(upload)
                snapshot = await engine.currentSnapshot()
                batteryWarning = "battery.warning.3"
            }
        }
        locationRecorder.updateLowPowerMode(
            ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        syncLocationState()

        let referenceNow = Date()
        if referenceNow.timeIntervalSince(lastStorageCheckAt) >= 60 {
            lastStorageCheckAt = referenceNow
            lastStorageBytes = WatchStorage.availableBytes()
        }
        let storageBand = RecordingStoragePolicy.standard.band(
            forAvailableBytes: lastStorageBytes
        )
        switch storageBand {
        case .critical:
            storageWarning = "storage.warning.critical"
            if snapshot.state == .recording {
                await engine.stop()
                let upload = await locationRecorder.stopSession()
                sendTrackIfAvailable(upload)
                snapshot = await engine.currentSnapshot()
            }
        case .warning:
            storageWarning = "storage.warning.1gb"
        case .normal, .unknown:
            storageWarning = nil
        }

        let previousState = previousStateForHaptic
        if previousState == .recovering, snapshot.state == .recording {
            recoveryNoticeSeconds = Int(
                (Double(snapshot.totalGapMs) / 1000).rounded()
            )
            if !settings.silentResume {
                device.play(.success)
            }
        }
        if snapshot.state == .interrupted,
            previousState != .interrupted
        {
            device.play(.notification)
        }
        previousStateForHaptic = snapshot.state
        await publishHealth(now: referenceNow)
        now = referenceNow
    }

    private func publishHealth(now: Date) async {
        let event = RecordingHealthEvent(
            sessionID: snapshot.sessionID,
            stateVersion: snapshot.stateVersion,
            state: recordingStateName(snapshot.state),
            recordingStartedAtMs: snapshot.sessionStartedAt.map {
                TimeMath.epochMs($0)
            },
            recordedAtMs: TimeMath.epochMs(now),
            lastAudioBufferAtMs: snapshot.lastAudioBufferAt.map {
                TimeMath.epochMs($0)
            },
            chunkSequence: snapshot.currentSequence,
            bytesWritten: snapshot.totalBytes,
            batteryLevel: batteryLevel,
            storageAvailableBytes: lastStorageBytes,
            audioSessionActive: snapshot.state == .recording
                || snapshot.state == .recovering,
            locationEnabled: locationRecorder.isEnabled,
            locationAuthorization: locationRecorder.authorizationStatus,
            locationTrackBytes: locationRecorder.trackBytes,
            locationSettingUpdatedAtMs: locationRecorder.settingUpdatedAtMs
        )
        await healthPublisher.publish(event)
    }

    private func applyRemoteLocationSetting(_ setting: LocationSetting) {
        locationRecorder.apply(setting)
        syncLocationState()
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

    var autoResumeEnabled: Bool { settings.autoResume }
    var silentResumeEnabled: Bool { settings.silentResume }

    func setAutoResumeEnabled(_ enabled: Bool) {
        settings.setAutoResume(enabled)
        Task { await engine.setAutoRecoveryEnabled(enabled) }
        if enabled, pendingRecovery != nil {
            resumeCountdownCancelled = false
            if isForeground {
                beginResumeCountdown()
            }
        } else if !enabled {
            stopCountdown(keepPrompt: true)
        }
    }

    func setSilentResumeEnabled(_ enabled: Bool) {
        settings.setSilentResume(enabled)
    }

    /// The countdown may only run while the app is visible on screen.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            if pendingRecovery != nil, settings.autoResume,
                !resumeCountdownCancelled, !resumeCountdown.isActive
            {
                beginResumeCountdown()
            }
        } else {
            stopCountdown(keepPrompt: true)
        }
    }

    func start() async {
        guard pendingRecovery == nil else { return }
        await engine.setAutoRecoveryEnabled(settings.autoResume)
        recoveryNoticeSeconds = nil
        let storageBytes = WatchStorage.availableBytes()
        lastStorageBytes = storageBytes
        lastStorageCheckAt = Date()
        let storageBand = RecordingStoragePolicy.standard.band(
            forAvailableBytes: storageBytes
        )
        if storageBand == .critical {
            storageWarning = "storage.warning.critical"
            return
        }
        storageWarning = storageBand == .warning ? "storage.warning.1gb" : nil
        let device = WKInterfaceDevice.current()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        await engine.start(deviceModel: device.model, osVersion: osVersion)
        await refresh()
        if let sessionID = snapshot.sessionID,
            let startedAt = snapshot.sessionStartedAt
        {
            locationRecorder.start(
                sessionID: sessionID,
                sessionStartedAt: startedAt
            )
            syncLocationState()
        }
    }

    func stop() async {
        recoveryNoticeSeconds = nil
        await engine.stop()
        let upload = await locationRecorder.stopSession()
        sendTrackIfAvailable(upload)
        await refresh()
        syncLocationState()
    }

    func pause() async {
        await engine.pause()
        locationRecorder.pause()
        await refresh()
    }

    func resume() async {
        await engine.setAutoRecoveryEnabled(settings.autoResume)
        await engine.resume()
        locationRecorder.resume()
        await refresh()
    }

    /// Looks for a session left behind by a terminated process. Only called
    /// after `recoverPendingChunks()` has rebuilt the chunk index.
    func checkPendingRecovery() {
        guard pendingRecovery == nil,
            snapshot.state == .idle || snapshot.state == .failed
        else {
            return
        }
        guard let scanner = try? makeInterruptedScanner(),
            let info = scanner.scan()
        else {
            return
        }
        pendingRecovery = info
        resumeCountdownCancelled = false
        if settings.autoResume, isForeground {
            beginResumeCountdown()
        }
    }

    func cancelResumeCountdown() {
        resumeCountdownCancelled = true
        stopCountdown(keepPrompt: true)
    }

    /// Starts from the visible 3-second countdown or the manual resume button.
    func resumePendingSession() async {
        guard let info = pendingRecovery else { return }
        stopCountdown(keepPrompt: true)
        await engine.setAutoRecoveryEnabled(settings.autoResume)
        let started = await engine.resumePreviousSession(
            info,
            deviceModel: WKInterfaceDevice.current().model,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            autoRecoveryEnabled: settings.autoResume
        )
        if started {
            pendingRecovery = nil
            resumeCountdownCancelled = false
            locationRecorder.start(
                sessionID: info.sessionID,
                sessionStartedAt: TimeMath.date(
                    epochMs: info.sessionStartedAtMs
                ),
                continuingExisting: true
            )
            recoveryNoticeSeconds = Int(
                (Double(
                    info.recoveryGapMs(nowMs: TimeMath.epochMs(Date()))
                ) / 1000).rounded()
            )
            if !settings.silentResume {
                WKInterfaceDevice.current().play(.success)
            }
        }
        await refresh()
        syncLocationState()
    }

    /// Closes the leftover heartbeat without deleting any audio so the prompt
    /// does not return on the next launch.
    func ignorePendingRecovery() async {
        guard let info = pendingRecovery else { return }
        stopCountdown(keepPrompt: true)
        if let scanner = try? makeInterruptedScanner() {
            try? scanner.markCompleted(
                sessionID: info.sessionID,
                nowMs: TimeMath.epochMs(Date())
            )
        }
        resumeCountdownCancelled = false
        pendingRecovery = nil
        await refresh()
    }

    private func makeInterruptedScanner() throws -> InterruptedSessionScanner {
        InterruptedSessionScanner(
            audioRoot: try WatchPaths.audioRoot(),
            healthFileURL: try WatchPaths.healthFileURL()
        )
    }

    private func beginResumeCountdown() {
        guard pendingRecovery != nil, countdownTask == nil, isForeground else {
            return
        }
        resumeCountdown = ResumeCountdown()
        resumeCountdown.start()
        resumeCountdownSeconds = resumeCountdown.remainingSeconds
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.isForeground else {
                    self.stopCountdown(keepPrompt: true)
                    return
                }
                if self.resumeCountdown.advance() {
                    self.resumeCountdownSeconds = nil
                    self.countdownTask = nil
                    await self.resumePendingSession()
                    return
                }
                self.resumeCountdownSeconds =
                    self.resumeCountdown
                    .remainingSeconds
            }
        }
    }

    private func stopCountdown(keepPrompt: Bool) {
        countdownTask?.cancel()
        countdownTask = nil
        resumeCountdown.cancel()
        resumeCountdownSeconds = nil
        if !keepPrompt {
            pendingRecovery = nil
        }
    }

    func setLocationEnabled(_ enabled: Bool) {
        locationRecorder.setEnabled(enabled)
        locationEnabled = enabled
        syncLocationState()
    }

    private func syncLocationState() {
        locationStatus = locationRecorder.status
        locationEnabled = locationRecorder.isEnabled
        locationPointCount = locationRecorder.recordedPointCount
    }

    private func sendTrackIfAvailable(_ upload: LocationTrackUpload?) {
        guard let upload, let connectivity else {
            return
        }
        _ = connectivity.sendTrack(
            fileURL: upload.fileURL,
            envelope: upload.envelope
        )
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
