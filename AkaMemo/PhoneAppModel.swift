import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PhoneAppModel {
    let container: ModelContainer?
    private let connectivity: PhoneConnectivityService?
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
            service.activate()
        } catch {
            self.container = nil
            self.connectivity = nil
            self.setupFailed = true
        }
    }
}
