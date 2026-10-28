import AkaMemoCore
import Foundation
import OSLog

/// Applies deletion commands to Watch files and the transfer queue.
actor WatchDeletionHandler {
    private let root: URL
    private let deletionStore: WatchDeletionStore
    private let queue: WatchTransferQueue
    private var stopSessionHandler: (@Sendable (UUID?, Int64?) async -> Void)?
    private var stopLocationSessionHandler: (@Sendable (UUID) async -> Void)?
    private let fileManager = FileManager.default
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "storage"
    )

    init(
        appSupportRoot: URL,
        deletionStore: WatchDeletionStore,
        queue: WatchTransferQueue
    ) {
        self.root = appSupportRoot
        self.deletionStore = deletionStore
        self.queue = queue
    }

    /// Lets the recorder stop a session before its files are deleted.
    func setStopSessionHandler(
        _ handler: @escaping @Sendable (UUID?, Int64?) async -> Void
    ) {
        stopSessionHandler = handler
    }

    /// Lets a location deletion stop the live location writer without
    /// touching audio recording.
    func setStopLocationSessionHandler(
        _ handler: @escaping @Sendable (UUID) async -> Void
    ) {
        stopLocationSessionHandler = handler
    }

    func apply(_ command: DeletionCommand, now: Date = Date()) async {
        guard command.isValid else {
            logger.error("ignored invalid deletion command")
            return
        }
        _ = await deletionStore.apply(command)
        let nowMs = TimeMath.epochMs(now)

        switch command.scope {
        case .chunk:
            guard let chunkID = command.entityID else {
                return
            }
            let entries = await queue.entries()
            let matching = entries.filter {
                $0.envelope.chunkID == chunkID
            }
            if matching.isEmpty {
                await deleteChunkByScan(
                    chunkID: chunkID,
                    tombstoneID: command.tombstoneID,
                    nowMs: nowMs
                )
            } else {
                for entry in matching {
                    removeFile(relativePath: entry.envelope.relativePath)
                    removeFile(
                        relativePath: sidecarPath(
                            for: entry.envelope.relativePath
                        )
                    )
                    await updateManifest(
                        sessionID: entry.envelope.sessionID,
                        sequence: entry.envelope.sequence,
                        tombstoneID: command.tombstoneID,
                        nowMs: nowMs
                    )
                }
            }
            await queue.applyDeletion(command, now: now)
        case .session:
            guard let sessionID = command.entityID else {
                return
            }
            await stopSessionHandler?(sessionID, nil)
            removeSession(sessionID: sessionID)
            await queue.applyDeletion(command, now: now)
        case .location:
            guard let sessionID = command.sessionID ?? command.entityID else {
                return
            }
            await stopLocationSessionHandler?(sessionID)
            removeLocationFiles(sessionIDs: [sessionID])
            await queue.applyDeletion(command, now: now)
        case .all:
            guard let epochMs = command.epochMs else {
                return
            }
            await stopSessionHandler?(nil, epochMs)
            let directories = sessionDirectories()
            var removed: Set<UUID> = []
            for directory in directories {
                guard let startedAtMs = directory.startedAtMs,
                    startedAtMs < epochMs
                else {
                    continue
                }
                removeSessionDirectory(directory.url)
                removed.insert(directory.sessionID)
            }
            removeLocationFiles(sessionIDs: removed)
            await queue.applyDeletion(command, now: now)
        }

        logger.info(
            "applied deletion scope \(command.scope.rawValue, privacy: .public)"
        )
    }

    private struct SessionDirectory {
        let sessionID: UUID
        let url: URL
        let startedAtMs: Int64?
    }

    private func sessionDirectories() -> [SessionDirectory] {
        let audioRoot = root.appending(
            path: "audio",
            directoryHint: .isDirectory
        )
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: audioRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else {
            return []
        }
        return contents.compactMap { url in
            guard
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                    == true,
                let sessionID = UUID(uuidString: url.lastPathComponent)
            else {
                return nil
            }
            return SessionDirectory(
                sessionID: sessionID,
                url: url,
                startedAtMs: sessionStartedAtMs(in: url)
            )
        }
    }

    private func sessionStartedAtMs(in directory: URL) -> Int64? {
        let manifestURL = directory.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(
                ChunkManifest.self,
                from: data
            )
        else {
            return nil
        }
        return manifest.sessionStartedAtMs
    }

    private func removeSession(sessionID: UUID) {
        let directory = root.appending(
            path: "audio",
            directoryHint: .isDirectory
        ).appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        removeSessionDirectory(directory)
        removeLocationFiles(sessionIDs: [sessionID])
    }

    private func removeSessionDirectory(_ directory: URL) {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "could not remove watch session: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func removeLocationFiles(sessionIDs: Set<UUID>) {
        guard !sessionIDs.isEmpty else {
            return
        }
        let locationRoot = root.appending(
            path: "location",
            directoryHint: .isDirectory
        )
        guard
            let enumerator = fileManager.enumerator(
                at: locationRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        let names = Set(
            sessionIDs.flatMap {
                [
                    $0.uuidString + ".jsonl",
                    $0.uuidString + ".jsonl.part",
                    $0.uuidString + ".gpx",
                ]
            }
        )
        for case let url as URL in enumerator
        where names.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func deleteChunkByScan(
        chunkID: UUID,
        tombstoneID: UUID,
        nowMs: Int64
    ) async {
        for directory in sessionDirectories() {
            guard
                let contents = try? fileManager.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            else {
                continue
            }
            for url in contents
            where url.pathExtension == "json"
                && url.lastPathComponent != "manifest.json"
            {
                guard let data = try? Data(contentsOf: url),
                    let metadata = try? JSONDecoder().decode(
                        ChunkMetadataSnapshot.self,
                        from: data
                    ), metadata.chunkID == chunkID
                else {
                    continue
                }
                let audioName = ChunkPath.fileName(
                    sequence: metadata.sequence,
                    startEpochMs: metadata.startedAtMs,
                    kind: .audio
                )
                let audioURL = directory.url.appending(path: audioName)
                try? fileManager.removeItem(at: audioURL)
                try? fileManager.removeItem(at: url)
                await updateManifest(
                    sessionID: directory.sessionID,
                    sequence: metadata.sequence,
                    tombstoneID: tombstoneID,
                    nowMs: nowMs
                )
                return
            }
        }
    }

    private func updateManifest(
        sessionID: UUID,
        sequence: Int,
        tombstoneID: UUID,
        nowMs: Int64
    ) async {
        let directory = root.appending(
            path: "audio",
            directoryHint: .isDirectory
        ).appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        let manifestURL = directory.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
            var manifest = try? JSONDecoder().decode(
                ChunkManifest.self,
                from: data
            )
        else {
            return
        }
        manifest.setLocalState(
            sequence: sequence,
            localState: .deleted,
            tombstoneID: tombstoneID,
            nowMs: nowMs
        )
        let writer = AtomicFileWriter(directory: directory)
        do {
            _ = try await writer.writeJSON(
                manifest,
                fileName: "manifest.json",
                overwrite: true
            )
        } catch {
            logger.error(
                "watch manifest update failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func removeFile(relativePath: String) {
        let url = root.appending(path: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    private func sidecarPath(for relativePath: String) -> String {
        (relativePath as NSString).deletingPathExtension + ".json"
    }
}
