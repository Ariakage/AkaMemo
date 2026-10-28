import AkaMemoCore
import SwiftUI

/// FR-001 first-run consent and permission education for the iPhone app.
struct OnboardingView: View {
    let battery: BatteryAlertCoordinator?
    let onComplete: () -> Void

    @State private var step: Int
    @State private var notificationsDenied = false

    init(
        battery: BatteryAlertCoordinator?,
        onComplete: @escaping () -> Void
    ) {
        self.battery = battery
        self.onComplete = onComplete
        let preview = OnboardingPreview.step ?? 1
        _step = State(initialValue: min(max(preview, 1), 3))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("app.name")
                        .font(.largeTitle.bold())
                    switch step {
                    case 1:
                        welcome
                    case 2:
                        permissions
                    default:
                        privacy
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 12) {
                if step < 3 {
                    Button("onboarding.next") {
                        step += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                } else {
                    Button("onboarding.agree") {
                        complete()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    Text("onboarding.consent.note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var welcome: some View {
        Text("onboarding.page1.title")
            .font(.title2.bold())
        Text("onboarding.page1.body")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var permissions: some View {
        Text("onboarding.page2.title")
            .font(.title2.bold())
        Text("onboarding.page2.body")
            .foregroundStyle(.secondary)

        if battery != nil {
            Button("onboarding.notifications.allow") {
                Task {
                    await battery?.requestAuthorizationIfNeeded()
                    notificationsDenied =
                        battery?.notificationsDenied ?? false
                }
            }
            .buttonStyle(.bordered)
            if notificationsDenied {
                Text("onboarding.notifications.denied")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var privacy: some View {
        Text("onboarding.page3.title")
            .font(.title2.bold())
        Text("onboarding.page3.body")
            .foregroundStyle(.secondary)
    }

    private func complete() {
        ConsentState.markCompleted()
        onComplete()
    }
}
