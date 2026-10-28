import AkaMemoCore
import SwiftUI
import UniformTypeIdentifiers

struct LocationTrackSection: View {
    let track: LocationTrackRecord?
    var onDelete: (() -> Void)?

    @State private var showPrivacyPrompt = false
    @State private var showDeletePrompt = false
    @State private var exportDocument: GPXExportDocument?
    @State private var exportFileName = "AkaMemo.gpx"
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        Section("location.track.title") {
            if let track {
                LabeledContent(
                    "location.track.points",
                    value: "\(track.pointCount)"
                )
                if let distance = track.distanceMeters {
                    LabeledContent(
                        "location.track.distance",
                        value: distanceText(distance)
                    )
                }
                Button("location.export.gpx") {
                    showPrivacyPrompt = true
                }
                if let onDelete {
                    Button("location.track.delete", role: .destructive) {
                        showDeletePrompt = true
                    }
                    .alert(
                        "location.delete.title",
                        isPresented: $showDeletePrompt
                    ) {
                        Button("location.delete.confirm", role: .destructive) {
                            onDelete()
                        }
                        Button("deletion.cancel", role: .cancel) {}
                    } message: {
                        Text("location.delete.message")
                    }
                }
            } else {
                Text("location.track.empty")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .alert(
            "location.export.privacy.title",
            isPresented: $showPrivacyPrompt
        ) {
            Button("location.export.continue") {
                Task {
                    await prepareExport()
                }
            }
            Button("deletion.cancel", role: .cancel) {}
        } message: {
            Text("location.export.privacy.message")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: UTType(filenameExtension: "gpx") ?? .xml,
            defaultFilename: exportFileName
        ) { _ in
            exportDocument = nil
        }
    }

    private func prepareExport() async {
        guard let track else {
            return
        }
        do {
            let root = try PhonePaths.applicationSupport()
            let url = root.appending(path: track.relativePath)
            let data = try Data(contentsOf: url)
            let decoded = LocationTrackCodec.decode(data)
            let sessionStartedAtMs = TimeMath.epochMs(track.sessionStartedAt)
            let endedAtMs = TimeMath.epochMs(track.endedAt)
            guard
                let gpx = GPXExporter.gpx(
                    points: decoded.points,
                    sessionStartedAtMs: sessionStartedAtMs,
                    endedAtMs: endedAtMs
                )
            else {
                errorMessage = String(localized: "location.export.empty")
                return
            }
            exportFileName = GPXExporter.fileName(
                sessionStartedAtMs: sessionStartedAtMs,
                sessionID: track.sessionID
            )
            exportDocument = GPXExportDocument(text: gpx)
            errorMessage = nil
            isExporting = true
        } catch {
            errorMessage = String(localized: "location.export.failed")
        }
    }

    private func distanceText(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1f km", meters / 1_000)
        }
        return String(format: "%.0f m", meters)
    }
}

struct GPXExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
            let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
