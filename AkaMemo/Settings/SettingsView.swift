import AkaMemoCore
import SwiftData
import SwiftUI

/// Location privacy controls from FR-024. The Watch owns the actual location
/// permission; this screen shows its last reported status and total track
/// usage, and sends the global toggle to the Watch.
struct SettingsView: View {
    let settings: PhoneSettingsModel

    @Environment(\.dismiss) private var dismiss
    @Query private var tracks: [LocationTrackRecord]
    @State private var trackUsageBytes: Int64?

    var body: some View {
        NavigationStack {
            List {
                Section("settings.location.title") {
                    Toggle(
                        "settings.location.enabled",
                        isOn: Binding(
                            get: { settings.isLocationEnabled },
                            set: { settings.setLocationEnabled($0) }
                        )
                    )
                    LabeledContent("settings.location.watchStatus") {
                        Text(watchStatusKey)
                    }
                    LabeledContent("settings.location.authorization") {
                        Text(authorizationKey)
                    }
                    LabeledContent("settings.location.usage") {
                        Text(usageText)
                    }
                    Text("settings.location.footnote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("settings.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("settings.done") {
                        dismiss()
                    }
                }
            }
            .task(id: tracks.count) {
                await loadTrackUsage()
            }
        }
    }

    private var watchStatusKey: LocalizedStringKey {
        guard let enabled = settings.watchLocationEnabled else {
            return "settings.location.unknown"
        }
        return enabled ? "settings.location.value.on" : "settings.location.value.off"
    }

    private var authorizationKey: LocalizedStringKey {
        switch settings.watchAuthorization {
        case "authorized":
            return "settings.location.auth.authorized"
        case "denied":
            return "settings.location.auth.denied"
        case "restricted":
            return "settings.location.auth.restricted"
        case "notDetermined":
            return "settings.location.auth.notDetermined"
        default:
            return "settings.location.unknown"
        }
    }

    private var usageText: String {
        guard let trackUsageBytes else {
            return "—"
        }
        return trackUsageBytes.formatted(.byteCount(style: .file))
    }

    @MainActor
    private func loadTrackUsage() async {
        guard let root = try? PhonePaths.applicationSupport() else {
            return
        }
        var total: Int64 = 0
        for track in tracks {
            let url = root.appending(path: track.relativePath)
            guard
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: url.path
                ),
                let size = attributes[.size] as? NSNumber
            else {
                continue
            }
            total += size.int64Value
        }
        trackUsageBytes = total
    }
}
