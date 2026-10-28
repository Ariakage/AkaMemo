import AVFoundation
import AkaMemoCore
import Foundation
import OSLog

/// Foreground-startable watch recorder.
///
/// The engine owns the audio session, chunk rotation, atomic sealing and the
/// health heartbeat. It never starts the microphone from the background; the
/// UI can only call `start` or `resume` while the app is on screen.
actor RecordingEngine {
    private enum SealReason: String {
        case rotation
        case pause
        case stop
        case interruption
        case routeChange
        case recovery
    }

    private enum RecoveryReason: String {
        case watchdog
        case interruption
        case audioFailure
        case mediaServicesReset
    }

    private struct CurrentChunk {
        let id: UUID
        let sequence: Int
        let startedAt: Date
        let startedAtMs: Int64
        let partURL: URL
        let finalURL: URL
        var observedDuration: TimeInterval
    }

    private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "recording")
    private let fileManager = FileManager.default
    private let healthEvaluator = RecordingHealthEvaluator.standard
    private let chunkPolicy = ChunkPolicy.standard
    private let autoRecoveryEnabled = true

    private var state: RecordingEngineState = .idle
    private var session: RecordingSession?
    private var sessionDirectory: URL?
    private var manifest: ChunkManifest?
    private var manifestWriter: AtomicFileWriter?
    private var sidecarWriter: AtomicFileWriter?
    private var healthWriter: AtomicFileWriter?
    private var recorder: AVAudioRecorder?
    private var currentChunk: CurrentChunk?
    private var nextSequence = 0
    private var sealedChunkCount = 0
    private var totalBytes: Int64 = 0
    private var totalGapMs: Int64 = 0
    private var lastError: RecordingEngineError?
    private var currentChannelCount = RecordingConfiguration.defaultChannelCount
    private var lastAudioGrowthAt: Date?
    private var lastStateVersion: Int64?
    private var batteryLevel: Double?
    private var isAudioSessionActive = false
    private var recoveryGeneration = 0

    private var rotationTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var notificationTasks: [Task<Void, Never>] = []

    // MARK: - Public API

    func currentSnapshot() -> RecordingSnapshot {
        RecordingSnapshot(
            state: state,
            sessionID: session?.id,
            sessionStartedAt: session?.startedAt,
            sessionEndedAt: session?.endedAt,
            currentSequence: currentChunk?.sequence,
            sealedChunkCount: sealedChunkCount,
            totalBytes: totalBytes,
            batteryLevel: batteryLevel,
            error: lastError,
            totalGapMs: totalGapMs,
            interruptionCount: session?.interruptionCount ?? 0
        )
    }

    func updateBatteryLevel(_ level: Double?) {
        batteryLevel = level
    }

    /// Starts a new session. Must be called from a visible foreground screen.
    func start(deviceModel: String?, osVersion: String) async {
        guard state == .idle || state == .failed || state == .interrupted else {
            return
        }
        if state == .interrupted {
            await resume()
            return
        }

        state = .preparing
        lastError = nil
        do {
            guard await Self.requestMicrophonePermission() else {
                throw RecordingEngineError.microphonePermissionDenied
            }
            try activateAudioSession()

            let now = Date()
            var newSession = RecordingSession(
                startedAt: now,
                state: .recording,
                sourceDeviceModel: deviceModel,
                sourceOSVersion: osVersion,
                timeZoneIdentifier: TimeZone.current.identifier
            )
            newSession.lastHeartbeatAt = now
            newSession.autoRecoveryEnabled = autoRecoveryEnabled
            newSession.lastStateVersion = StateVersion.initial
            session = newSession
            lastStateVersion = StateVersion.initial
            nextSequence = 0
            sealedChunkCount = 0
            totalBytes = 0
            totalGapMs = 0
            currentChunk = nil

            let directory = try WatchPaths.sessionDirectory(id: newSession.id)
            sessionDirectory = directory
            manifest = ChunkManifest(
                sessionID: newSession.id,
                sessionStartedAtMs: TimeMath.epochMs(now)
            )
            let sessionWriter = AtomicFileWriter(directory: directory)
            manifestWriter = sessionWriter
            sidecarWriter = sessionWriter
            healthWriter = AtomicFileWriter(directory: try WatchPaths.applicationSupport())

            try await persistManifest()
            try startChunk(at: now)
            state = .recording
            startLoops()
            observeSystemNotifications()
            try? await writeHealthFile()
            logger.info("recording started")
        } catch {
            lastError = map(error)
            state = .failed
            deactivateAudioSession()
            logger.error("start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func pause() async {
        guard state == .recording else { return }
        recoveryGeneration += 1
        stopLoops()
        do {
            if currentChunk != nil {
                try await sealCurrentChunk(reason: .pause)
            }
            session?.state = .paused
            session?.integrityState = "healthy"
            deactivateAudioSession()
            state = .paused
            lastError = nil
            try? await writeHealthFile()
            logger.info("recording paused")
        } catch {
            lastError = map(error)
            state = .failed
            deactivateAudioSession()
            logger.error("pause failed: \(String(describing: error), privacy: .public)")
        }
    }

    func resume() async {
        guard state == .paused || state == .interrupted else { return }
        recoveryGeneration += 1
        let wasInterrupted = state == .interrupted
        do {
            guard await Self.requestMicrophonePermission() else {
                throw RecordingEngineError.microphonePermissionDenied
            }
            try activateAudioSession()
            let now = Date()
            if wasInterrupted, let lastAudioGrowthAt {
                let gap = now.timeIntervalSince(lastAudioGrowthAt)
                if gap > 0 {
                    totalGapMs += Int64((gap * 1000).rounded())
                }
            }
            try startChunk(at: now)
            session?.state = .recording
            session?.integrityState = wasInterrupted ? "recovered" : "healthy"
            session?.totalGapMs = totalGapMs
            if wasInterrupted {
                session?.lastRecoveryAt = now
            }
            state = .recording
            lastError = nil
            startLoops()
            observeSystemNotifications()
            try? await writeHealthFile()
            logger.info("recording resumed")
        } catch {
            lastError = map(error)
            state = .interrupted
            deactivateAudioSession()
            logger.error("resume failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() async {
        guard
            state == .recording || state == .paused || state == .interrupted
                || state == .recovering
        else {
            return
        }
        recoveryGeneration += 1
        stopLoops()
        state = .finalizing
        do {
            if currentChunk != nil {
                try await sealCurrentChunk(reason: .stop)
            }
            session?.endedAt = Date()
            session?.state = .completed
            deactivateAudioSession()
            state = .idle
            lastError = nil
            try? await writeHealthFile()
            logger.info("recording stopped")
        } catch {
            lastError = map(error)
            state = .failed
            deactivateAudioSession()
            logger.error("stop failed: \(String(describing: error), privacy: .public)")
        }
        stopNotificationObservers()
    }

    // MARK: - Chunks

    private func startChunk(at date: Date) throws {
        guard let directory = sessionDirectory else {
            throw RecordingEngineError.notRecording
        }
        let startedAtMs = TimeMath.epochMs(date)
        let audioName = ChunkPath.fileName(
            sequence: nextSequence,
            startEpochMs: startedAtMs,
            kind: .audio
        )
        let partURL = directory.appending(
            path: audioName + ChunkFileSuffix.part.rawValue
        )
        let finalURL = directory.appending(path: audioName)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(RecordingConfiguration.sampleRate),
            AVNumberOfChannelsKey: currentChannelCount,
            AVEncoderBitRatePerChannelKey: RecordingConfiguration.bitRatePerChannel,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: partURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingEngineError.recorderFailed("AVAudioRecorder.record() returned false")
        }
        applyInProgressFileProtection(at: partURL)

        self.recorder = recorder
        currentChunk = CurrentChunk(
            id: UUID(),
            sequence: nextSequence,
            startedAt: date,
            startedAtMs: startedAtMs,
            partURL: partURL,
            finalURL: finalURL,
            observedDuration: 0
        )
        nextSequence += 1
        lastAudioGrowthAt = date
        session?.lastAudioBufferAt = date
        logger.info("chunk \(self.nextSequence - 1, privacy: .public) started")
    }

    private func sealCurrentChunk(reason: SealReason) async throws {
        guard let chunk = currentChunk, let recorder else { return }
        currentChunk = nil
        self.recorder = nil
        let recordedDuration = recorder.currentTime
        recorder.stop()

        guard fileManager.fileExists(atPath: chunk.partURL.path) else {
            throw RecordingEngineError.chunkFinalizeFailed("chunk file missing")
        }
        let byteSize = fileSize(at: chunk.partURL)
        guard byteSize > 0 else {
            throw RecordingEngineError.chunkFinalizeFailed("empty chunk")
        }
        guard var currentSession = session, let sidecarWriter else {
            throw RecordingEngineError.notRecording
        }

        let data = try Data(contentsOf: chunk.partURL)
        let checksum = AtomicFileWriter.sha256Hex(data)
        let durationMs = max(1, Int((recordedDuration * 1000).rounded()))
        let metadata = ChunkMetadataSnapshot(
            chunkID: chunk.id,
            sessionID: currentSession.id,
            sessionStartedAtMs: TimeMath.epochMs(currentSession.startedAt),
            sequence: chunk.sequence,
            startedAtMs: chunk.startedAtMs,
            durationMs: durationMs,
            byteSize: byteSize,
            checksumSHA256: checksum,
            channels: currentChannelCount,
            relativePath:
                "audio/\(currentSession.id.uuidString)/\(chunk.finalURL.lastPathComponent)",
            createdAtMs: TimeMath.epochMs(Date())
        )
        let jsonName = ChunkPath.fileName(
            sequence: chunk.sequence,
            startEpochMs: chunk.startedAtMs,
            kind: .metadata
        )
        _ = try await sidecarWriter.writeJSON(metadata, fileName: jsonName)

        guard !fileManager.fileExists(atPath: chunk.finalURL.path) else {
            throw RecordingEngineError.chunkFinalizeFailed("destination already exists")
        }
        try fileManager.moveItem(at: chunk.partURL, to: chunk.finalURL)
        applySealedFileProtection(at: chunk.finalURL)

        manifest?.upsert(
            ChunkManifest.Entry(
                chunkID: chunk.id,
                sequence: chunk.sequence,
                startedAtMs: chunk.startedAtMs,
                localState: .present,
                checksumSHA256: checksum,
                byteSize: byteSize,
                updatedAtMs: TimeMath.epochMs(Date())
            )
        )
        try await persistManifest()

        sealedChunkCount += 1
        totalBytes += Int64(byteSize)
        currentSession.lastAudioBufferAt = Date()
        currentSession.updatedAt = Date()
        self.session = currentSession
        logger.info(
            "sealed chunk \(chunk.sequence, privacy: .public) reason \(reason.rawValue, privacy: .public)"
        )
    }

    // MARK: - Loops

    private func startLoops() {
        stopLoops()
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_000))
                guard !Task.isCancelled else { return }
                await self?.rotationTick()
            }
        }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = Int64(
                    RecordingConfiguration.watchdogCheckInterval * 1000
                )
                try? await Task.sleep(for: .milliseconds(interval))
                guard !Task.isCancelled else { return }
                await self?.healthTick()
            }
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = Int64(RecordingConfiguration.heartbeatInterval * 1000)
                try? await Task.sleep(for: .milliseconds(interval))
                guard !Task.isCancelled else { return }
                await self?.heartbeatTick()
            }
        }
    }

    private func stopLoops() {
        rotationTask?.cancel()
        rotationTask = nil
        healthTask?.cancel()
        healthTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func rotationTick() async {
        guard state == .recording, let chunk = currentChunk, let recorder else {
            return
        }
        let now = Date()
        if recorder.currentTime > chunk.observedDuration + 0.25 {
            currentChunk?.observedDuration = recorder.currentTime
            lastAudioGrowthAt = now
            session?.lastAudioBufferAt = now
        }

        let size = fileSize(at: chunk.partURL)
        let elapsed = now.timeIntervalSince(chunk.startedAt)
        guard chunkPolicy.shouldSeal(elapsed: elapsed, byteCount: size) else {
            return
        }
        do {
            try await sealCurrentChunk(reason: .rotation)
            try startChunk(at: Date())
        } catch {
            await handleRecordingFailure(error)
        }
    }

    private func healthTick() async {
        guard state == .recording, let session else { return }
        let now = Date()
        let reference = lastAudioGrowthAt ?? session.startedAt
        let status = healthEvaluator.status(
            now: now,
            lastAudioBufferAt: reference,
            sessionStartedAt: session.startedAt
        )
        switch status {
        case .healthy:
            break
        case .recovering:
            logger.warning("audio progress stalled for 10s")
            await recoverAudio(reason: .watchdog)
        case .interrupted:
            logger.error("audio progress stalled for 30s")
            await recoverAudio(reason: .watchdog)
        }
    }

    private func heartbeatTick() async {
        guard state == .recording || state == .paused || state == .recovering else {
            return
        }
        try? await writeHealthFile()
    }

    // MARK: - Recovery

    private func recoverAudio(reason: RecoveryReason) async {
        guard autoRecoveryEnabled, state == .recording || state == .interrupted else {
            return
        }
        let generation = recoveryGeneration
        stopLoops()

        if currentChunk != nil {
            do {
                try await sealCurrentChunk(reason: .recovery)
            } catch {
                logger.error(
                    "seal before recovery failed: \(String(describing: error), privacy: .public)"
                )
            }
        }

        state = .recovering
        session?.state = .recovering
        session?.integrityState = "recovering"
        let gapStart = lastAudioGrowthAt
        try? await writeHealthFile()

        let delays = RecordingConfiguration.recoveryDelays
        for attempt in delays.indices {
            try? await Task.sleep(
                for: .milliseconds(Int64(delays[attempt] * 1000))
            )
            guard generation == recoveryGeneration, state == .recovering else {
                return
            }
            do {
                try activateAudioSession()
                try startChunk(at: Date())
                let now = Date()
                if let gapStart {
                    let gap = now.timeIntervalSince(gapStart)
                    if gap > 0 {
                        totalGapMs += Int64((gap * 1000).rounded())
                    }
                }
                session?.recoveryAttemptCount = attempt + 1
                session?.lastRecoveryAt = now
                session?.totalGapMs = totalGapMs
                session?.state = .recording
                session?.integrityState = "recovered"
                state = .recording
                lastError = nil
                startLoops()
                try? await writeHealthFile()
                logger.info(
                    "recovered after attempt \(attempt + 1, privacy: .public) reason \(reason.rawValue, privacy: .public)"
                )
                return
            } catch {
                logger.warning(
                    "recovery attempt \(attempt + 1, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }

        guard generation == recoveryGeneration else { return }
        state = .interrupted
        session?.state = .interrupted
        session?.integrityState = "interrupted"
        lastError = .audioSessionFailed("automatic recovery failed")
        try? await writeHealthFile()
    }

    private func handleRecordingFailure(_ error: Error) async {
        stopLoops()
        lastError = map(error)
        state = .interrupted
        session?.state = .interrupted
        session?.integrityState = "interrupted"
        if currentChunk != nil {
            do {
                try await sealCurrentChunk(reason: .interruption)
            } catch {
                logger.error(
                    "seal after failure failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        try? await writeHealthFile()
        await recoverAudio(reason: .audioFailure)
    }

    // MARK: - System events

    private func observeSystemNotifications() {
        guard notificationTasks.isEmpty else { return }
        notificationTasks.append(
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVAudioSession.interruptionNotification
                ) {
                    let rawType =
                        notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    let rawOptions =
                        notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                    await self?.handleInterruption(
                        typeRawValue: rawType,
                        optionsRawValue: rawOptions
                    )
                }
            }
        )
        notificationTasks.append(
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: AVAudioSession.routeChangeNotification
                ) {
                    await self?.handleRouteChange()
                }
            }
        )
        notificationTasks.append(
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: AVAudioSession.mediaServicesWereResetNotification
                ) {
                    await self?.handleMediaServicesReset()
                }
            }
        )
    }

    private func stopNotificationObservers() {
        for task in notificationTasks {
            task.cancel()
        }
        notificationTasks.removeAll()
    }

    private func handleInterruption(
        typeRawValue: UInt?,
        optionsRawValue: UInt?
    ) async {
        guard let typeRawValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeRawValue)
        else {
            return
        }
        switch type {
        case .began:
            guard state == .recording else { return }
            session?.interruptionCount += 1
            session?.integrityState = "interrupted"
            stopLoops()
            if currentChunk != nil {
                do {
                    try await sealCurrentChunk(reason: .interruption)
                } catch {
                    logger.error(
                        "seal on interruption failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            state = .interrupted
            session?.state = .interrupted
            lastError = .audioSessionFailed("audio interruption")
            try? await writeHealthFile()
            logger.info("audio interruption began")
        case .ended:
            guard state == .interrupted, autoRecoveryEnabled else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue ?? 0)
            if options.contains(.shouldResume) {
                await recoverAudio(reason: .interruption)
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange() async {
        guard state == .recording, currentChunk != nil else { return }
        do {
            try await sealCurrentChunk(reason: .routeChange)
            try startChunk(at: Date())
            try? await writeHealthFile()
            logger.info("audio route changed; started a new chunk")
        } catch {
            await handleRecordingFailure(error)
        }
    }

    private func handleMediaServicesReset() async {
        guard state == .recording || state == .paused else { return }
        isAudioSessionActive = false
        guard state == .recording else { return }
        stopLoops()
        if currentChunk != nil {
            do {
                try await sealCurrentChunk(reason: .interruption)
            } catch {
                logger.error(
                    "seal on media reset failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        state = .interrupted
        session?.state = .interrupted
        lastError = .audioSessionFailed("media services reset")
        try? await writeHealthFile()
        await recoverAudio(reason: .mediaServicesReset)
    }

    // MARK: - Persistence

    private func persistManifest() async throws {
        guard let manifest, let manifestWriter else { return }
        _ = try await manifestWriter.writeJSON(
            manifest,
            fileName: "manifest.json",
            overwrite: true
        )
    }

    private func writeHealthFile() async throws {
        guard var currentSession = session, let healthWriter else { return }
        let now = Date()
        let nowMs = TimeMath.epochMs(now)
        let version = StateVersion.next(
            lastKnown: lastStateVersion ?? StateVersion.initial,
            nowMs: nowMs
        )
        lastStateVersion = version
        currentSession.lastStateVersion = version
        currentSession.lastHeartbeatAt = now
        self.session = currentSession
        let currentBytes = currentChunk.map { fileSize(at: $0.partURL) } ?? 0
        let snapshot = WatchHealthSnapshot(
            sessionID: currentSession.id,
            sessionStartedAtMs: TimeMath.epochMs(currentSession.startedAt),
            endedAtMs: currentSession.endedAt.map { TimeMath.epochMs($0) },
            lastAudioBufferAtMs: currentSession.lastAudioBufferAt.map { TimeMath.epochMs($0) },
            lastHeartbeatAtMs: nowMs,
            chunkSequence: currentChunk?.sequence,
            bytesWritten: totalBytes + Int64(currentBytes),
            audioSessionActive: isAudioSessionActive,
            batteryLevel: batteryLevel,
            state: state.rawValue,
            stateVersion: version,
            totalGapMs: totalGapMs,
            interruptionCount: currentSession.interruptionCount
        )
        _ = try await healthWriter.writeJSON(
            snapshot,
            fileName: "health.json",
            overwrite: true
        )
    }

    // MARK: - Audio session

    private func activateAudioSession() throws {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default, options: [])
            try audioSession.setActive(true)
            let maximumChannels = max(1, audioSession.maximumInputNumberOfChannels)
            currentChannelCount = min(
                RecordingConfiguration.defaultChannelCount,
                maximumChannels
            )
            isAudioSessionActive = true
        } catch {
            isAudioSessionActive = false
            throw RecordingEngineError.audioSessionFailed(String(describing: error))
        }
    }

    private func deactivateAudioSession() {
        guard isAudioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            logger.warning(
                "audio session deactivate failed: \(String(describing: error), privacy: .public)"
            )
        }
        isAudioSessionActive = false
    }

    private static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Helpers

    private func fileSize(at url: URL) -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let number = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return number.intValue
    }

    private func map(_ error: Error) -> RecordingEngineError {
        if let error = error as? RecordingEngineError {
            return error
        }
        return .chunkFinalizeFailed(String(describing: error))
    }

    private func applyInProgressFileProtection(at url: URL) {
        #if os(watchOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path
            )
        #endif
    }

    private func applySealedFileProtection(at url: URL) {
        #if os(watchOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
    }
}
