import AkaMemoCore
import SwiftData
import SwiftUI

struct SessionListView: View {
    let transcription: TranscriptionCoordinator?
    let search: SearchCoordinator?
    let deletion: DeletionCoordinator?
    let diagnostics: AppDiagnostics?
    let battery: BatteryAlertCoordinator?

    @Query(sort: \ReceivedChunkRecord.startedAt, order: .forward)
    private var chunks: [ReceivedChunkRecord]
    @Query private var transcripts: [TranscriptRecord]
    @State private var pendingDeletion: PendingDeletion?
    @State private var deletionError: String?
    @State private var showDiagnostics = false

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
                    if let deletionError {
                        Section {
                            Text(deletionError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    ForEach(sessions) { session in
                        NavigationLink(value: session.sessionID) {
                            SessionRow(
                                session: session,
                                transcribedCount: transcribedCount(
                                    for: session
                                ),
                                hasFailure: hasFailure(for: session)
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = .session(session.sessionID)
                            } label: {
                                Label(
                                    "deletion.action",
                                    systemImage: "trash"
                                )
                            }
                        }
                    }
                }
                .navigationTitle("inbox.title")
                .navigationDestination(for: UUID.self) { sessionID in
                    SessionDetailView(
                        sessionID: sessionID,
                        transcription: transcription,
                        deletion: deletion
                    )
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let battery {
                BatteryBannerView(coordinator: battery)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label(
                            "diagnostics.title",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                    Button(role: .destructive) {
                        pendingDeletion = .all
                    } label: {
                        Label("deletion.all", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("deletion.menu"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SearchView(
                        search: search,
                        transcription: transcription,
                        deletion: deletion
                    )
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(Text("search.title"))
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
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                DiagnosticsView(diagnostics: diagnostics)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.close") {
                                showDiagnostics = false
                            }
                        }
                    }
            }
        }
    }

    private func performDeletion(_ pending: PendingDeletion) async {
        switch pending {
        case .session(let sessionID):
            _ = await deletion?.deleteSession(sessionID)
        case .chunk(let chunkID, _):
            _ = await deletion?.deleteChunk(chunkID)
        case .all:
            _ = await deletion?.deleteAll()
        }
        if let message = deletion?.errorMessage {
            deletionError = message
        }
    }

    private func transcribedCount(for session: SessionSummary) -> Int {
        let chunkIDs = Set(session.chunks.map(\.chunkID))
        return transcripts.filter {
            chunkIDs.contains($0.chunkID) && $0.status == .ready
        }.count
    }

    private func hasFailure(for session: SessionSummary) -> Bool {
        let chunkIDs = Set(session.chunks.map(\.chunkID))
        return transcripts.contains {
            chunkIDs.contains($0.chunkID) && $0.status == .failed
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let transcribedCount: Int
    let hasFailure: Bool

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
                if transcribedCount == session.chunkCount {
                    Text("session.transcription.ready")
                        .foregroundStyle(.green)
                } else if hasFailure {
                    Text("session.transcription.failed")
                        .foregroundStyle(.red)
                } else {
                    Text("session.transcription.pending")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 2)
    }
}
