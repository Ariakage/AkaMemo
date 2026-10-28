import AVFoundation
import AkaMemoCore
import Foundation
import OSLog

/// Rebuilds the chunk index after an unclean exit.
///
/// Scans `audio/<sessionUUID>/.parts` for chunks left by a terminated process.
/// Readable chunks become sealed `.m4a` files with a JSON sidecar and a
/// manifest entry; unreadable chunks are renamed `.m4a.corrupt` and kept.
/// The scan is idempotent and never deletes an unreadable chunk.
actor ChunkRecoveryService {
    struct Summary: Sendable, Equatable {
        var sessionsScanned = 0
        var recoveredChunks = 0
        var rebuiltSidecars = 0
        var quarantinedChunks = 0
    }

    private struct AudioInspection {
        let frames: AVAudioFramePosition
        let sampleRate: Double
        let channels: Int

        var durationMs: Int {
            guard sampleRate > 0 else { return 1 }
            return max(1, Int((Double(frames) / sampleRate * 1000).rounded()))
        }
    }

    private enum RecoveryError: Error {
        case emptyChunk
        case invalidFormat
    }

    private let audioRoot: URL
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.ariakage.AkaMemo", category: "storage")

    init(audioRoot: URL) {
        self.audioRoot = audioRoot
    }

    func recoverAll() async -> Summary {
        var summary = Summary()
        guard
            let directories = try? fileManager.contentsOfDirectory(
                at: audioRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else {
            return summary
        }

        for directory in directories {
            guard
                (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                let sessionID = UUID(uuidString: directory.lastPathComponent)
            else {
                continue
            }
            summary.sessionsScanned += 1
            do {
                let sessionSummary = try await recoverSession(
                    at: directory,
                    sessionID: sessionID
                )
                summary.recoveredChunks += sessionSummary.recoveredChunks
                summary.rebuiltSidecars += sessionSummary.rebuiltSidecars
                summary.quarantinedChunks += sessionSummary.quarantinedChunks
            } catch {
                logger.error(
                    "session recovery failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return summary
    }

    private func recoverSession(
        at directory: URL,
        sessionID: UUID
    ) async throws -> Summary {
        var summary = Summary()
        let partsDirectory = directory.appending(path: ".parts", directoryHint: .isDirectory)
        let finalFiles = audioFiles(in: directory)
        let partFiles = audioFiles(in: partsDirectory)
        guard !finalFiles.isEmpty || !partFiles.isEmpty else {
            return summary
        }

        let writer = AtomicFileWriter(directory: directory)
        var manifest =
            loadManifest(at: directory)
            ?? ChunkManifest(
                sessionID: sessionID,
                sessionStartedAtMs: earliestStart(in: finalFiles + partFiles)
            )
        var didChange = false

        for partURL in partFiles {
            guard let parsed = ChunkPath.parseFileName(partURL.lastPathComponent) else {
                continue
            }
            let finalURL = directory.appending(path: partURL.lastPathComponent)
            if fileManager.fileExists(atPath: finalURL.path) {
                logger.warning("orphan part file left in place because the final exists")
                continue
            }

            do {
                let inspection = try inspectAudio(at: partURL)
                guard inspection.frames > 0 else {
                    throw RecoveryError.emptyChunk
                }
                let data = try Data(contentsOf: partURL)
                let checksum = AtomicFileWriter.sha256Hex(data)
                let sidecarName = ChunkPath.fileName(
                    sequence: parsed.sequence,
                    startEpochMs: parsed.startEpochMs,
                    kind: .metadata
                )
                let sidecarURL = directory.appending(path: sidecarName)
                let metadata: ChunkMetadataSnapshot
                if let data = try? Data(contentsOf: sidecarURL),
                    let existing = try? JSONDecoder().decode(
                        ChunkMetadataSnapshot.self,
                        from: data
                    )
                {
                    metadata = existing
                } else {
                    metadata = ChunkMetadataSnapshot(
                        chunkID: UUID(),
                        sessionID: sessionID,
                        sessionStartedAtMs: manifest.sessionStartedAtMs,
                        sequence: parsed.sequence,
                        startedAtMs: parsed.startEpochMs,
                        durationMs: inspection.durationMs,
                        byteSize: data.count,
                        checksumSHA256: checksum,
                        sampleRate: Int(inspection.sampleRate.rounded()),
                        channels: inspection.channels,
                        relativePath: "audio/\(sessionID.uuidString)/\(finalURL.lastPathComponent)",
                        createdAtMs: TimeMath.epochMs(Date())
                    )
                    _ = try await writer.writeJSON(
                        metadata,
                        fileName: sidecarName,
                        overwrite: true
                    )
                    summary.rebuiltSidecars += 1
                }

                try fileManager.moveItem(at: partURL, to: finalURL)
                applySealedFileProtection(at: finalURL)
                manifest.upsert(
                    ChunkManifest.Entry(
                        chunkID: metadata.chunkID,
                        sequence: metadata.sequence,
                        startedAtMs: metadata.startedAtMs,
                        localState: .present,
                        checksumSHA256: metadata.checksumSHA256,
                        byteSize: metadata.byteSize,
                        updatedAtMs: TimeMath.epochMs(Date())
                    )
                )
                didChange = true
                summary.recoveredChunks += 1
                logger.info(
                    "recovered chunk \(metadata.sequence, privacy: .public) of session"
                )
            } catch {
                quarantine(partURL, in: directory, summary: &summary)
            }
        }

        for finalURL in audioFiles(in: directory) {
            guard let parsed = ChunkPath.parseFileName(finalURL.lastPathComponent) else {
                continue
            }
            let sidecarName = ChunkPath.fileName(
                sequence: parsed.sequence,
                startEpochMs: parsed.startEpochMs,
                kind: .metadata
            )
            let sidecarURL = directory.appending(path: sidecarName)
            var metadata: ChunkMetadataSnapshot?
            if let data = try? Data(contentsOf: sidecarURL) {
                metadata = try? JSONDecoder().decode(ChunkMetadataSnapshot.self, from: data)
            }
            if metadata == nil {
                do {
                    let inspection = try inspectAudio(at: finalURL)
                    guard inspection.frames > 0 else {
                        throw RecoveryError.emptyChunk
                    }
                    let data = try Data(contentsOf: finalURL)
                    metadata = ChunkMetadataSnapshot(
                        chunkID: UUID(),
                        sessionID: sessionID,
                        sessionStartedAtMs: manifest.sessionStartedAtMs,
                        sequence: parsed.sequence,
                        startedAtMs: parsed.startEpochMs,
                        durationMs: inspection.durationMs,
                        byteSize: data.count,
                        checksumSHA256: AtomicFileWriter.sha256Hex(data),
                        sampleRate: Int(inspection.sampleRate.rounded()),
                        channels: inspection.channels,
                        relativePath: "audio/\(sessionID.uuidString)/\(finalURL.lastPathComponent)",
                        createdAtMs: TimeMath.epochMs(Date())
                    )
                    if let metadata {
                        _ = try await writer.writeJSON(
                            metadata,
                            fileName: sidecarName,
                            overwrite: true
                        )
                        summary.rebuiltSidecars += 1
                    }
                } catch {
                    logger.error(
                        "could not rebuild sidecar: \(String(describing: error), privacy: .public)"
                    )
                }
            }

            guard let metadata else { continue }
            if let existing = manifest.entry(sequence: parsed.sequence) {
                if existing.localState == .missing {
                    manifest.setLocalState(
                        sequence: parsed.sequence,
                        localState: .present,
                        nowMs: TimeMath.epochMs(Date())
                    )
                    didChange = true
                }
            } else {
                manifest.upsert(
                    ChunkManifest.Entry(
                        chunkID: metadata.chunkID,
                        sequence: metadata.sequence,
                        startedAtMs: metadata.startedAtMs,
                        localState: .present,
                        checksumSHA256: metadata.checksumSHA256,
                        byteSize: metadata.byteSize,
                        updatedAtMs: TimeMath.epochMs(Date())
                    )
                )
                didChange = true
            }
        }

        let observations = audioFiles(in: directory).compactMap { url -> ChunkFileObservation? in
            guard let parsed = ChunkPath.parseFileName(url.lastPathComponent) else {
                return nil
            }
            return ChunkFileObservation(
                sequence: parsed.sequence,
                startedAtMs: parsed.startEpochMs
            )
        }
        let result = manifest.reconcile(
            with: observations,
            nowMs: TimeMath.epochMs(Date())
        )
        if didChange || !result.addedSequences.isEmpty
            || !result.newlyMissingSequences.isEmpty
            || !result.recoveredSequences.isEmpty
        {
            _ = try await writer.writeJSON(
                manifest,
                fileName: "manifest.json",
                overwrite: true
            )
        }
        return summary
    }

    private func loadManifest(at directory: URL) -> ChunkManifest? {
        let url = directory.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ChunkManifest.self, from: data)
    }

    private func audioFiles(in directory: URL) -> [URL] {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        else {
            return []
        }
        return
            contents
            .filter { $0.pathExtension == ChunkFileKind.audio.rawValue }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func earliestStart(in files: [URL]) -> Int64 {
        files.compactMap { ChunkPath.parseFileName($0.lastPathComponent)?.startEpochMs }.min()
            ?? TimeMath.epochMs(Date())
    }

    private func inspectAudio(at url: URL) throws -> AudioInspection {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else {
            throw RecoveryError.invalidFormat
        }
        return AudioInspection(
            frames: file.length,
            sampleRate: sampleRate,
            channels: Int(file.processingFormat.channelCount)
        )
    }

    private func quarantine(
        _ partURL: URL,
        in directory: URL,
        summary: inout Summary
    ) {
        let corruptURL = directory.appending(
            path: partURL.lastPathComponent + ChunkFileSuffix.corrupt.rawValue
        )
        guard !fileManager.fileExists(atPath: corruptURL.path) else {
            logger.error("corrupt destination already exists; leaving part in place")
            return
        }
        do {
            try fileManager.moveItem(at: partURL, to: corruptURL)
            summary.quarantinedChunks += 1
            logger.error("quarantined unreadable chunk")
        } catch {
            logger.error(
                "could not quarantine chunk: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func applySealedFileProtection(at url: URL) {
        #if os(watchOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
    }
}
