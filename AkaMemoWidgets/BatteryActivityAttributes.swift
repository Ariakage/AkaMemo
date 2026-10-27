import ActivityKit
import Foundation

struct BatteryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var batteryLevel: Double
        var batteryState: String
        var recordingState: String
        var startedAt: Date
        var lastUpdated: Date
    }

    var sessionID: UUID
}
