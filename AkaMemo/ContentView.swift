import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var model = PhoneAppModel()

    var body: some View {
        NavigationStack {
            Group {
                if let container = model.container {
                    ReceivedChunksView()
                        .modelContainer(container)
                } else {
                    ContentUnavailableView(
                        "inbox.error.title",
                        systemImage: "exclamationmark.triangle",
                        description: Text("inbox.error.storage")
                    )
                }
            }
            .navigationTitle("app.name")
        }
    }
}

private struct ReceivedChunksView: View {
    @Query(sort: \ReceivedChunkRecord.receivedAt, order: .reverse)
    private var chunks: [ReceivedChunkRecord]

    var body: some View {
        Group {
            if chunks.isEmpty {
                ContentUnavailableView(
                    "inbox.empty.title",
                    systemImage: "tray",
                    description: Text("inbox.empty.message")
                )
            } else {
                List {
                    ForEach(chunks, id: \.chunkID) { chunk in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                chunk.startedAt,
                                format: .dateTime.month().day().hour().minute()
                            )
                            .font(.headline)

                            Text("\(chunk.durationMs / 1000) s · \(chunk.byteSize / 1024) KB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("inbox.title")
            }
        }
    }
}

#Preview {
    ContentView()
}
