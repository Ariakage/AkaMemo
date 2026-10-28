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
            let root = try Self.applicationSupportDirectory()
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

    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appending(path: "AkaMemo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
