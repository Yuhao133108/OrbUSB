import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var state: AppState
    var observesMenu = true
    @State private var listHeight: CGFloat = 80
    @Environment(\.openSettings) private var openSettings

    private var visibleDevices: [USBDevice] {
        state.devices.filter { state.preferences.showForwarded || $0.state != .forwarded }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OrbUSB").font(.headline)
                Spacer()
                if state.isRefreshing { ProgressView().controlSize(.mini) }
                Button { state.requestRefresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh USB devices")
                    .accessibilityLabel("Refresh USB devices")
                    .disabled(state.isRefreshing)
            }
            .padding(.horizontal, 6)
            if let error = state.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                    Spacer(minLength: 4)
                    Button("Retry") { state.requestRefresh() }.controlSize(.small)
                }
                .help(state.diagnostic)
                .padding(8)
            }
            Divider()
            if visibleDevices.isEmpty {
                if !state.devices.isEmpty {
                    Text("Forwarded devices are hidden in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 80)
                } else {
                    EmptyStateView(hasLoaded: state.hasLoaded, failed: state.error != nil)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        deviceGroup("Favorites", devices: visibleDevices.filter(state.preferences.isFavorite))
                        ForEach([USBDeviceState.attached, .available, .forwarded, .unknown], id: \.self) { group in
                            deviceGroup(group.title, devices: visibleDevices.filter {
                                $0.state == group && !state.preferences.isFavorite($0)
                            })
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, 390))
                .scrollBounceBehavior(.basedOnSize)
            }
            if state.debugVisible {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.version)
                    Text(state.executablePath)
                    if let duration = state.lastRefreshDuration {
                        Text("Last refresh: \(duration, format: .number.precision(.fractionLength(3))) s")
                    }
                    Text(!state.preferences.enableUSBMonitoring ? "USB notifications disabled" : state.monitoringAvailable ? "USB notifications enabled" : "USB notifications unavailable")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Divider()
            footerButton("Open OrbStack…") { state.openOrbStack() }
            footerButton("Settings…") {
                state.closeMenu()
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }
            footerButton("Quit OrbUSB") {
                state.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 350)
        .background(.regularMaterial)
        .background {
            if observesMenu { MenuWindowObserver(state: state).frame(width: 0, height: 0) }
        }
        .onAppear { if observesMenu { state.openMenu() } }
        .onDisappear { if observesMenu { state.closeMenu() } }
    }

    @ViewBuilder
    private func deviceGroup(_ title: String, devices: [USBDevice]) -> some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                ForEach(devices) { device in
                    DeviceRow(device: device, state: state).id(device.connectionKey)
                }
            }
        }
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

#Preview("Live USB devices") {
    MenuBarView(state: AppState(startMonitoring: false))
}

#Preview("Captured device layout") {
    let state = AppState(startMonitoring: false)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appendingPathComponent("OrbUSBTests/Fixtures/list-captured-redacted.json")
    if let text = try? String(contentsOf: fixture, encoding: .utf8), let devices = try? USBParser.listJSON(text) {
        state.devices = devices.map { device in
            var value = device
            value.state = .available
            return value
        }
        state.hasLoaded = true
    }
    return MenuBarView(state: state, observesMenu: false)
}
