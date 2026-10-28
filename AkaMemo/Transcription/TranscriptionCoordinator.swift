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

    /// Unit tests run inside the app and share its container. Starting a
    /// transcription there can raise the system speech prompt and block the
    /// test host, so the queue stays idle under XCTest.
    private var isSuppressedForTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
            != nil
    }

    func start() async {
        guard !isSuppressedForTesting, !isRunning else {
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
