import SwiftUI

struct ContentView: View {
    @State private var model = RecordingViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                header
                timer
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                if model.batteryMonitoringUnavailable {
                    Text("battery.unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let warning = model.batteryWarning {
                    Text(LocalizedStringKey(warning))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if let warning = model.storageWarning {
                    Text(LocalizedStringKey(warning))
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 4) {
                    Image(systemName: "location")
                    Text(LocalizedStringKey(locationStatusKey(model.locationStatus)))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Toggle(
                    "location.enabled",
                    isOn: Binding(
                        get: { model.locationEnabled },
                        set: { model.setLocationEnabled($0) }
                    )
                )
                .font(.caption2)
                controls
                if model.snapshot.state == .idle {
                    Text("recording.hint.foreground")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .task {
            await model.recoverPendingChunks()
            await model.observe()
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("app.name")
                .font(.headline)
            HStack(spacing: 4) {
                if model.snapshot.state == .recording {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                }
                Text(LocalizedStringKey(model.stateKey))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func locationStatusKey(
        _ status: LocationRecorder.Status
    ) -> String {
        switch status {
        case .idle: "location.status.idle"
        case .requesting: "location.status.requesting"
        case .recording: "location.status.recording"
        case .paused: "location.status.paused"
        case .unavailable: "location.status.unavailable"
        case .disabled: "location.status.disabled"
        case .completed: "location.status.completed"
        case .failed: "location.status.failed"
        }
    }

    private var timer: some View {
        VStack(spacing: 4) {
            Text(model.elapsedText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel(Text("recording.elapsed"))
                .accessibilityValue(Text(model.elapsedText))

            HStack(spacing: 8) {
                if let battery = model.batteryText {
                    Label(battery, systemImage: "battery.75")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Label(
                    "\(model.snapshot.sealedChunkCount)",
                    systemImage: "square.stack.3d.up"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("recording.chunks"))
                .accessibilityValue(Text("\(model.snapshot.sealedChunkCount)"))
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.snapshot.state {
        case .idle, .failed:
            Button {
                Task { await model.start() }
            } label: {
                Label("recording.start", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

        case .preparing:
            ProgressView()
                .accessibilityLabel(Text("recording.state.preparing"))

        case .recording:
            HStack(spacing: 8) {
                Button {
                    Task { await model.pause() }
                } label: {
                    Label("recording.pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("recording.stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }

        case .paused:
            HStack(spacing: 8) {
                Button {
                    Task { await model.resume() }
                } label: {
                    Label("recording.resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("recording.stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }

        case .recovering:
            VStack(spacing: 6) {
                ProgressView()
                    .accessibilityLabel(Text("recording.state.recovering"))

                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("recording.stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }

        case .interrupted:
            HStack(spacing: 8) {
                Button {
                    Task { await model.resume() }
                } label: {
                    Label("recording.continue", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("recording.stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }

        case .finalizing:
            ProgressView()
                .accessibilityLabel(Text("recording.state.finalizing"))
        }
    }
}

#Preview {
    ContentView()
}
