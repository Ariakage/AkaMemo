import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)

            Text("AkaMemo")
                .font(.headline)

            Text("录音入口")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
