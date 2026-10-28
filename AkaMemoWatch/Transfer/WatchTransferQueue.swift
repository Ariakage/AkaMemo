import AkaMemoCore
import Foundation
import OSLog

protocol ChunkTransferTransport: AnyObject, Sendable {
    /// Starts a background file transfer. Returns false when the session is
    /// not activated or the file cannot be queued.
    func transferFile(at url: URL, metadata: [String: String]) -> Bool
}

/// Persistent queue for Watch -> iPhone chunk transfers.
///
/// The queue survives app relaunches (`queue/transfer-manifest.json`).
/// A transfer that succeeds is only `received` until the phone sends an
/// application-level confirmation; `confirmed` chunks are never re-sent.
actor WatchTransferQueue {
    private let appSupportRoot: URL
    private let writer: AtomicFileWriter
    private let deletionStore: WatchDeletionStore?
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "transfer")
    private var document: ChunkTransferQueueDocument
    private var transport: (any ChunkTransferTransport)?
    private var retryTask: Task<Void, Never>?

    init(appSupportRoot: URL, deletionStore: WatchDeletionStore? = nil) {
        self.appSupportRoot = appSupportRoot
        self.deletionStore = deletionStore
        let directory = appSupportRoot.appending(path: "queue", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.writer = AtomicFileWriter(directory: directory)
        let queueURL = directory.appending(path: "transfer-manifest.json")
        if let data = try? Data(contentsOf: queueURL),
            var loaded = try? JSONDecoder().decode(ChunkTransferQueueDocument.self, from: data)
        {
            for index in loaded.entries.indices
            where loaded.entries[index].state == .transferring {
                loaded.entries[index].state = .queued
                loaded.entries[index].nextAttemptAtMs = TimeMath.epochMs(Date())
            }
            self.document = loaded
        } else {
            self.document = ChunkTransferQueueDocument()
        }
    }

    func setTransport(_ transport: any ChunkTransferTransport) {
        self.transport = transport
    }

    func activate(with transport: any ChunkTransferTransport) {
        setTransport(transport)
        guard retryTask == nil else {
            Task { await self.tick() }
            return
        }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5_000))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
        Task { await self.tick() }
    }

    func enqueue(_ envelope: ChunkTransferEnvelope, now: Date = Date()) async {
        guard envelope.isValid else {
            logger.error("rejected invalid transfer envelope")
            return
        }
        if let deletionStore,
            await deletionStore.isDeleted(
                chunkID: envelope.chunkID,
                sessionID: envelope.sessionID,
                sessionStartedAtMs: envelope.sessionStartedAtMs
            )
        {
            return
        }
        let nowMs = TimeMath.epochMs(now)
        if let existing = document.entry(chunkID: envelope.chunkID) {
            guard existing.state != .confirmed else { return }
        }
        var entry =
            document.entry(chunkID: envelope.chunkID)
            ?? ChunkTransferQueueEntry(
                envelope: envelope,
                state: .queued,
                attemptCount: 0,
                nextAttemptAtMs: nowMs,
                updatedAtMs: nowMs
            )
        entry.envelope = envelope
        entry.state = .queued
        entry.nextAttemptAtMs = nowMs
        entry.updatedAtMs = nowMs
        document.upsert(entry)
        await persist()
        await tick(now: now)
    }

    func tick(now: Date = Date()) async {
        guard let transport else {
            return
        }
        let nowMs = TimeMath.epochMs(now)
        var didChange = false
        let chunkIDs = document.entries.map(\.envelope.chunkID)

        for chunkID in chunkIDs {
            guard
                let index = document.entries.firstIndex(where: {
                    $0.envelope.chunkID == chunkID
                })
            else {
                continue
            }
            var entry = document.entries[index]

            if let deletionStore,
                await deletionStore.isDeleted(
                    chunkID: entry.envelope.chunkID,
                    sessionID: entry.envelope.sessionID,
                    sessionStartedAtMs: entry.envelope.sessionStartedAtMs
                )
            {
                document.entries.remove(at: index)
                didChange = true
                continue
            }

            if entry.state == .transferring, nowMs - entry.updatedAtMs > 300_000 {
                entry.state = .queued
                entry.nextAttemptAtMs = nowMs
            }

            switch entry.state {
            case .confirmed, .verified, .transferring, .localOnly, .corrupt:
                continue
            case .queued, .failed, .received:
                guard entry.nextAttemptAtMs <= nowMs else {
                    continue
                }
                if entry.state == .received {
                    entry.state = .queued
                }
            @unknown default:
                continue
            }

            guard entry.envelope.isValid else {
                entry.state = .corrupt
                entry.lastErrorCode = "invalidEnvelope"
                entry.nextAttemptAtMs = 0
                entry.updatedAtMs = nowMs
                document.entries[index] = entry
                didChange = true
                continue
            }

            let fileURL = appSupportRoot.appending(path: entry.envelope.relativePath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                entry.attemptCount += 1
                entry.state = .failed
                entry.lastErrorCode = "fileMissing"
                entry.nextAttemptAtMs = TransferRetryPolicy.nextAttemptAtMs(
                    attempt: entry.attemptCount,
                    nowMs: nowMs
                )
                entry.updatedAtMs = nowMs
                document.entries[index] = entry
                didChange = true
                continue
            }

            guard let payload = try? entry.envelope.jsonString() else {
                entry.attemptCount += 1
                entry.state = .failed
                entry.lastErrorCode = "envelopeEncodingFailed"
                entry.nextAttemptAtMs = TransferRetryPolicy.nextAttemptAtMs(
                    attempt: entry.attemptCount,
                    nowMs: nowMs
                )
                entry.updatedAtMs = nowMs
                document.entries[index] = entry
                didChange = true
                continue
            }

            let metadata = [
                "chunkID": entry.envelope.chunkID.uuidString,
                ChunkTransferEnvelope.metadataKey: payload,
            ]
            if transport.transferFile(at: fileURL, metadata: metadata) {
                entry.state = .transferring
                entry.attemptCount = 0
                entry.lastErrorCode = nil
                entry.updatedAtMs = nowMs
            } else {
                entry.attemptCount += 1
                entry.state = .failed
                entry.lastErrorCode = "transferUnavailable"
                entry.nextAttemptAtMs = TransferRetryPolicy.nextAttemptAtMs(
                    attempt: entry.attemptCount,
                    nowMs: nowMs
                )
                entry.updatedAtMs = nowMs
            }
            document.entries[index] = entry
            didChange = true
        }

        if didChange {
            await persist()
        }
    }

    func handleTransferFinished(
        chunkID: UUID?,
        errorCode: String?,
        now: Date = Date()
    ) async {
        guard let chunkID, var entry = document.entry(chunkID: chunkID) else {
            return
        }
        let nowMs = TimeMath.epochMs(now)
        if let errorCode {
            entry.attemptCount += 1
            entry.state = .failed
            entry.lastErrorCode = String(errorCode.prefix(120))
            entry.nextAttemptAtMs = TransferRetryPolicy.nextAttemptAtMs(
                attempt: entry.attemptCount,
                nowMs: nowMs
            )
            logger.warning("chunk transfer failed; retry scheduled")
        } else {
            entry.state = .received
            entry.attemptCount = 0
            entry.lastErrorCode = nil
            entry.nextAttemptAtMs = TransferRetryPolicy.acknowledgementDeadlineMs(
                nowMs: nowMs
            )
        }
        entry.updatedAtMs = nowMs
        document.upsert(entry)
        await persist()
    }

    func handleConfirmation(
        chunkID: UUID,
        checksum: String,
        now: Date = Date()
    ) async {
        guard var entry = document.entry(chunkID: chunkID) else {
            return
        }
        guard
            entry.envelope.checksumSHA256.caseInsensitiveCompare(checksum) == .orderedSame
        else {
            logger.warning("confirmation checksum mismatch")
            return
        }
        entry.state = .confirmed
        entry.lastErrorCode = nil
        entry.nextAttemptAtMs = 0
        entry.updatedAtMs = TimeMath.epochMs(now)
        document.upsert(entry)
        await persist()
    }

    /// Adds sealed chunks that are not in the queue yet. This covers chunks
    /// recorded before the transfer queue existed and chunks sealed just
    /// before a process exit.
    func enqueueSealedChunksNotInQueue(now: Date = Date()) async {
        let nowMs = TimeMath.epochMs(now)
        let audioRoot = appSupportRoot.appending(path: "audio", directoryHint: .isDirectory)
        guard
            let sessionDirectories = try? fileManager.contentsOfDirectory(
                at: audioRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else {
            return
        }

        var didChange = false
        for sessionDirectory in sessionDirectories {
            guard
                (try? sessionDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                    == true,
                UUID(uuidString: sessionDirectory.lastPathComponent) != nil
            else {
                continue
            }
            let manifestURL = sessionDirectory.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(ChunkManifest.self, from: data)
            else {
                continue
            }

            for entry in manifest.entries where entry.localState == .present {
                guard entry.sequence >= 0, entry.startedAtMs > 0 else {
                    continue
                }
                let sidecarName = ChunkPath.fileName(
                    sequence: entry.sequence,
                    startEpochMs: entry.startedAtMs,
                    kind: .metadata
                )
                let sidecarURL = sessionDirectory.appending(path: sidecarName)
                guard let sidecarData = try? Data(contentsOf: sidecarURL),
                    let metadata = try? JSONDecoder().decode(
                        ChunkMetadataSnapshot.self,
                        from: sidecarData
                    )
                else {
                    continue
                }
                if document.entry(chunkID: metadata.chunkID) != nil {
                    continue
                }
                if let deletionStore,
                    await deletionStore.isDeleted(
                        chunkID: metadata.chunkID,
                        sessionID: metadata.sessionID,
                        sessionStartedAtMs: metadata.sessionStartedAtMs
                    )
                {
                    continue
                }
                let envelope = ChunkTransferEnvelope(
                    chunkID: metadata.chunkID,
                    sessionID: metadata.sessionID,
                    sessionStartedAtMs: metadata.sessionStartedAtMs,
                    sequence: metadata.sequence,
                    startedAtMs: metadata.startedAtMs,
                    durationMs: metadata.durationMs,
                    byteSize: metadata.byteSize,
                    checksumSHA256: metadata.checksumSHA256,
                    formatVersion: metadata.formatVersion,
                    sampleRate: metadata.sampleRate,
                    channels: metadata.channels,
                    bitRate: metadata.bitRate,
                    relativePath: metadata.relativePath
                )
                guard envelope.isValid else {
                    continue
                }
                document.upsert(
                    ChunkTransferQueueEntry(
                        envelope: envelope,
                        state: .queued,
                        attemptCount: 0,
                        nextAttemptAtMs: nowMs,
                        updatedAtMs: nowMs
                    )
                )
                didChange = true
            }
        }

        if didChange {
            await persist()
            await tick(now: now)
        }
    }

    func entries() -> [ChunkTransferQueueEntry] {
        document.entries
    }

    /// Drops queued, transferring, received, and confirmed entries that fall
    /// inside a deletion command. Returns after persisting the queue.
    func applyDeletion(_ command: DeletionCommand, now: Date = Date()) async {
        let before = document.entries.count
        switch command.scope {
        case .chunk:
            if let chunkID = command.entityID {
                document.entries.removeAll {
                    $0.envelope.chunkID == chunkID
                }
            }
        case .session:
            if let sessionID = command.entityID ?? command.sessionID {
                document.entries.removeAll {
                    $0.envelope.sessionID == sessionID
                }
            }
        case .location:
            break
        case .all:
            if let epochMs = command.epochMs {
                document.entries.removeAll {
                    $0.envelope.sessionStartedAtMs < epochMs
                }
            }
        }
        if document.entries.count != before {
            await persist()
        }
    }

    private func persist() async {
        document.entries.sort {
            $0.envelope.startedAtMs < $1.envelope.startedAtMs
        }
        do {
            _ = try await writer.writeJSON(
                document,
                fileName: "transfer-manifest.json",
                overwrite: true
            )
        } catch {
            logger.error(
                "transfer queue persist failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
