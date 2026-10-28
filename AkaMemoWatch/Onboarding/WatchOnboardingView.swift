import AVFoundation
import AkaMemoCore
import SwiftUI

/// FR-001 first-run consent and permission education for the Watch app.
struct WatchOnboardingView: View {
    let model: RecordingViewModel
    let onComplete: () -> Void

    @State private var step: Int
    @State private var micGranted: Bool
    @State private var micDenied: Bool
    @State private var locationAuthorization: String

    init(model: RecordingViewModel, onComplete: @escaping () -> Void) {
        self.model = model
        self.onComplete = onComplete
        let permission = AVAudioApplication.shared.recordPermission
        _micGranted = State(initialValue: permission == .granted)
        _micDenied = State(initialValue: permission == .denied)
        _locationAuthorization = State(
            initialValue: model.locationAuthorization
        )
        let preview = OnboardingPreview.step ?? 1
        _step = State(initialValue: min(max(preview, 1), 4))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("app.name")
                    .font(.headline)
                switch step {
                case 1:
                    welcome
                case 2:
                    microphone
                case 3:
                    location
                default:
                    privacy
                }
            }
            .padding(.horizontal, 4)
        }
        .task(id: step) {
            guard step == 3 else {
                return
            }
            while !Task.isCancelled {
                locationAuthorization = model.locationAuthorization
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var welcome: some View {
        Text("watch.onboarding.intro")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Button("watch.onboarding.continue") {
            step = 2
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var microphone: some View {
        Text("watch.onboarding.mic.title")
            .font(.caption)
        Text("watch.onboarding.mic.body")
            .font(.caption2)
            .foregroundStyle(.secondary)
        if micGranted {
            Text("watch.onboarding.mic.granted")
                .font(.caption2)
                .foregroundStyle(.green)
        } else if micDenied {
            Text("watch.onboarding.mic.denied")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Button("watch.onboarding.mic.allow") {
                Task {
                    let granted = await model.requestMicrophonePermission()
                    micGranted = granted
                    micDenied =
                        !granted
                        && AVAudioApplication.shared.recordPermission
                            == .denied
                }
            }
            .buttonStyle(.bordered)
        }
        Button("watch.onboarding.continue") {
            step = 3
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var location: some View {
        Text("watch.onboarding.location.title")
            .font(.caption)
        Text("watch.onboarding.location.body")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Text(locationStatusKey)
            .font(.caption2)
            .foregroundStyle(.secondary)
        if locationAuthorization == "notDetermined" {
            Button("watch.onboarding.location.allow") {
                model.requestLocationAuthorization()
                locationAuthorization = model.locationAuthorization
            }
            .buttonStyle(.bordered)
        }
        Button("watch.onboarding.continue") {
            step = 4
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var privacy: some View {
        Text("watch.onboarding.privacy")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Button("watch.onboarding.agree") {
            ConsentState.markCompleted()
            onComplete()
        }
        .buttonStyle(.borderedProminent)
    }

    private var locationStatusKey: LocalizedStringKey {
        switch locationAuthorization {
        case "authorized":
            return "watch.onboarding.location.granted"
        case "denied", "restricted":
            return "watch.onboarding.location.denied"
        default:
            return "watch.onboarding.location.notRequested"
        }
    }
}
