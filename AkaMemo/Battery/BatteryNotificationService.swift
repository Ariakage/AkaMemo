import Foundation
import OSLog
import UserNotifications

protocol BatteryNotificationPosting: Sendable {
    func requestAuthorization() async -> Bool
    func postBatteryAlert(level: Int) async
}

/// Posts local notifications. There is no remote push path in the MVP.
actor BatteryNotificationService: BatteryNotificationPosting {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "battery"
    )

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(
                options: [.alert, .sound]
            )
        } catch {
            logger.error("notification authorization failed")
            return false
        }
    }

    func postBatteryAlert(level: Int) async {
        let content = UNMutableNotificationContent()
        if level <= 3 {
            content.title = String(localized: "battery.notification.title.3")
            content.body = String(localized: "battery.notification.body.3")
        } else {
            content.title = String(localized: "battery.notification.title.5")
            content.body = String(localized: "battery.notification.body.5")
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "akamemo.battery.\(level).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            logger.error("could not post battery notification")
        }
    }
}
