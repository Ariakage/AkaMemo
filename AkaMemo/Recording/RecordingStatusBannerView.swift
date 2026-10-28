import SwiftUI

struct RecordingStatusBannerView: View {
    @Bindable var coordinator: RecordingWatchdog

    var body: some View {
        if let banner = coordinator.banner {
            HStack(spacing: 8) {
                Image(
                    systemName: banner.kind == .storage
                        ? "internaldrive" : "exclamationmark.triangle"
                )
                Text(LocalizedStringKey(banner.messageKey))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(
                banner.kind == .storage ? Color.red : Color.orange
            )
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (banner.kind == .storage ? Color.red : Color.orange)
                    .opacity(0.12)
            )
            .accessibilityElement(children: .combine)
        }
    }
}
