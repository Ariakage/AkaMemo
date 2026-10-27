import AkaMemoCore
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("AkaMemo")
                    .font(.largeTitle.bold())

                Text("录音、转写与检索的工程骨架已建立。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Core \(AkaMemoCore.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .navigationTitle("AkaMemo")
        }
    }
}

#Preview {
    ContentView()
}
