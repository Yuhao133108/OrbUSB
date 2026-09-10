import SwiftUI

@main
struct OrbUSBApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra("OrbUSB", systemImage: "cable.connector") {
            MenuBarView(state: state)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(state: state)
        }
    }
}
