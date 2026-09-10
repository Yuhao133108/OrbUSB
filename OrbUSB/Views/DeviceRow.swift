import AppKit
import SwiftUI

struct DeviceRow: View {
    let device: USBDevice
    @Bindable var state: AppState
    @State private var expanded = false
    @State private var hovering = false
    @State private var machine = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: device.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(device.state == .attached ? Color.accentColor : .secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                if state.preferences.isFavorite(device) {
                                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            }
                            if state.preferences.showDeviceIDs || device.state == .forwarded {
                                HStack(spacing: 5) {
                                    if state.preferences.showDeviceIDs { Text(device.vidPID).monospacedDigit() }
                                    if device.state == .forwarded { Text("Shared with macOS") }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            if state.preferences.showSerialNumbers, let serial = device.serialNumber {
                                Text(serial).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let operation = state.operation(for: device) {
                                Text(operation.phase.rawValue + "…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(device.name)
                .accessibilityLabel("\(device.name), \(device.state.title), show details")
                if let operation = state.operation(for: device) {
                    ProgressView().controlSize(.small).frame(width: 54)
                        .accessibilityLabel(operation.phase.rawValue)
                } else if device.state == .available || device.state == .attached {
                    Button(device.state == .attached ? "Detach" : "Attach") { state.toggle(device, machine: machine) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state.error != nil)
                        .accessibilityLabel("\(device.state == .attached ? "Detach" : "Attach") \(device.name)")
                } else {
                    Image(systemName: device.state == .forwarded ? "link" : "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help(device.state == .forwarded ? "Shared with macOS" : "Refresh to check device state")
                }
            }
            .frame(minHeight: 52)
            if let error = state.rowErrors[device.connectionKey] ?? device.detailError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 32).padding(.bottom, 6)
            }
            if expanded {
                DeviceDetailsView(device: device, showSerial: state.preferences.showSerialNumbers)
                if device.state == .available, device.type?.localizedCaseInsensitiveContains("network") == true {
                    TextField("Machine (optional)", text: $machine)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .padding(.leading, 32)
                        .padding(.bottom, 8)
                        .help("Leave empty for OrbStack's default machine")
                }
                Button(state.preferences.isFavorite(device) ? "Remove from Favorites" : "Add to Favorites") {
                    state.preferences.toggleFavorite(device)
                }
                .font(.caption).padding(.leading, 32).padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(state.preferences.isFavorite(device) ? "Remove from Favorites" : "Add to Favorites") {
                state.preferences.toggleFavorite(device)
            }
            Divider()
            Button("Copy Device ID") { copy(device.id) }
            Button("Copy VID:PID") { copy(device.vidPID) }
            Button(expanded ? "Hide Details" : "Show Details") { expanded.toggle() }
            if device.state == .available || device.state == .attached {
                Divider()
                Button(device.state == .attached ? "Detach" : "Attach") { state.toggle(device, machine: machine) }
                    .disabled(state.operation(for: device) != nil || state.error != nil)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
