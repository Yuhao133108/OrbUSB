import SwiftUI

struct EmptyStateView: View {
    let hasLoaded: Bool
    let failed: Bool

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "cable.connector").font(.system(size: 25)).foregroundStyle(.secondary)
            Text(failed ? "USB devices unavailable" : hasLoaded ? "No USB devices" : "Reading USB devices…")
                .font(.callout.weight(.medium))
            Text(failed ? "Open OrbStack or try refreshing." : hasLoaded ? "Connect a USB device to your Mac." : "Connecting to OrbStack")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }
}
