import AkaMemoCore
import Foundation

protocol HealthEventTransport: AnyObject, Sendable {
    func updateHealthContext(_ event: RecordingHealthEvent) -> Bool
    func sendHealthEvent(_ event: RecordingHealthEvent) -> Bool
}

/// Publishes a combined health snapshot every 10 seconds and an immediate
/// event on every recording state change. Snapshots go through
/// `applicationContext`; events use userInfo/message.
actor WatchHealthPublisher {
    private let transport: (any HealthEventTransport)?
    private let intervalMs: Int64
    private var lastPublishedAtMs: Int64 = 0
    private var lastState: String?

    init(
        transport: (any HealthEventTransport)?,
        intervalMs: Int64 = 10_000
    ) {
        self.transport = transport
        self.intervalMs = intervalMs
    }

    func publish(_ event: RecordingHealthEvent) {
        let stateChanged = event.state != lastState
        let due = event.recordedAtMs - lastPublishedAtMs >= intervalMs
        if stateChanged {
            _ = transport?.sendHealthEvent(event)
        }
        if due || stateChanged {
            _ = transport?.updateHealthContext(event)
            lastPublishedAtMs = event.recordedAtMs
        }
        lastState = event.state
    }
}
