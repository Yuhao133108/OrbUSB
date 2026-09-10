import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var updatingLogin = false
    @State private var loginMessage: String?

    var body: some View {
        @Bindable var preferences = state.preferences
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(get: { loginEnabled }, set: updateLogin))
                    .disabled(updatingLogin)
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.secondary)
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section("Devices") {
                Picker("Refresh while menu is open", selection: $preferences.refreshInterval) {
                    ForEach([1, 2, 5, 10], id: \.self) { interval in
                        Text("\(interval) sec").tag(interval)
                    }
                }
                Toggle("Show forwarded devices", isOn: $preferences.showForwarded)
                Toggle("Show device IDs", isOn: $preferences.showDeviceIDs)
                Toggle("Show serial numbers", isOn: $preferences.showSerialNumbers)
                Toggle("Enable USB hotplug monitoring", isOn: $preferences.enableUSBMonitoring)
                if !state.monitoringAvailable {
                    Text("USB notifications are unavailable. Automatic refresh still works while the menu is open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("USB access is managed by OrbStack. OrbUSB only runs its command line tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: preferences.enableUSBMonitoring) { state.configureUSBMonitor() }
        .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
    }

    private func updateLogin(_ enabled: Bool) {
        updatingLogin = true
        loginMessage = nil
        Task { @MainActor in
            defer {
                updatingLogin = false
                loginEnabled = SMAppService.mainApp.status == .enabled
            }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                if SMAppService.mainApp.status == .requiresApproval {
                    loginMessage = "Allow OrbUSB in System Settings → General → Login Items."
                }
            } catch {
                loginMessage = "Unable to change login settings. Keep OrbUSB in Applications and try again."
            }
        }
    }
}
