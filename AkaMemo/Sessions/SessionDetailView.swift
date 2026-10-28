import AkaMemoCore
import SwiftData
import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID
    let transcription: TranscriptionCoordinator?
    let deletion: DeletionCoordinator?
    let startChunkID: UUID?
    let startAtMs: Int64?

    @Environment(\.dismiss) private var dismiss
    @Query private var chunks: [ReceivedChunkRecord]
    @Query private var transcripts: [TranscriptRecord]
    @Query private var locationTracks: [LocationTrackRecord]
    @State private var playback = PlaybackController()
    @State private var didStartInitialPlayback = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var deletionError: String?
    @State private var showPurgePrompt = false
    @State private var jumpAudioUnavailable = false

    init(
        sessionID: UUID,
        transcription: TranscriptionCoordinator?,
        deletion: DeletionCoordinator? = nil,
        startChunkID: UUID? = nil,
        startAtMs: Int64? = nil
    ) {
        self.sessionID = sessionID
        self.transcription = transcription
        self.deletion = deletion
        self.startChunkID = startChunkID
        self.startAtMs = startAtMs
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
        _locationTracks = Query(
            filter: #Predicate<LocationTrackRecord> { record in
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
                    if session.chunks.contains(where: { !$0.audioPurged }) {
                        Button("audioPurge.action", role: .destructive) {
                            showPurgePrompt = true
                        }
                    } else {
                        Text("audioPurge.done")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .alert(
                    "audioPurge.title",
                    isPresented: $showPurgePrompt
                ) {
                    Button("audioPurge.confirm", role: .destructive) {
                        Task {
                            await purgeAudio()
                        }
                    }
                    Button("deletion.cancel", role: .cancel) {}
                } message: {
                    Text("audioPurge.message")
                }

                LocationTrackSection(track: locationTracks.first) {
                    guard let track = locationTracks.first else {
                        return
                    }
                    Task {
                        let deleted = await deletion?.deleteTrack(
                            track.trackID,
                            sessionID: track.sessionID
                        )
                        if deleted != true, let message = deletion?.errorMessage {
                            deletionError = message
                        }
                    }
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
                        .swipeActions(
                            edge: .trailing,
                            allowsFullSwipe: false
                        ) {
                            Button(role: .destructive) {
                                pendingDeletion = .chunk(
                                    chunk.chunkID,
                                    sessionID: sessionID
                                )
                            } label: {
                                Label(
                                    "deletion.action",
                                    systemImage: "trash"
                                )
                            }
                        }
                    }
                }

                if jumpAudioUnavailable {
                    Section {
                        Text("session.audioUnavailable")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = playback.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let deletionError {
                    Section {
                        Text(deletionError)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    pendingDeletion = .session(sessionID)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("deletion.action"))
            }
        }
        .alert(item: $pendingDeletion) { pending in
            Alert(
                title: Text(pending.titleKey),
                message: Text(pending.messageKey),
                primaryButton: .destructive(Text("deletion.confirm")) {
                    Task {
                        await performDeletion(pending)
                    }
                },
                secondaryButton: .cancel(Text("deletion.cancel"))
            )
        }
        .onAppear { startInitialPlaybackIfNeeded() }
        .onChange(of: chunks.count) { _, _ in
            startInitialPlaybackIfNeeded()
        }
        .onDisappear { playback.stop() }
    }

    private func performDeletion(_ pending: PendingDeletion) async {
        switch pending {
        case .session:
            if await deletion?.deleteSession(sessionID) == true {
                playback.stop()
                dismiss()
            }
        case .chunk(let chunkID, _):
            if await deletion?.deleteChunk(chunkID) == true {
                if playback.currentChunkID == chunkID {
                    playback.stop()
                }
            }
        case .all:
            if await deletion?.deleteAll() == true {
                playback.stop()
                dismiss()
            }
        }
        if let message = deletion?.errorMessage {
            deletionError = message
        }
    }

    private func purgeAudio() async {
        guard await deletion?.purgeAudio(sessionID: sessionID) == true else {
            if let message = deletion?.errorMessage {
                deletionError = message
            }
            return
        }
        playback.stop()
    }

    private func startInitialPlaybackIfNeeded() {
        guard !didStartInitialPlayback, let startChunkID,
            let chunk = session?.chunks.first(where: {
                $0.chunkID == startChunkID
            })
        else {
            return
        }
        didStartInitialPlayback = true
        guard !chunk.audioPurged else {
            jumpAudioUnavailable = true
            return
        }
        playback.start(chunk: chunk, atAbsoluteMs: startAtMs)
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
                if chunk.audioPurged {
                    Label("playback.audioPurged", systemImage: "waveform.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
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
                                isPlayingThisChunk
                                    ? "playback.pause" : "playback.play"
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
