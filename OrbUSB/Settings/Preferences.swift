import Foundation
import Observation

@MainActor @Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults
    var refreshInterval: Int { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    var showForwarded: Bool { didSet { defaults.set(showForwarded, forKey: "showForwarded") } }
    var showDeviceIDs: Bool { didSet { defaults.set(showDeviceIDs, forKey: "showDeviceIDs") } }
    var showSerialNumbers: Bool { didSet { defaults.set(showSerialNumbers, forKey: "showSerialNumbers") } }
    var enableUSBMonitoring: Bool { didSet { defaults.set(enableUSBMonitoring, forKey: "enableUSBMonitoring") } }
    private(set) var favorites: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["refreshInterval": 2, "showForwarded": true,
                                    "showDeviceIDs": true, "showSerialNumbers": false,
                                    "enableUSBMonitoring": true])
        let interval = defaults.integer(forKey: "refreshInterval")
        refreshInterval = [1, 2, 5, 10].contains(interval) ? interval : 2
        showForwarded = defaults.bool(forKey: "showForwarded")
        showDeviceIDs = defaults.bool(forKey: "showDeviceIDs")
        showSerialNumbers = defaults.bool(forKey: "showSerialNumbers")
        enableUSBMonitoring = defaults.bool(forKey: "enableUSBMonitoring")
        favorites = Set(defaults.stringArray(forKey: "favorites") ?? [])
    }

    func isFavorite(_ device: USBDevice) -> Bool { favorites.contains(device.preferenceKey) }

    func toggleFavorite(_ device: USBDevice) {
        if !favorites.insert(device.preferenceKey).inserted { favorites.remove(device.preferenceKey) }
        defaults.set(favorites.sorted(), forKey: "favorites")
    }
}
