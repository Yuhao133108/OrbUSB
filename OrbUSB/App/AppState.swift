import AppKit
import Foundation
import Observation
import OSLog

@MainActor @Observable
final class AppState {
    var devices: [USBDevice] = []
    var isRefreshing = false
    var error: String?
    var diagnostic = ""
    var hasLoaded = false
    var lastRefreshDuration: TimeInterval?
    var lastRefreshDate: Date?
    var executablePath = "Not found"
    var version = "Unknown"
    var menuOpen = false
    var debugVisible = false
    var operations: [String: USBDeviceOperation] = [:]
    var rowErrors: [String: String] = [:]

    let preferences: Preferences
    var monitoringAvailable = true
    @ObservationIgnored private let monitor = USBMonitor()
    @ObservationIgnored private var hotplugTask: Task<Void, Never>?
    @ObservationIgnored let service: OrbStackUSBService
    @ObservationIgnored private var operationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false

    init(service: OrbStackUSBService = OrbStackUSBService(), preferences: Preferences = Preferences(), startMonitoring: Bool = true) {
        self.service = service
        self.preferences = preferences
        if startMonitoring { configureUSBMonitor() }
    }

    func configureUSBMonitor() {
        monitor.stop()
        hotplugTask?.cancel()
        monitoringAvailable = true
        guard preferences.enableUSBMonitoring else { return }
        monitoringAvailable = monitor.start { [weak self] in
            guard let self else { return }
            self.requestRefresh(force: true)
            // OrbStack may see the event slightly after IOKit.
            self.hotplugTask?.cancel()
            self.hotplugTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                self?.requestRefresh(force: true)
            }
        }
    }

    func shutdown() {
        closeMenu()
        operationTasks.values.forEach { $0.cancel() }
        monitor.stop()
        hotplugTask?.cancel()
    }

    func openMenu() {
        guard !menuOpen else { return }
        menuOpen = true
        debugVisible = NSEvent.modifierFlags.contains(.option)
        Log.ui.debug("Menu opened")
        requestRefresh()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.preferences.refreshInterval ?? 2
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, self.menuOpen else { return }
                self.requestRefresh()
            }
        }
    }

    func closeMenu() {
        menuOpen = false
        polling?.cancel()
        polling = nil
        Log.ui.debug("Menu closed")
    }

    func requestRefresh(force: Bool = false) {
        if isRefreshing {
            if force { refreshAgain = true }
            return
        }
        isRefreshing = true
        refreshAgain = false
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while true {
                let start = Date()
                do {
                    let list = try await self.service.refresh()
                    self.devices = list
                    let currentKeys = Set(list.map(\.connectionKey))
                    self.rowErrors = self.rowErrors.filter { currentKeys.contains($0.key) }
                    self.error = nil
                    self.diagnostic = ""
                    self.hasLoaded = true
                    self.lastRefreshDate = Date()
                    self.executablePath = await self.service.executable?.path ?? "Not found"
                    if self.version == "Unknown" {
                        await self.service.loadVersion()
                        self.version = await self.service.version
                    }
                    Log.usb.debug("Refreshed \(list.count) USB devices")
                } catch {
                    self.error = error.localizedDescription
                    self.diagnostic = (error as? OrbStackError)?.diagnostic ?? error.localizedDescription
                    // Preserve the last snapshot for context; actions are disabled while stale.
                    Log.usb.error("USB refresh failed")
                }
                self.lastRefreshDuration = Date().timeIntervalSince(start)
                guard self.refreshAgain else { break }
                self.refreshAgain = false
            }
            self.isRefreshing = false
            self.refreshTask = nil
        }
    }

    func toggle(_ displayed: USBDevice, machine: String? = nil) {
        guard error == nil, operation(for: displayed) == nil,
              displayed.state == .available || displayed.state == .attached else { return }
        let attaching = displayed.state == .available
        let key = displayed.connectionKey
        operations[key] = USBDeviceOperation(device: displayed,
            phase: attaching ? (displayed.isStorage ? .resolvingDisk : .attaching) : .detaching)
        rowErrors[key] = nil
        operationTasks[key] = Task {
            defer { operations[key] = nil; operationTasks[key] = nil }
            var failure: String?
            do {
                if attaching {
                    // Mark pending in the service immediately; CLI refresh before
                    // this point would leave automount unprotected for its duration.
                    var current = displayed
                    if !displayed.isStorage {
                        let list = try await service.refresh()
                        guard let fresh = list.first(where: { $0.connectionKey == displayed.connectionKey }),
                              fresh.state == .available else { throw USBStorageError.stateChanged }
                        current = fresh
                    }
                    try await service.attachDevice(current, machine: machine) { phase in
                        self.operations[key]?.phase = phase
                    }
                } else {
                    await refreshTask?.value
                    let currentList = try await service.refresh()
                    devices = currentList
                    guard let current = currentList.first(where: { $0.connectionKey == displayed.connectionKey }),
                          current.state == .attached else { throw USBStorageError.stateChanged }
                    try Task.checkCancellation()
                    try await service.detachDevice(id: current.id)
                }
            } catch {
                failure = "\(attaching ? "Attach" : "Detach") failed\n\(error.localizedDescription)"
            }
            // Even failed commands may have changed host state. Never infer success locally.
            requestRefresh(force: true)
            await refreshTask?.value
            if let failure {
                // Keep errors on the current row if unmount changed its OrbStack ID.
                let matches = devices.filter { $0.connectionKey == key || displayed.hasSameSerialIdentity(as: $0) }
                rowErrors[matches.count == 1 ? matches[0].connectionKey : key] = failure
            }
        }
    }

    func operation(for device: USBDevice) -> USBDeviceOperation? {
        operations.values.first { $0.matches(device) }
    }

    func openOrbStack() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.kdrag0n.MacVirt")
            ?? URL(fileURLWithPath: "/Applications/OrbStack.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
