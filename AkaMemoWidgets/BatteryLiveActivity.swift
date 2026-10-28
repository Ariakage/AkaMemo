import ActivityKit
import SwiftUI
import WidgetKit

struct BatteryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BatteryActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("Watch 电量 \(percent(context.state.batteryLevel))")
                    .font(.headline)
                Text(context.state.recordingState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "applewatch")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state.batteryLevel))
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.recordingState)
                        .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "applewatch")
            } compactTrailing: {
                Text(percent(context.state.batteryLevel))
            } minimal: {
                Text(percent(context.state.batteryLevel))
            }
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
