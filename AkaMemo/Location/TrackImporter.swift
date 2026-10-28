import AkaMemoCore
import Foundation
import OSLog
import SwiftData

struct LocationTrackInsert: Sendable, Equatable {
    let trackID: UUID
    let sessionID: UUID
    let sessionStartedAt: Date
    let startedAt: Date
    let endedAt: Date
    let pointCount: Int
    let distanceMeters: Double?
    let relativePath: String
    let checksumSHA256: String
    let importedAt: Date
}

@ModelActor
actor LocationTrackStore {
    func contains(trackID: UUID, checksumSHA256: String) throws -> Bool {
        var descriptor = FetchDescriptor<LocationTrackRecord>(
            predicate: #Predicate { record in
                record.trackID == trackID
                    && record.checksumSHA256 == checksumSHA256
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func insert(_ value: LocationTrackInsert) throws {
        modelContext.insert(
            LocationTrackRecord(
                trackID: value.trackID,
                sessionID: value.sessionID,
                sessionStartedAt: value.sessionStartedAt,
                startedAt: value.startedAt,
                endedAt: value.endedAt,
                pointCount: value.pointCount,
                distanceMeters: value.distanceMeters,
                stateRaw: "completed",
                relativePath: value.relativePath,
                checksumSHA256: value.checksumSHA256,
                importedAt: value.importedAt
            )
        )
        try modelContext.save()
    }
}

/// Validates and stores a Watch track file. Rejects deleted sessions and
/// malformed files; a duplicate `trackID + checksum` is accepted once.
actor TrackImporter {
    enum Result: Sendable, Equatable {
        case accepted(Int)
        case duplicate
        case rejected(String)
    }

    private let store: LocationTrackStore
    private let applicationSupport: URL
    private let deletionStore: DeletionStore?
    private let diagnostics: AppDiagnostics?
    private let fileManager = FileManager.default
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "location"
    )

    init(
        store: LocationTrackStore,
        applicationSupport: URL,
        deletionStore: DeletionStore?,
        diagnostics: AppDiagnostics?
    ) {
        self.store = store
        self.applicationSupport = applicationSupport
        self.deletionStore = deletionStore
        self.diagnostics = diagnostics
    }

    func importFile(
        at fileURL: URL,
        envelope: TrackTransferEnvelope,
        now: Date = Date()
    ) async -> Result {
        guard envelope.isValid else {
            return .rejected("invalidEnvelope")
        }
        if let deletionStore {
            do {
                switch try await deletionStore.matchForTrack(
                    sessionID: envelope.sessionID,
                    sessionStartedAtMs: envelope.sessionStartedAtMs
                ) {
                case .none, .audio:
                    // An audio purge does not touch location tracks.
                    break
                case .session, .chunk, .location, .epoch:
                    try? fileManager.removeItem(at: fileURL)
                    return .rejected("deletedSession")
                }
            } catch {
                return .rejected("deletionCheckFailed")
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .rejected("readFailed")
        }
        let checksum = AtomicFileWriter.sha256Hex(data)
        guard
            checksum.caseInsensitiveCompare(envelope.checksumSHA256)
                == .orderedSame
        else {
            return .rejected("checksumMismatch")
        }
        let decoded = LocationTrackCodec.decode(data)
        guard decoded.invalidLineCount == 0 else {
            return .rejected("invalidLines")
        }
        guard decoded.points.count == envelope.pointCount else {
            return .rejected("pointCountMismatch")
        }
        guard isMonotonic(decoded.points) else {
            return .rejected("nonMonotonic")
        }

        do {
            if try await store.contains(
                trackID: envelope.trackID,
                checksumSHA256: envelope.checksumSHA256
            ) {
                try? fileManager.removeItem(at: fileURL)
                return .duplicate
            }
        } catch {
            return .rejected("lookupFailed")
        }

        let relativePath = TrackPaths.relativePath(
            sessionStartedAtMs: envelope.sessionStartedAtMs,
            sessionID: envelope.sessionID
        )
        let destination = applicationSupport.appending(path: relativePath)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try Data(contentsOf: destination)
                guard
                    AtomicFileWriter.sha256Hex(existing)
                        .caseInsensitiveCompare(checksum) == .orderedSame
                else {
                    return .rejected("destinationConflict")
                }
                try? fileManager.removeItem(at: fileURL)
                return .duplicate
            }
            try fileManager.moveItem(at: fileURL, to: destination)
        } catch {
            return .rejected("storageFailed")
        }

        let value = LocationTrackInsert(
            trackID: envelope.trackID,
            sessionID: envelope.sessionID,
            sessionStartedAt: TimeMath.date(
                epochMs: envelope.sessionStartedAtMs
            ),
            startedAt: TimeMath.date(epochMs: envelope.startedAtMs),
            endedAt: TimeMath.date(epochMs: envelope.endedAtMs),
            pointCount: decoded.points.count,
            distanceMeters: LocationTrackCodec.distanceMeters(decoded.points),
            relativePath: relativePath,
            checksumSHA256: checksum,
            importedAt: now
        )
        do {
            try await store.insert(value)
        } catch {
            try? fileManager.removeItem(at: destination)
            return .rejected("persistenceFailed")
        }

        logger.info("track imported with \(decoded.points.count, privacy: .public) points")
        await diagnostics?.log(
            level: .info,
            category: .location,
            message: "track imported",
            metadata: ["count": "\(decoded.points.count)"]
        )
        return .accepted(decoded.points.count)
    }

    private func isMonotonic(_ points: [LocationPoint]) -> Bool {
        guard points.count > 1 else {
            return true
        }
        for index in 1..<points.count
        where points[index].timestampMs <= points[index - 1].timestampMs {
            return false
        }
        return true
    }
}
