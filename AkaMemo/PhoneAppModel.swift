import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PhoneAppModel {
    let container: ModelContainer?
    private let connectivity: PhoneConnectivityService?
    #if DEBUG
        private let store: MemoryStore?
        private let inbox: PhoneInboxService?
    #endif
    private(set) var setupFailed = false

    init() {
        do {
            let container = try ModelContainer(for: ReceivedChunkRecord.self)
            let root = try PhonePaths.applicationSupport()
            let store = MemoryStore(modelContainer: container)
            let inbox = PhoneInboxService(store: store, applicationSupport: root)
            let service = PhoneConnectivityService(
                inbox: inbox,
                applicationSupport: root
            )
            self.container = container
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
                    }
                }
            #endif
        } catch {
            self.container = nil
            self.connectivity = nil
            #if DEBUG
                self.store = nil
                self.inbox = nil
            #endif
            self.setupFailed = true
        }
    }
}
