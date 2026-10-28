import AkaMemoCore
import Foundation
import Observation

/// Validates Watch battery events, posts local notifications once, and drives
/// the low-battery banner and Live Activity.
@MainActor
@Observable
final class BatteryAlertCoordinator {
    enum BannerKind: Equatable {
        case low
        case stopped
    }

    struct Banner: Equatable {
        let kind: BannerKind
        let level: Int

        var messageKey: String {
            switch kind {
            case .low: "battery.banner.low"
            case .stopped: "battery.banner.stopped"
            }
        }
    }

    private let notifier: any BatteryNotificationPosting
    private let activity: any BatteryActivityControlling
    private var latest: BatteryEvent?
    private var processedAlertIDs: [UUID] = []
    private var isForeground = false
    private var didRequestAuthorization = false

    private(set) var banner: Banner?
    private(set) var notificationsDenied = false

    init(
        notifier: any BatteryNotificationPosting,
        activity: any BatteryActivityControlling
    ) {
        self.notifier = notifier
        self.activity = activity
    }

    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuthorization else {
            return
        }
        didRequestAuthorization = true
        let granted = await notifier.requestAuthorization()
        notificationsDenied = !granted
    }

    func setForeground(_ active: Bool) async {
        isForeground = active
        guard active, let latest else {
            return
        }
        let now = Date()
        guard latest.recordingState == "recording",
            !latest.isCharging,
            latest.batteryLevel <= 0.05,
            !latest.isExpired(nowMs: TimeMath.epochMs(now))
        else {
            return
        }
        await startActivity(from: latest, now: now)
    }

    func handle(_ event: BatteryEvent, now: Date = Date()) async {
        let nowMs = TimeMath.epochMs(now)
        guard !event.isExpired(nowMs: nowMs) else {
            return
        }
        if event.kind == .snapshot {
            await handleSnapshot(event, now: now)
            return
        }

        if event.kind == .reset {
            banner = nil
            await activity.end()
            return
        }

        guard event.kind == .alert5 || event.kind == .alert3,
            !processedAlertIDs.contains(event.eventID)
        else {
            return
        }
        markProcessed(event.eventID)

        if let latest, latest.recordedAtMs > event.recordedAtMs {
            if let eventSession = event.sessionID,
                let latestSession = latest.sessionID,
                eventSession != latestSession
            {
                return
            }
            if event.kind == .alert5 {
                if latest.batteryLevel <= 0.03
                    || latest.isCharging
                    || latest.recordingState != "recording"
                {
                    return
                }
            } else if latest.isCharging || latest.batteryLevel > 0.03 {
                return
            }
        }

        if event.kind == .alert3 {
            await notifier.postBatteryAlert(level: 3)
            banner = Banner(kind: .stopped, level: 3)
            await activity.end()
            return
        }

        await notifier.postBatteryAlert(level: 5)
        banner = Banner(
            kind: .low,
            level: Int((event.batteryLevel * 100).rounded())
        )
        if isForeground {
            await startActivity(from: event, now: now)
        }
    }

    private func handleSnapshot(_ event: BatteryEvent, now: Date) async {
        if let latest, event.recordedAtMs < latest.recordedAtMs {
            return
        }
        let previousSessionID = latest?.sessionID
        latest = event
        if let previousSessionID, previousSessionID != event.sessionID {
            banner = nil
            await activity.end()
        }

        if event.isCharging, event.batteryLevel > 0.10 {
            banner = nil
            await activity.end()
            return
        }
        if event.recordingState != "recording" {
            if event.batteryLevel <= 0.03 {
                banner = Banner(kind: .stopped, level: 3)
            } else {
                banner = nil
            }
            await activity.end()
            return
        }
        if event.batteryLevel <= 0.03 {
            banner = Banner(kind: .stopped, level: 3)
            await activity.end()
        } else if event.batteryLevel <= 0.05 {
            banner = Banner(
                kind: .low,
                level: Int((event.batteryLevel * 100).rounded())
            )
            if isForeground {
                await startActivity(from: event, now: now)
            }
        } else {
            banner = nil
            if event.batteryLevel > 0.10 {
                await activity.end()
            }
        }
    }

    private func startActivity(from event: BatteryEvent, now: Date) async {
        guard let sessionID = event.sessionID else {
            return
        }
        await activity.startOrUpdate(
            sessionID: sessionID,
            level: event.batteryLevel,
            batteryState: event.batteryState.rawValue,
            recordingState: event.recordingState,
            now: now
        )
    }

    private func markProcessed(_ eventID: UUID) {
        processedAlertIDs.append(eventID)
        if processedAlertIDs.count > 100 {
            processedAlertIDs.removeFirst(processedAlertIDs.count - 100)
        }
    }
}
