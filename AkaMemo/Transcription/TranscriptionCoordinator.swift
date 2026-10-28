import Foundation
import Observation

/// Drives the transcription queue from the UI while keeping the work off the
/// main actor. Runs are serialized: a second request waits for the first.
@MainActor
@Observable
final class TranscriptionCoordinator {
    private let service: TranscriptionService
    private(set) var isRunning = false
    private(set) var lastRun: TranscriptionService.RunSummary?

    init(service: TranscriptionService) {
        self.service = service
    }

    func start() async {
        guard !isRunning else {
            return
        }
        isRunning = true
        defer { isRunning = false }
        lastRun = await service.runDueTasks()
    }

    func retry(chunkID: UUID) async {
        await service.retry(chunkID: chunkID)
        await start()
    }
}
