import Foundation
import Observation

@MainActor
@Observable
final class DeletionCoordinator {
    private let service: DeletionService?
    private(set) var isDeleting = false
    private(set) var errorMessage: String?

    init(service: DeletionService?) {
        self.service = service
    }

    func deleteChunk(_ chunkID: UUID) async -> Bool {
        await perform {
            try await service?.deleteChunk(chunkID)
        }
    }

    func deleteSession(_ sessionID: UUID) async -> Bool {
        await perform {
            try await service?.deleteSession(sessionID)
        }
    }

    func deleteTrack(_ trackID: UUID, sessionID: UUID) async -> Bool {
        await perform {
            try await service?.deleteTrack(trackID, sessionID: sessionID)
        }
    }

    func deleteAll() async -> Bool {
        await perform {
            try await service?.deleteAll()
        }
    }

    private func perform(
        _ operation: () async throws -> Void
    ) async -> Bool {
        guard !isDeleting else {
            return false
        }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await operation()
            return true
        } catch {
            errorMessage = String(localized: "deletion.error")
            return false
        }
    }
}
