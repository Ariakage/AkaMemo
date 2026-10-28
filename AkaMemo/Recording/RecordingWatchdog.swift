import AkaMemoCore
import Foundation
import Observation

/// Tracks Watch health snapshots, schedules the dead-man notification, and
/// exposes a banner when the recording may have stopped.
@MainActor
@Observable
final class RecordingWatchdog {
    enum BannerKind: Equatable {
        case interrupted
        case stale
        case storage
        case paused
    }

    struct Banner: Equatable {
        let kind: BannerKind

        var messageKey: String {
            switch kind {
            case .interrupted: "recording.banner.interrupted"
            case .stale: "recording.banner.stale"
            case .storage: "recording.banner.storage"
            case .paused: "recording.banner.paused"
            }
        }
    }

    private let notifier: any RecordingNotificationPosting
    private let storagePolicy = RecordingStoragePolicy.standard
    private let heartbeatTimeout: TimeInterval = 45
    private let deadManDelay: TimeInterval = 90
    private let notificationDedupeWindow: TimeInterval = 300

    private var latest: RecordingHealthEvent?
    private var lastHeartbeatAt: Date?
    private var lastInterruptedNotificationAt: Date?
    private var timerTask: Task<Void, Never>?

    private(set) var banner: Banner?

    init(notifier: any RecordingNotificationPosting) {
        self.notifier = notifier
    }

    func handle(_ event: RecordingHealthEvent, now: Date = Date()) async {
        guard !event.isExpired(nowMs: TimeMath.epochMs(now)) else {
            return
        }
        if let latest, latest.sessionID == event.sessionID {
            guard event.stateVersion >= latest.stateVersion else {
                return
            }
        } else {
            stopTimer()
            lastInterruptedNotificationAt = nil
        }
        latest = event

        if isStorageCritical(event) {
            banner = Banner(kind: .storage)
        }

        if event.isRecording {
            lastHeartbeatAt = TimeMath.date(epochMs: event.recordedAtMs)
            if !isStorageCritical(event) {
                banner = nil
            }
            if let sessionID = event.sessionID {
                await notifier.scheduleDeadMan(
                    sessionID: sessionID,
                    after: deadManDelay
                )
            }
            startTimer()
            return
        }

        lastHeartbeatAt = nil
        stopTimer()
        if let sessionID = event.sessionID {
            await notifier.cancelDeadMan(sessionID: sessionID)
        }
        switch event.state {
        case "interrupted":
            if !isStorageCritical(event) {
                banner = Banner(kind: .interrupted)
            }
            await notifyInterruptedIfNeeded(now: now)
        case "failed":
            if !isStorageCritical(event) {
                banner = Banner(kind: .interrupted)
            }
            await notifyInterruptedIfNeeded(now: now)
        case "paused":
            if !isStorageCritical(event) {
                banner = Banner(kind: .paused)
            }
        default:
            if !isStorageCritical(event) {
                banner = nil
            }
        }
    }

    /// Called by the in-app timer; the system dead-man notification covers the
    /// suspended case.
    func evaluate(now: Date = Date()) async {
        guard let latest, latest.isRecording,
            let lastHeartbeatAt,
            now.timeIntervalSince(lastHeartbeatAt) >= heartbeatTimeout
        else {
            return
        }
        if banner == nil {
            banner = Banner(kind: .stale)
        }
        await notifyInterruptedIfNeeded(now: now)
    }

    func clear() async {
        latest = nil
        lastHeartbeatAt = nil
        lastInterruptedNotificationAt = nil
        banner = nil
        stopTimer()
        await notifier.cancelAllDeadMan()
    }

    private func notifyInterruptedIfNeeded(now: Date) async {
        if let last = lastInterruptedNotificationAt,
            now.timeIntervalSince(last) < notificationDedupeWindow
        {
            return
        }
        lastInterruptedNotificationAt = now
        await notifier.postInterrupted()
    }

    private func isStorageCritical(_ event: RecordingHealthEvent) -> Bool {
        storagePolicy.band(forAvailableBytes: event.storageAvailableBytes)
            == .critical
    }

    private func startTimer() {
        guard timerTask == nil else {
            return
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else {
                    return
                }
                await self.evaluate()
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
