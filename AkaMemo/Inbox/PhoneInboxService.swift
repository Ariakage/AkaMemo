import AVFoundation
import AkaMemoCore
import Foundation
import OSLog

/// Verifies and stores chunks received from the Watch.
///
/// The service is idempotent: a chunk with the same ID and checksum is a
/// duplicate. The audio file is moved into the iPhone archive before the
/// SwiftData record is written; if the record fails, the file is removed so
/// the Watch can retry.
actor PhoneInboxService {
    enum Result: Sendable, Equatable {
        case accepted
        case duplicate
        case rejected(String)
    }

    private let store: MemoryStore
    private let applicationSupport: URL
    private let deletionStore: DeletionStore?
    private let diagnostics: AppDiagnostics?
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "storage")

    init(
        store: MemoryStore,
        applicationSupport: URL,
        deletionStore: DeletionStore? = nil,
        diagnostics: AppDiagnostics? = nil
    ) {
        self.store = store
        self.applicationSupport = applicationSupport
        self.deletionStore = deletionStore
        self.diagnostics = diagnostics
    }

    func receive(
        fileURL: URL,
        envelope: ChunkTransferEnvelope,
        receivedAt: Date = Date()
    ) async -> Result {
        guard envelope.isValid else {
            return .rejected("invalidEnvelope")
        }
        if let deletionStore {
            do {
                switch try await deletionStore.matchForInbox(
                    chunkID: envelope.chunkID,
                    sessionID: envelope.sessionID,
                    sessionStartedAtMs: envelope.sessionStartedAtMs
                ) {
                case .none:
                    break
                case .chunk:
                    try? fileManager.removeItem(at: fileURL)
                    await logRejection("deletedChunk", envelope: envelope)
                    return .rejected("deletedChunk")
                case .session:
                    try? fileManager.removeItem(at: fileURL)
                    await logRejection("deletedSession", envelope: envelope)
                    return .rejected("deletedSession")
                case .audio:
                    try? fileManager.removeItem(at: fileURL)
                    await logRejection("audioPurged", envelope: envelope)
                    return .rejected("audioPurged")
                case .location:
                    // Only the track was deleted; this session's audio still
                    // belongs in the library.
                    break
                case .epoch:
                    try? fileManager.removeItem(at: fileURL)
                    await logRejection("deletedEpoch", envelope: envelope)
                    return .rejected("deletedEpoch")
                }
            } catch {
                logger.error(
                    "deletion lookup failed: \(String(describing: error), privacy: .public)"
                )
                return .rejected("deletionCheckFailed")
            }
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let number = attributes[.size] as? NSNumber else {
                return .rejected("sizeMissing")
            }
            let byteSize = number.intValue
            guard byteSize > 0, byteSize == envelope.byteSize else {
                return .rejected("sizeMismatch")
            }

            let data = try Data(contentsOf: fileURL)
            let checksum = AtomicFileWriter.sha256Hex(data)
            guard checksum.caseInsensitiveCompare(envelope.checksumSHA256) == .orderedSame else {
                return .rejected("checksumMismatch")
            }
            guard durationMatches(fileURL: fileURL, expectedMs: envelope.durationMs) else {
                return .rejected("durationMismatch")
            }

            if try await store.contains(
                chunkID: envelope.chunkID,
                checksumSHA256: envelope.checksumSHA256
            ) {
                try? fileManager.removeItem(at: fileURL)
                await diagnostics?.log(
                    level: .debug,
                    category: .transfer,
                    message: "chunk duplicate",
                    metadata: ["chunkSeq": "\(envelope.sequence)"]
                )
                return .duplicate
            }
            if try await store.contains(chunkID: envelope.chunkID) {
                return .rejected("chunkIDConflict")
            }
            if try await store.contains(
                sessionID: envelope.sessionID,
                sequence: envelope.sequence
            ) {
                return .rejected("sequenceConflict")
            }

            let relativePath = archiveRelativePath(for: envelope)
            let destination = applicationSupport.appending(path: relativePath)
            let destinationDirectory = destination.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: destination.path) {
                let existingData = try Data(contentsOf: destination)
                let existingChecksum = AtomicFileWriter.sha256Hex(existingData)
                guard existingChecksum.caseInsensitiveCompare(checksum) == .orderedSame else {
                    return .rejected("destinationChecksumMismatch")
                }
                let alreadyStored = try await store.contains(
                    chunkID: envelope.chunkID,
                    checksumSHA256: envelope.checksumSHA256
                )
                if !alreadyStored {
                    try await store.insert(
                        envelope: envelope,
                        relativePath: relativePath,
                        receivedAt: receivedAt
                    )
                }
                try? fileManager.removeItem(at: fileURL)
                return .duplicate
            }

            try fileManager.moveItem(at: fileURL, to: destination)

            do {
                try await writeSidecar(
                    envelope: envelope,
                    relativePath: relativePath,
                    directory: destinationDirectory,
                    receivedAt: receivedAt
                )
                try await store.insert(
                    envelope: envelope,
                    relativePath: relativePath,
                    receivedAt: receivedAt
                )
            } catch {
                try? fileManager.removeItem(at: destination)
                logger.error(
                    "inbox persistence failed: \(String(describing: error), privacy: .public)"
                )
                return .rejected("persistenceFailed")
            }

            await diagnostics?.log(
                level: .info,
                category: .transfer,
                message: "chunk accepted",
                metadata: [
                    "chunkSeq": "\(envelope.sequence)",
                    "byteSize": "\(envelope.byteSize)",
                ]
            )
            NotificationCenter.default.post(
                name: .akamemoInboxAcceptedChunk,
                object: nil
            )
            return .accepted
        } catch {
            logger.error(
                "inbox receive failed: \(String(describing: error), privacy: .public)"
            )
            return .rejected("processingFailed")
        }
    }

    private func logRejection(
        _ code: String,
        envelope: ChunkTransferEnvelope
    ) async {
        await diagnostics?.log(
            level: .warning,
            category: .transfer,
            message: "chunk rejected",
            metadata: [
                "errorCode": code,
                "chunkSeq": "\(envelope.sequence)",
            ]
        )
    }

    private func durationMatches(fileURL: URL, expectedMs: Int) -> Bool {
        guard let file = try? AVAudioFile(forReading: fileURL),
            file.processingFormat.sampleRate > 0
        else {
            return false
        }
        let durationMs = Double(file.length) / file.processingFormat.sampleRate * 1000
        return abs(durationMs - Double(expectedMs)) <= 2_000
    }

    private func archiveRelativePath(for envelope: ChunkTransferEnvelope) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let date = TimeMath.date(epochMs: envelope.sessionStartedAtMs)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let fileName = ChunkPath.fileName(
            sequence: envelope.sequence,
            startEpochMs: envelope.startedAtMs,
            kind: .audio
        )
        return
            "audio/\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))/\(envelope.sessionID.uuidString)/\(fileName)"
    }

    private func writeSidecar(
        envelope: ChunkTransferEnvelope,
        relativePath: String,
        directory: URL,
        receivedAt: Date
    ) async throws {
        let metadata = ChunkMetadataSnapshot(
            chunkID: envelope.chunkID,
            sessionID: envelope.sessionID,
            sessionStartedAtMs: envelope.sessionStartedAtMs,
            sequence: envelope.sequence,
            startedAtMs: envelope.startedAtMs,
            durationMs: envelope.durationMs,
            byteSize: envelope.byteSize,
            checksumSHA256: envelope.checksumSHA256,
            formatVersion: envelope.formatVersion,
            sampleRate: envelope.sampleRate,
            channels: envelope.channels,
            bitRate: envelope.bitRate,
            relativePath: relativePath,
            createdAtMs: TimeMath.epochMs(receivedAt)
        )
        let sidecarName = ChunkPath.fileName(
            sequence: envelope.sequence,
            startEpochMs: envelope.startedAtMs,
            kind: .metadata
        )
        let writer = AtomicFileWriter(directory: directory)
        _ = try await writer.writeJSON(
            metadata,
            fileName: sidecarName,
            overwrite: true
        )
    }
}

extension Notification.Name {
    /// Posted after a chunk is verified and stored. Carries no user content.
    static let akamemoInboxAcceptedChunk = Notification.Name(
        "AkaMemo.inboxAcceptedChunk"
    )
}
