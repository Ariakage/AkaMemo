import Combine
import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var model = PhoneAppModel()
    @State private var path: [UUID] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let container = model.container {
                NavigationStack(path: $path) {
                    SessionListView(
                        transcription: model.transcription,
                        search: model.search,
                        deletion: model.deletion,
                        diagnostics: model.diagnostics,
                        battery: model.battery,
                        recordingWatchdog: model.recordingWatchdog,
                        settings: model.settings
                    )
                    .navigationTitle("app.name")
                }
                // Applied above the stack so navigation destinations (session
                // detail, search) inherit the model context.
                .modelContainer(container)
            } else {
                NavigationStack {
                    ContentUnavailableView(
                        "inbox.error.title",
                        systemImage: "exclamationmark.triangle",
                        description: Text("inbox.error.storage")
                    )
                    .navigationTitle("app.name")
                }
            }
        }
        .task {
            await model.battery?.setForeground(true)
            await model.battery?.requestAuthorizationIfNeeded()
            await model.search?.prepare()
            await model.transcription?.start()
            model.settings?.publishLocationSetting()
            #if DEBUG
                if SimulatorFixtureSeeder.openDemoSessionRequested,
                    path.isEmpty,
                    let raw = SimulatorFixtureSeeder.demoSessionIDs.first,
                    let sessionID = UUID(uuidString: raw)
                {
                    path.append(sessionID)
                }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            let active = phase == .active
            Task {
                await model.battery?.setForeground(active)
                if active {
                    await model.transcription?.start()
                    model.settings?.publishLocationSetting()
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .akamemoInboxAcceptedChunk
            )
        ) { _ in
            Task {
                await model.transcription?.start()
            }
        }
    }
}

#Preview {
    ContentView()
}
