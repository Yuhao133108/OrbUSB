import Foundation
import OSLog

actor OrbStackUSBService {
    private let cli = OrbCLI()
    private let executableOverride: URL?
    private let storage: any USBStoragePreparing
    let hostRecovery: USBHostRecoveryService
    private var recoveryInProgress = false

    init(executable: URL? = nil, storage: any USBStoragePreparing = USBStorageService(),
         hostRecovery: USBHostRecoveryService = USBHostRecoveryService()) {
        executableOverride = executable
        self.storage = storage
        self.hostRecovery = hostRecovery
    }
    private(set) var executable: URL?
    private(set) var version = "Unknown"
    // Actor reentrancy does not serialize operations across awaits. Keep this
    // lock until preparation, CLI execution and cleanup have all finished.
    private var transactions: [String: USBDevice] = [:]
    private(set) var transferStates: [String: USBTransferState] = [:]

    private func transition(_ device: USBDevice, to state: USBTransferState) {
        transferStates[device.id] = state
        Log.usb.info("[USBTransfer] id=\(device.id, privacy: .public) state=\(state.rawValue, privacy: .public)")
    }

    private func acquire(_ device: USBDevice) throws {
        guard !recoveryInProgress else { throw USBHostRecoveryError.operationInProgress }
        guard !transactions.values.contains(where: { $0.mutationKey == device.mutationKey || $0.hasSameSerialIdentity(as: device) }) else {
            throw USBStorageError.operationInProgress
        }
        transactions[device.id] = device
    }

    private var refreshTask: Task<[USBDevice], any Error>?

    func hostStatus(for devices: [USBDevice]) async -> [USBDevice] {
        await hostRecovery.decorate(devices)
    }

    func recoverDevice(_ device: USBDevice) async throws -> RecoveryResult {
        // Recovery excludes ALL mutations, not just a possibly obsolete OrbStack bus ID.
        guard transactions.isEmpty, !recoveryInProgress else { throw USBHostRecoveryError.operationInProgress }
        guard device.hostIdentity != nil else { throw USBHostRecoveryError.unsupportedIdentity }
        try acquire(device)
        recoveryInProgress = true
        defer { transactions[device.id] = nil; recoveryInProgress = false }
        try await storage.ensureNoPendingOperations(for: nil)
        // Drain a coalesced pre-operation refresh; validation always uses an uncached CLI read.
        if let refreshTask { _ = try? await refreshTask.value }
        return try await hostRecovery.recover(device) { try await self.recoverySnapshot() }
    }

    private func recoverySnapshot() async throws -> [USBDevice] {
        let detailed = try await listDevices()
        // JSON ports are independent evidence. Never let a conflicting info/text
        // response erase OrbStack's explicit attached state during recovery.
        let raw = try USBParser.listJSON(try await command(["usb", "list", "-f", "json"]).stdout)
        return raw.map { entry in
            guard var device = detailed.first(where: { $0.id == entry.id }),
                  device.vendorID == entry.vendorID, device.productID == entry.productID,
                  device.serialNumber == entry.serialNumber, device.enumeration == entry.enumeration else {
                var unknown = entry
                unknown.state = .unknown
                unknown.detailError = "OrbStack USB identity changed during verification"
                return unknown
            }
            if entry.state == .attached { device.state = .attached }
            return device
        }
    }

    func findOrbExecutable() async throws -> URL {
        if let executableOverride {
            guard FileManager.default.isExecutableFile(atPath: executableOverride.path) else {
                throw OrbStackError.executableNotFound
            }
            executable = executableOverride
            return executableOverride
        }
        if let executable, FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        let discovered = try await cli.findOrbExecutable()
        executable = discovered
        return discovered
    }

    func loadVersion() async {
        if let result = try? await command(["version"]) {
            version = result.stdout.components(separatedBy: .newlines).first ?? "Unknown"
        }
    }

    // All refresh callers share a single in-flight snapshot.
    func refresh() async throws -> [USBDevice] {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.listDevices() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func listDevices() async throws -> [USBDevice] {
        let result: CLIResult
        do {
            result = try await command(["usb", "list", "-f", "json"])
        } catch OrbStackError.commandFailed(let reason) where reason.contains("unknown shorthand flag") || reason.contains("unknown flag") {
            throw OrbStackError.parseFailed("This OrbStack version does not support JSON. Update OrbStack to 2.2.3 or later.")
        }
        let devices = try USBParser.listJSON(result.stdout)
        var updated: [USBDevice] = []
        // Small batches keep refresh latency down without spawning one process per device at once.
        for start in stride(from: 0, to: devices.count, by: 4) {
            let batch = Array(devices[start..<min(start + 4, devices.count)])
            let values = await withTaskGroup(of: USBDevice?.self, returning: [USBDevice].self) { group in
                for device in batch {
                    group.addTask {
                        do { return try await self.getDeviceInfo(device: device) }
                        catch OrbStackError.deviceNotFound { return nil }
                        catch {
                            var unknown = device
                            unknown.detailError = error.localizedDescription
                            return unknown
                        }
                    }
                }
                var values: [USBDevice] = []
                for await value in group { if let value { values.append(value) } }
                return values
            }
            updated.append(contentsOf: values)
        }
        // Explicit text STATE supplements JSON/info for automatically forwarded devices.
        // A failure to read it never labels an unverified device as safely available.
        do {
            let text = try await command(["usb", "list"])
            let states = try USBParser.listTextStates(text.stdout)
            updated = updated.map { device in
                var value = device
                if value.state == .available || value.state == .unknown, let state = states[value.id] {
                    value.state = state
                }
                return value
            }
        } catch {
            updated = updated.map { device in
                var value = device
                if value.state != .attached {
                    value.state = .unknown
                    value.detailError = "Unable to verify sharing state"
                }
                return value
            }
        }
        return updated.sorted { $0.id < $1.id }
    }

    func getDeviceInfo(id: String) async throws -> USBDevice {
        guard USBParser.validID(id) else { throw OrbStackError.deviceNotFound }
        return try await getDeviceInfo(device: USBDevice(id: id, name: "USB device"))
    }

    private func getDeviceInfo(device: USBDevice) async throws -> USBDevice {
        let result = try await command(["usb", "info", device.id])
        return try USBParser.info(result.stdout, device: device)
    }

    func attachDevice(id: String) async throws {
        try await attachDevice(id: id, machine: nil)
    }

    func attachDevice(id: String, machine: String?) async throws {
        guard USBParser.validID(id), let device = try await listDevices().first(where: { $0.id == id }) else {
            throw OrbStackError.deviceNotFound
        }
        try await attachDevice(device, machine: machine) { _ in }
    }

    func attachDevice(_ device: USBDevice, machine: String?,
                      progress: @MainActor @Sendable (USBOperationPhase) -> Void) async throws {
        try await transferDevice(device, machine: machine, dryRun: false, progress: progress)
    }

    // Runs the same reservation, DA preparation, OrbStack read-only identity
    // refresh and final launch guard, but never starts an attach command.
    func diagnoseStorageHandoff(_ device: USBDevice) async throws {
        try await transferDevice(device, machine: nil, dryRun: true) { _ in }
    }

    private func transferDevice(_ device: USBDevice, machine: String?, dryRun: Bool,
                                progress: @MainActor @Sendable (USBOperationPhase) -> Void) async throws {
        try acquire(device)
        defer { transactions[device.id] = nil }
        Log.usb.debug("[USB Attach] request device=\(device.id, privacy: .public)")
        var preparationStarted = false
        transition(device, to: .preparing)
        do {
            guard device.state == .available else { throw USBStorageError.stateChanged }
            try Task.checkCancellation()
            var current = device
            var disks: [USBStorageDisk] = []
            let needsStorage = try await storage.begin(for: device)
            preparationStarted = true
            try Task.checkCancellation()
            if needsStorage {
                await progress(.resolvingDisk)
                disks = try await storage.resolveDisks(for: device)
                if !disks.isEmpty {
                    await progress(.waitingForMount)
                    try await storage.waitForMount(on: disks)
                    await progress(.unmountingVolumes)
                    try await storage.unmountVolumes(on: disks)
                    await progress(.verifyingUnmount)
                    Log.usb.debug("[USB Attach] verifying child volumes")
                    try await storage.verifyUnmount(on: disks)
                }
                transition(device, to: .ejecting)
                await progress(.ejecting)
                try Task.checkCancellation()
                try await storage.ejectDisks(for: device, on: disks)
                transition(device, to: .waitingForStorageRelease)
                await progress(.waitingForStorageRelease)
                try await storage.waitForStorageRelease(for: device)
                await progress(.resolvingUSBID)
                if let refreshTask { _ = try? await refreshTask.value }
                current = try device.resolvedAfterUnmount(in: await listDevices())
                // A new bus ID or USB enumeration is a new connection, even
                // with a duplicated serial. Never transfer to a replacement.
                guard current.connectionKey == device.connectionKey else { throw USBStorageError.identityChanged }
            }
            // Resolve the executable before the final host checks (discovery can await).
            let executable = try await findOrbExecutable()
            await progress(.attaching)
            try await storage.finalCheck(for: current, on: disks)
            try Task.checkCancellation()
            guard transactions[device.id] == device else { throw USBStorageError.identityChanged }
            if dryRun {
                try storage.launchValidation(for: current)()
                try Task.checkCancellation()
                await storage.end(for: device)
                transition(device, to: .idle)
                Log.usb.info("[USBTransfer] diagnostic PASS; OrbStack attach was not invoked")
                return
            }
            transition(device, to: .attaching)
            try await performAttach(id: current.id, machine: machine, executable: executable,
                                    beforeLaunch: storage.launchValidation(for: current))
            Log.usb.debug("[USB Attach] attach succeeded")
            if preparationStarted { await storage.end(for: device) }
            transition(device, to: .attached)
        } catch {
            // Equivalent to async defer: pending approval is cleared before unlocking.
            if preparationStarted { await storage.end(for: device) }
            transition(device, to: .failed)
            Log.usb.error("[USBTransfer] aborting attach id=\(device.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            Log.usb.error("[USB Attach] aborted: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    private func performAttach(id: String, machine: String?, executable: URL,
                               beforeLaunch: @escaping @Sendable () throws -> Void) async throws {
        guard USBParser.validID(id) else { throw OrbStackError.deviceNotFound }
        var arguments = ["usb", "attach", id]
        if let machine, !machine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-m", machine]
        }
        let result = try await cli.run(executable: executable, arguments: arguments, timeout: 30, beforeLaunch: {
            try beforeLaunch()
            Log.usb.info("[USBTransfer] invoking OrbStack USB attach")
        })
        guard result.terminationStatus == 0 else {
            throw OrbStackError.commandFailure(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func detachDevice(id: String) async throws {
        guard USBParser.validID(id) else { throw OrbStackError.deviceNotFound }
        try acquire(USBDevice(id: id, name: "USB device"))
        defer { transactions[id] = nil }
        let device = USBDevice(id: id, name: "USB device")
        transition(device, to: .detaching)
        do {
            try await storage.ensureNoPendingOperations(for: id)
            try Task.checkCancellation()
            _ = try await command(["usb", "detach", id], timeout: 30)
            transition(device, to: .idle)
        } catch {
            transition(device, to: .failed)
            throw error
        }
    }

    private func command(_ arguments: [String], timeout: TimeInterval = 12) async throws -> CLIResult {
        let executable = try await findOrbExecutable()
        let result = try await cli.run(executable: executable, arguments: arguments, timeout: timeout)
        guard result.terminationStatus == 0 else {
            throw OrbStackError.commandFailure(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }
}
