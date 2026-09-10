// swift-tools-version: 6.2
import PackageDescription

// Standalone core tests: the application itself is built only through Xcode MCP.
let package = Package(
    name: "OrbUSBCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "OrbUSBCore", targets: ["OrbUSBCore"])],
    targets: [
        .target(name: "OrbUSBCore", path: "OrbUSB",
                exclude: ["App", "Views", "Settings/SettingsView.swift"],
                sources: ["Models", "Services", "Utilities", "Settings/Preferences.swift"]),
        .testTarget(name: "OrbUSBTests", dependencies: ["OrbUSBCore"],
                    path: "OrbUSBTests", resources: [.copy("Fixtures")])
    ]
)
