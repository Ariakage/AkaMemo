import Foundation
import OSLog
import UserNotifications

protocol RecordingNotificationPosting: Sendable {
    func postInterrupted() async
    func scheduleDeadMan(sessionID: UUID, after: TimeInterval) async
    func cancelDeadMan(sessionID: UUID) async
    func cancelAllDeadMan() async
}

/// Local recording notifications. Dead-man notifications are scheduled ahead
/// so the system can fire them even while the app is suspended.
actor RecordingNotificationService: RecordingNotificationPosting {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "recording"
    )

    func postInterrupted() async {
        let content = baseContent(
            title: String(localized: "recording.notification.interrupted.title"),
            body: String(localized: "recording.notification.interrupted.body")
        )
        let request = UNNotificationRequest(
            identifier: "akamemo.interrupted.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func scheduleDeadMan(sessionID: UUID, after: TimeInterval) async {
        let identifier = deadManIdentifier(sessionID)
        center.removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
        let content = baseContent(
            title: String(localized: "recording.notification.deadman.title"),
            body: String(localized: "recording.notification.deadman.body")
        )
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(60, after),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
        } catch {
            logger.error("could not schedule dead-man notification")
        }
    }

    func cancelDeadMan(sessionID: UUID) async {
        center.removePendingNotificationRequests(
            withIdentifiers: [deadManIdentifier(sessionID)]
        )
    }

    func cancelAllDeadMan() async {
        let pending = await center.pendingNotificationRequests()
        let identifiers =
            pending
            .map(\.identifier)
            .filter { $0.hasPrefix("akamemo.deadman.") }
        center.removePendingNotificationRequests(
            withIdentifiers: identifiers
        )
    }

    private func baseContent(
        title: String,
        body: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        return content
    }

    private func deadManIdentifier(_ sessionID: UUID) -> String {
        "akamemo.deadman.\(sessionID.uuidString)"
    }
}
