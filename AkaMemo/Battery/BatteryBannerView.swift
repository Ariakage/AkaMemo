import SwiftUI

struct BatteryBannerView: View {
    @Bindable var coordinator: BatteryAlertCoordinator

    var body: some View {
        if let banner = coordinator.banner {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(
                        systemName: banner.kind == .stopped
                            ? "battery.0"
                            : "battery.25"
                    )
                    Text(LocalizedStringKey(banner.messageKey))
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(
                    banner.kind == .stopped ? Color.red : Color.orange
                )

                if coordinator.notificationsDenied {
                    Text("battery.banner.notificationsOff")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (banner.kind == .stopped ? Color.red : Color.orange)
                    .opacity(0.12)
            )
        }
    }
}
