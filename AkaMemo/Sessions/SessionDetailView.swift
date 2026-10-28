import AkaMemoCore
import SwiftData
import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID
    @Query private var chunks: [ReceivedChunkRecord]
    @State private var playback = PlaybackController()

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _chunks = Query(
            filter: #Predicate<ReceivedChunkRecord> { record in
                record.sessionID == sessionID
            },
            sort: [SortDescriptor(\ReceivedChunkRecord.sequence)]
        )
    }

    private var session: SessionSummary? {
        SessionAggregator.group(chunks.map(\.summary)).first
    }

    var body: some View {
        List {
            if let session {
                Section {
                    LabeledContent(
                        "session.duration",
                        value: SessionFormatting.durationText(session.totalDurationMs)
                    )
                    LabeledContent(
                        "session.size",
                        value: SessionFormatting.byteText(session.totalBytes)
                    )
                    LabeledContent(
                        "session.chunkCount",
                        value: "\(session.chunkCount)"
                    )
                }

                Section("session.chunks.title") {
                    ForEach(session.chunks, id: \.chunkID) { chunk in
                        ChunkRow(chunk: chunk, playback: playback)
                    }
                }

                if let error = playback.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            } else {
                ContentUnavailableView(
                    "session.empty.title",
                    systemImage: "tray"
                )
            }
        }
        .navigationTitle("session.title")
        .onDisappear { playback.stop() }
    }
}

private struct ChunkRow: View {
    let chunk: ChunkSummary
    let playback: PlaybackController

    private var isCurrent: Bool {
        playback.currentChunkID == chunk.chunkID
    }

    private var isPlayingThisChunk: Bool {
        isCurrent && playback.isPlaying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    TimeMath.date(epochMs: chunk.startedAtMs),
                    format: .dateTime.hour().minute().second()
                )
                .font(.subheadline)

                Spacer()

                Text(SessionFormatting.durationText(Int64(chunk.durationMs)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    playback.toggle(chunk: chunk)
                } label: {
                    Image(
                        systemName: isPlayingThisChunk
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text(
                        LocalizedStringKey(
                            isPlayingThisChunk ? "playback.pause" : "playback.play"
                        )
                    )
                )

                if isCurrent {
                    Slider(
                        value: Binding(
                            get: { playback.progress },
                            set: { playback.seek(to: $0) }
                        ),
                        in: 0...1
                    )
                    .accessibilityLabel(Text("playback.progress"))

                    Text(playback.currentTimeText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
