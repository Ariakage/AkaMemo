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
    @Query private var chunks: [ReceivedChunkRecord]
    @Query private var transcripts: [TranscriptRecord]
    @State private var trackUsageBytes: Int64?
    @State private var audioBytes: Int64?
    @State private var transcriptBytes: Int64?
    @State private var indexBytes: Int64?

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

                Section("settings.storage.title") {
                    LabeledContent("settings.storage.audio") {
                        Text(byteText(audioBytes))
                    }
                    LabeledContent("settings.storage.transcripts") {
                        Text(byteText(transcriptBytes))
                    }
                    LabeledContent("settings.storage.index") {
                        Text(byteText(indexBytes))
                    }
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
            .task(id: tracks.count + chunks.count + transcripts.count) {
                await loadUsage()
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
        byteText(trackUsageBytes)
    }

    private func byteText(_ bytes: Int64?) -> String {
        guard let bytes else {
            return "—"
        }
        return bytes.formatted(.byteCount(style: .file))
    }

    @MainActor
    private func loadUsage() async {
        guard let root = try? PhonePaths.applicationSupport() else {
            return
        }
        var trackTotal: Int64 = 0
        for track in tracks {
            trackTotal += fileBytes(
                at: root.appending(path: track.relativePath)
            )
        }
        trackUsageBytes = trackTotal

        audioBytes =
            chunks
            .filter { $0.audioPurgedAt == nil }
            .reduce(Int64(0)) { total, chunk in
                total + Int64(chunk.byteSize)
            }
        transcriptBytes =
            transcripts
            .filter { $0.status == .ready }
            .reduce(Int64(0)) { total, transcript in
                total + Int64(transcript.text.utf8.count)
            }
        let indexURL = root.appending(path: "index/search.sqlite")
        indexBytes =
            fileBytes(at: indexURL)
            + fileBytes(at: URL(fileURLWithPath: indexURL.path + "-wal"))
            + fileBytes(at: URL(fileURLWithPath: indexURL.path + "-shm"))
    }

    private func fileBytes(at url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }
}
