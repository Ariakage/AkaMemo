import AkaMemoCore
import Foundation
import OSLog

struct WatchDeletionState: Codable, Sendable, Equatable {
    struct Tombstone: Codable, Sendable, Equatable {
        let id: UUID
        let scope: DeletionScope
        let entityID: UUID?
        let sessionID: UUID?
        let deletedAtMs: Int64
    }

    var epochMs: Int64?
    var tombstones: [Tombstone]
}

/// Persists deletion boundaries on the Watch. Loaded before the transfer queue
/// starts so old chunks are never sent after a delete-all.
actor WatchDeletionStore {
    private let stateURL: URL
    private let writer: AtomicFileWriter
    private var state: WatchDeletionState
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo.watchkitapp",
        category: "storage"
    )

    init(appSupportRoot: URL) {
        let directory = appSupportRoot.appending(
            path: "deletion",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.stateURL = directory.appending(path: "state.json")
        self.writer = AtomicFileWriter(directory: directory)
        if let data = try? Data(contentsOf: stateURL),
            let loaded = try? JSONDecoder().decode(
                WatchDeletionState.self,
                from: data
            )
        {
            self.state = loaded
        } else {
            self.state = WatchDeletionState(epochMs: nil, tombstones: [])
        }
    }

    func apply(_ command: DeletionCommand) async -> Bool {
        var changed = false
        if command.scope == .all, let epochMs = command.epochMs {
            if (state.epochMs ?? 0) < epochMs {
                state.epochMs = epochMs
                changed = true
            }
        } else if !state.tombstones.contains(where: {
            $0.id == command.tombstoneID
        }) {
            state.tombstones.append(
                WatchDeletionState.Tombstone(
                    id: command.tombstoneID,
                    scope: command.scope,
                    entityID: command.entityID,
                    sessionID: command.sessionID,
                    deletedAtMs: command.deletedAtMs
                )
            )
            changed = true
        }
        if changed {
            await persist()
        }
        return true
    }

    func isDeleted(
        chunkID: UUID?,
        sessionID: UUID,
        sessionStartedAtMs: Int64
    ) -> Bool {
        if let epochMs = state.epochMs, sessionStartedAtMs < epochMs {
            return true
        }
        for tombstone in state.tombstones {
            switch tombstone.scope {
            case .chunk:
                if let chunkID, tombstone.entityID == chunkID {
                    return true
                }
            case .audio:
                // The chunk's audio was purged and must not be re-queued.
                if let chunkID, tombstone.entityID == chunkID {
                    return true
                }
            case .session:
                if tombstone.entityID == sessionID {
                    return true
                }
            case .location:
                // The track is gone but the session's audio still uploads.
                continue
            case .all:
                continue
            }
        }
        return false
    }

    func epochMs() -> Int64? {
        state.epochMs
    }

    func tombstoneCount() -> Int {
        state.tombstones.count
    }

    private func persist() async {
        do {
            _ = try await writer.writeJSON(
                state,
                fileName: "state.json",
                overwrite: true
            )
        } catch {
            logger.error(
                "watch deletion state persist failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
