import AkaMemoCore
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PhoneAppModel {
    let container: ModelContainer?
    let transcription: TranscriptionCoordinator?
    let search: SearchCoordinator?
    let deletion: DeletionCoordinator?
    let diagnostics: AppDiagnostics?
    let battery: BatteryAlertCoordinator?
    private let connectivity: PhoneConnectivityService?
    #if DEBUG
        private let store: MemoryStore?
        private let inbox: PhoneInboxService?
    #endif
    private(set) var setupFailed = false

    init() {
        do {
            let container = try ModelContainer(
                for: ReceivedChunkRecord.self,
                TranscriptRecord.self,
                TranscriptSegmentRecord.self,
                TranscriptionTaskRecord.self,
                DeletionTombstoneRecord.self,
                DataEpochRecord.self,
                LocationTrackRecord.self
            )
            let root = try PhonePaths.applicationSupport()
            let diagnostics = AppDiagnostics(root: root)
            let store = MemoryStore(modelContainer: container)
            let deletionStore = DeletionStore(modelContainer: container)
            let inbox = PhoneInboxService(
                store: store,
                applicationSupport: root,
                deletionStore: deletionStore,
                diagnostics: diagnostics
            )
            let batteryCoordinator = BatteryAlertCoordinator(
                notifier: BatteryNotificationService(),
                activity: BatteryLiveActivityController()
            )
            let locationTrackStore = LocationTrackStore(
                modelContainer: container
            )
            let trackImporter = TrackImporter(
                store: locationTrackStore,
                applicationSupport: root,
                deletionStore: deletionStore,
                diagnostics: diagnostics
            )
            let service = PhoneConnectivityService(
                inbox: inbox,
                applicationSupport: root,
                deletionStore: deletionStore,
                trackImporter: trackImporter,
                batteryEventHandler: { event in
                    Task { @MainActor in
                        await batteryCoordinator.handle(event)
                    }
                }
            )
            let transcriptStore = TranscriptStore(modelContainer: container)
            let searchIndex = try? SQLiteSearchIndex(
                databaseURL: root.appending(path: "index/search.sqlite")
            )
            let indexer = searchIndex.map {
                TranscriptIndexer(index: $0, diagnostics: diagnostics)
            }
            let transcriptionService = TranscriptionService(
                store: transcriptStore,
                provider: AppleSpeechTranscriptionProvider(),
                applicationSupport: root,
                indexer: indexer,
                diagnostics: diagnostics
            )
            let deletionService = DeletionService(
                store: deletionStore,
                applicationSupport: root,
                index: searchIndex,
                sender: service,
                diagnostics: diagnostics
            )
            self.container = container
            self.transcription = TranscriptionCoordinator(
                service: transcriptionService
            )
            self.search = SearchCoordinator(
                index: searchIndex,
                indexer: indexer,
                store: transcriptStore
            )
            self.deletion = DeletionCoordinator(service: deletionService)
            self.diagnostics = diagnostics
            self.battery = batteryCoordinator
            self.connectivity = service
            #if DEBUG
                self.store = store
                self.inbox = inbox
            #endif
            service.activate()
            #if DEBUG
                if SimulatorFixtureSeeder.isRequested {
                    Task {
                        _ = await SimulatorFixtureSeeder(inbox: inbox, store: store)
                            .seedIfNeeded()
                        await SimulatorTranscriptSeeder(
                            container: container,
                            indexer: indexer
                        ).seedIfNeeded()
                    }
                }
            #endif
        } catch {
            self.container = nil
            self.transcription = nil
            self.search = nil
            self.deletion = nil
            self.diagnostics = nil
            self.battery = nil
            self.connectivity = nil
            #if DEBUG
                self.store = nil
                self.inbox = nil
            #endif
            self.setupFailed = true
        }
    }
}
