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
    var recoveryNotice: String?

    let preferences: Preferences
    var monitoringAvailable = true
    @ObservationIgnored private let monitor = USBMonitor()
    @ObservationIgnored private var hotplugTask: Task<Void, Never>?
    @ObservationIgnored let service: OrbStackUSBService
    @ObservationIgnored private var operationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var mutationRevision: UInt64 = 0
    @ObservationIgnored private var hostReturnTask: Task<Void, Never>?

    init(service: OrbStackUSBService = OrbStackUSBService(), preferences: Preferences = Preferences(), startMonitoring: Bool = true) {
        self.service = service
        self.preferences = preferences
        if startMonitoring { configureUSBMonitor() }
    }

    func configureUSBMonitor() {
        monitor.stop()
        hotplugTask?.cancel()
        hostReturnTask?.cancel()
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
        hostReturnTask?.cancel()
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
        guard operations.isEmpty else { refreshAgain = true; return }
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
                let revision = self.mutationRevision
                do {
                    let list = await self.service.hostStatus(for: try await self.service.refresh())
                    guard revision == self.mutationRevision, self.operations.isEmpty else {
                        self.refreshAgain = true
                        break
                    }
                    self.devices = list
                    self.scheduleHostReturnCheck(list)
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
                    guard revision == self.mutationRevision, self.operations.isEmpty else { break }
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
        guard error == nil, operations.isEmpty,
              displayed.state == .available || displayed.state == .attached else { return }
        mutationRevision &+= 1
        let attaching = displayed.state == .available
        let key = displayed.connectionKey
        operations[key] = USBDeviceOperation(device: displayed,
            phase: attaching ? (displayed.isStorage ? .resolvingDisk : .attaching) : .detaching)
        rowErrors[key] = nil
        operationTasks[key] = Task {
            defer {
                operations[key] = nil; operationTasks[key] = nil
                mutationRevision &+= 1
                requestRefresh(force: true)
            }
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
            await refreshAfterMutation()
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

    func recover(_ displayed: USBDevice) {
        guard error == nil, operations.isEmpty, displayed.hostBindingState == .driverUnavailable,
              displayed.recoveryEligibility == .eligible else { return }
        let key = displayed.connectionKey
        recoveryNotice = nil
        mutationRevision &+= 1
        operations[key] = USBDeviceOperation(device: displayed, phase: .recovering)
        rowErrors[key] = nil
        operationTasks[key] = Task {
            defer {
                operations[key] = nil; operationTasks[key] = nil
                mutationRevision &+= 1
                requestRefresh(force: true)
            }
            var failure: String?
            do {
                let result = try await service.recoverDevice(displayed)
                if let index = devices.firstIndex(where: { $0.hostIdentity == displayed.hostIdentity }) {
                    devices[index].hostIdentity = result.after.identity
                    devices[index].hostBindingState = .available
                    devices[index].recoveryEligibility = .alreadyRecovered
                }
            } catch {
                failure = error.localizedDescription
                rowErrors[key] = "Recovery failed\n\(error.localizedDescription)"
                if let index = devices.firstIndex(where: { $0.hostIdentity == displayed.hostIdentity }) {
                    devices[index].hostBindingState = .failed
                    devices[index].recoveryError = error.localizedDescription
                }
            }
            await refreshAfterMutation()
            if let failure {
                let current = devices.first {
                    guard let original = displayed.hostIdentity, let identity = $0.hostIdentity else { return false }
                    return $0.hostBindingState == .failed && $0.recoveryError == failure
                        && original.sameConnection(as: identity, requireGeneration: false)
                }
                if let current {
                    rowErrors[key] = nil
                    rowErrors[current.connectionKey] = "Recovery failed\n\(failure)"
                } else {
                    // Unplug/replacement can remove the row entirely. Preserve the outcome visibly.
                    recoveryNotice = "\(displayed.name): Recovery failed\n\(failure)"
                }
            }
        }
    }

    private func refreshAfterMutation() async {
        // Keep actions locked until a fresh post-command snapshot has been published.
        // A refresh that began before the mutation is drained and discarded by its revision check.
        await refreshTask?.value
        do {
            let list = await service.hostStatus(for: try await service.listDevices())
            devices = list
            error = nil
            hasLoaded = true
            lastRefreshDate = Date()
            refreshAgain = false
            scheduleHostReturnCheck(list)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func scheduleHostReturnCheck(_ list: [USBDevice]) {
        hostReturnTask?.cancel()
        guard list.contains(where: { $0.hostBindingState == .returning }) else { return }
        hostReturnTask = Task { [weak self] in
            // A bounded observation deadline, never a reset trigger or a readiness assertion.
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.requestRefresh(force: true)
        }
    }

    func openOrbStack() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.kdrag0n.MacVirt")
            ?? URL(fileURLWithPath: "/Applications/OrbStack.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
