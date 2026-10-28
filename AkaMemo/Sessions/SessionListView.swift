import AkaMemoCore
import SwiftData
import SwiftUI

struct SessionListView: View {
    @Query(sort: \ReceivedChunkRecord.startedAt, order: .forward)
    private var chunks: [ReceivedChunkRecord]

    private var sessions: [SessionSummary] {
        SessionAggregator.group(chunks.map(\.summary))
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "inbox.empty.title",
                    systemImage: "tray",
                    description: Text("inbox.empty.message")
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        NavigationLink(value: session.sessionID) {
                            SessionRow(session: session)
                        }
                    }
                }
                .navigationTitle("inbox.title")
                .navigationDestination(for: UUID.self) { sessionID in
                    SessionDetailView(sessionID: sessionID)
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                TimeMath.date(epochMs: session.startedAtMs),
                format: .dateTime.month().day().hour().minute()
            )
            .font(.headline)

            HStack(spacing: 10) {
                Label(
                    SessionFormatting.durationText(session.totalDurationMs),
                    systemImage: "clock"
                )
                Label {
                    Text("\(session.chunkCount)")
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                .accessibilityLabel(Text("session.chunkCount"))
                .accessibilityValue(Text("\(session.chunkCount)"))
                Label(
                    SessionFormatting.byteText(session.totalBytes),
                    systemImage: "internaldrive"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("session.transfer.received")
                    .foregroundStyle(.green)
                Text("session.transcription.pending")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
    }
}
