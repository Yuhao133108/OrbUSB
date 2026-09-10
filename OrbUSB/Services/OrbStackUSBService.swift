import Foundation

actor OrbStackUSBService {
    private let cli = OrbCLI()
    private let executableOverride: URL?
    private let storage: any USBStoragePreparing

    init(executable: URL? = nil, storage: any USBStoragePreparing = USBStorageService()) {
        executableOverride = executable
        self.storage = storage
    }
    private(set) var executable: URL?
    private(set) var version = "Unknown"
    private var refreshTask: Task<[USBDevice], any Error>?

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
        guard device.state == .available else { throw USBStorageError.stateChanged }
        var current = device
        if device.isStorage {
            await progress(.resolvingDisk)
            let disks = try await storage.resolveDisks(for: device)
            guard !disks.isEmpty else { throw USBStorageError.diskNotFound }
            await progress(.unmountingVolumes)
            try await storage.unmountVolumes(on: disks)
            await progress(.resolvingUSBID)
            // A poll started before/during unmount must not supply the attach ID.
            if let refreshTask { _ = try? await refreshTask.value }
            current = try device.resolvedAfterUnmount(in: await listDevices())
        }
        try Task.checkCancellation()
        await progress(.attaching)
        try await performAttach(id: current.id, machine: machine)
    }

    private func performAttach(id: String, machine: String?) async throws {
        guard USBParser.validID(id) else { throw OrbStackError.deviceNotFound }
        var arguments = ["usb", "attach", id]
        if let machine, !machine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-m", machine]
        }
        _ = try await command(arguments, timeout: 30)
    }

    func detachDevice(id: String) async throws {
        guard USBParser.validID(id) else { throw OrbStackError.deviceNotFound }
        _ = try await command(["usb", "detach", id], timeout: 30)
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
