import ActivityKit
import Foundation

protocol BatteryActivityControlling: AnyObject, Sendable {
    func startOrUpdate(
        sessionID: UUID,
        level: Double,
        batteryState: String,
        recordingState: String,
        now: Date
    ) async
    func end() async
}

/// Starts and updates the low-battery Live Activity. `Activity.request` only
/// works while the app is foreground, so callers must gate on scene phase.
final class BatteryLiveActivityController: BatteryActivityControlling,
    @unchecked Sendable
{
    nonisolated(unsafe) private var activity: Activity<BatteryActivityAttributes>?

    func startOrUpdate(
        sessionID: UUID,
        level: Double,
        batteryState: String,
        recordingState: String,
        now: Date
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        let state = BatteryActivityAttributes.ContentState(
            batteryLevel: level,
            batteryState: batteryState,
            recordingState: recordingState,
            startedAt: now,
            lastUpdated: now
        )
        let content = ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(5 * 60)
        )
        if let activity {
            await activity.update(content)
            return
        }
        do {
            activity = try Activity.request(
                attributes: BatteryActivityAttributes(sessionID: sessionID),
                content: content,
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    func end() async {
        guard let activity else {
            return
        }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
