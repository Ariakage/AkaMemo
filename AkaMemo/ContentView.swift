import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var model = PhoneAppModel()

    var body: some View {
        NavigationStack {
            Group {
                if let container = model.container {
                    SessionListView()
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
    }
}

#Preview {
    ContentView()
}
