import SwiftUI

struct RecordingStatusBannerView: View {
    @Bindable var coordinator: RecordingWatchdog

    var body: some View {
        if let banner = coordinator.banner {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                Text(LocalizedStringKey(banner.messageKey))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12))
            .accessibilityElement(children: .combine)
        }
    }

    private var tint: Color {
        switch coordinator.banner?.kind {
        case .storage:
            .red
        case .paused:
            .blue
        case .interrupted, .stale, .none:
            .orange
        }
    }

    private var iconName: String {
        switch coordinator.banner?.kind {
        case .storage:
            "internaldrive"
        case .paused:
            "pause.circle"
        case .interrupted, .stale, .none:
            "exclamationmark.triangle"
        }
    }
}
