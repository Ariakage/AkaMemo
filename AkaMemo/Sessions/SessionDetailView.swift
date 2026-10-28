import AkaMemoCore
import SwiftData
import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID
    let transcription: TranscriptionCoordinator?

    @Query private var chunks: [ReceivedChunkRecord]
    @Query private var transcripts: [TranscriptRecord]
    @State private var playback = PlaybackController()

    init(sessionID: UUID, transcription: TranscriptionCoordinator?) {
        self.sessionID = sessionID
        self.transcription = transcription
        _chunks = Query(
            filter: #Predicate<ReceivedChunkRecord> { record in
                record.sessionID == sessionID
            },
            sort: [SortDescriptor(\ReceivedChunkRecord.sequence)]
        )
        _transcripts = Query(
            filter: #Predicate<TranscriptRecord> { record in
                record.sessionID == sessionID
            }
        )
    }

    private var session: SessionSummary? {
        SessionAggregator.group(chunks.map(\.summary)).first
    }

    private var transcriptByChunk: [UUID: TranscriptRecord] {
        var result: [UUID: TranscriptRecord] = [:]
        for transcript in transcripts {
            guard let existing = result[transcript.chunkID] else {
                result[transcript.chunkID] = transcript
                continue
            }
            if existing.status == .ready {
                continue
            }
            if transcript.status == .ready
                || transcript.updatedAt > existing.updatedAt
            {
                result[transcript.chunkID] = transcript
            }
        }
        return result
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
                        ChunkRow(
                            chunk: chunk,
                            playback: playback,
                            transcript: transcriptByChunk[chunk.chunkID],
                            onRetry: {
                                Task {
                                    await transcription?.retry(
                                        chunkID: chunk.chunkID
                                    )
                                }
                            }
                        )
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
    let transcript: TranscriptRecord?
    let onRetry: () -> Void

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

            transcriptView
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        if let transcript {
            switch transcript.status {
            case .ready:
                if transcript.text.isEmpty {
                    Text("transcription.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(transcript.text)
                        .font(.footnote)
                }
            case .failed:
                HStack {
                    Text("session.transcription.failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("transcription.retry", action: onRetry)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                Text(
                    TranscriptionStatusText.errorMessage(transcript.errorCode)
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            case .pending:
                Text("session.transcription.pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("session.transcription.pending")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum TranscriptionStatusText {
    static func errorMessage(_ code: String?) -> LocalizedStringKey {
        switch code {
        case TranscriptionErrorCode.permissionDenied.rawValue:
            "transcription.error.permission"
        case TranscriptionErrorCode.engineUnavailable.rawValue:
            "transcription.error.engine"
        case TranscriptionErrorCode.audioMissing.rawValue:
            "transcription.error.audio"
        case TranscriptionErrorCode.decodeFailed.rawValue,
            TranscriptionErrorCode.unsupportedFormat.rawValue:
            "transcription.error.decode"
        default:
            "transcription.error.generic"
        }
    }
}
