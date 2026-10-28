import Combine
import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var model = PhoneAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if let container = model.container {
                    SessionListView(
                        transcription: model.transcription,
                        search: model.search,
                        deletion: model.deletion,
                        diagnostics: model.diagnostics,
                        battery: model.battery
                    )
                    .modelContainer(container)
                } else {
                    ContentUnavailableView(
                        "inbox.error.title",
                        systemImage: "exclamationmark.triangle",
                        description: Text("inbox.error.storage")
                    )
                }
            }
            .navigationTitle("app.name")
        }
        .task {
            await model.battery?.setForeground(true)
            await model.battery?.requestAuthorizationIfNeeded()
            await model.search?.prepare()
            await model.transcription?.start()
        }
        .onChange(of: scenePhase) { _, phase in
            let active = phase == .active
            Task {
                await model.battery?.setForeground(active)
                if active {
                    await model.transcription?.start()
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
