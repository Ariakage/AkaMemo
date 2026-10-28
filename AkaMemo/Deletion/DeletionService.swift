import AkaMemoCore
import Foundation
import OSLog

protocol DeletionCommandSending: AnyObject, Sendable {
    /// Queues a deletion command for the Watch. Returns false when
    /// WatchConnectivity is unavailable; the tombstone stays unacknowledged
    /// and is resent on the next reachable session.
    func sendDeletion(_ command: DeletionCommand) -> Bool
}

/// Deletes local audio, transcripts, index entries, and metadata, then tells
/// the Watch. The tombstone is written before any destructive work.
actor DeletionService {
    private let store: DeletionStore
    private let applicationSupport: URL
    private let index: SQLiteSearchIndex?
    private let sender: (any DeletionCommandSending)?
    private let diagnostics: AppDiagnostics?
    private let fileManager = FileManager.default
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo",
        category: "storage"
    )

    init(
        store: DeletionStore,
        applicationSupport: URL,
        index: SQLiteSearchIndex?,
        sender: (any DeletionCommandSending)?,
        diagnostics: AppDiagnostics? = nil
    ) {
        self.store = store
        self.applicationSupport = applicationSupport
        self.index = index
        self.sender = sender
        self.diagnostics = diagnostics
    }

    func deleteChunk(_ chunkID: UUID) async throws {
        try await execute(
            scope: .chunk,
            entityID: chunkID,
            sessionID: nil,
            reason: "userDelete"
        )
    }

    func deleteSession(_ sessionID: UUID) async throws {
        try await execute(
            scope: .session,
            entityID: sessionID,
            sessionID: sessionID,
            reason: "userDelete"
        )
    }

    func deleteTrack(_ trackID: UUID, sessionID: UUID) async throws {
        try await execute(
            scope: .location,
            entityID: trackID,
            sessionID: sessionID,
            reason: "userDeleteTrack"
        )
    }

    func deleteAll() async throws {
        try await execute(
            scope: .all,
            entityID: nil,
            sessionID: nil,
            reason: "allData"
        )
    }

    private func execute(
        scope: DeletionScope,
        entityID: UUID?,
        sessionID: UUID?,
        reason: String
    ) async throws {
        do {
            let plan = try await store.prepareDeletion(
                scope: scope,
                entityID: entityID,
                sessionID: sessionID,
                reason: reason
            )
            try removeFiles(for: plan)
            if let index {
                switch scope {
                case .chunk:
                    if let entityID {
                        try await index.deleteChunk(entityID)
                    }
                case .session:
                    if let sessionID {
                        try await index.deleteSession(sessionID)
                    }
                case .location:
                    break
                case .all:
                    // Scoped per session so an entry that arrived after the
                    // epoch is not removed from the index.
                    for sessionID in plan.sessionIDs {
                        try await index.deleteSession(sessionID)
                    }
                }
            }
            try await store.completeDeletion(plan)
            if sender?.sendDeletion(plan.command) != true {
                logger.info(
                    "deletion command queued for later delivery, scope \(scope.rawValue, privacy: .public)"
                )
            }
            await diagnostics?.log(
                level: .info,
                category: .storage,
                message: "deletion completed",
                metadata: ["scope": scope.rawValue]
            )
        } catch {
            await diagnostics?.log(
                level: .error,
                category: .storage,
                message: "deletion failed",
                metadata: ["scope": scope.rawValue, "errorCode": "deleteFailed"]
            )
            throw error
        }
    }

    private func removeFiles(for plan: DeletionPlan) throws {
        for target in plan.targets {
            let audioURL = applicationSupport.appending(path: target.relativePath)
            try removeIfExists(audioURL)
            let sidecarURL = audioURL.deletingPathExtension()
                .appendingPathExtension("json")
            try removeIfExists(sidecarURL)
        }
        for relativePath in plan.transcriptPaths {
            let url = applicationSupport.appending(path: relativePath)
            try removeIfExists(url)
        }
        if plan.scope == .location, let relativePath = plan.locationRelativePath {
            try removeIfExists(
                applicationSupport.appending(path: relativePath)
            )
        }
        try removeLocationFiles(sessionIDs: plan.sessionIDs)
    }

    private func removeLocationFiles(sessionIDs: [UUID]) throws {
        guard !sessionIDs.isEmpty else {
            return
        }
        let locationRoot = applicationSupport.appending(
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
            sessionIDs.flatMap { [$0.uuidString + ".jsonl", $0.uuidString + ".gpx"] }
        )
        for case let url as URL in enumerator
        where names.contains(url.lastPathComponent) {
            try removeIfExists(url)
        }
    }

    private func removeIfExists(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }
}
