import XCTest
#if SWIFT_PACKAGE
@testable import OrbUSBCore
#else
@testable import OrbUSB
#endif

@MainActor
final class USBStorageTests: XCTestCase {
    private func device(id: String = "00200000", serial: String? = "fixture", enumeration: Int = 1) -> USBDevice {
        USBDevice(id: id, name: "Fixture disk", vendorID: "1234", productID: "abcd",
                  product: "Disk", serialNumber: serial, state: .available, type: "Storage", enumeration: enumeration)
    }

    func testDiskResolutionRequiresUniqueHardwareIdentity() throws {
        let disk = USBStorageDisk(bsdName: "disk8", registryID: 123)
        let host = USBStorageHost(vendorID: "1234", productID: "abcd", serialNumber: "fixture",
                                  locationID: 0x00200000, disks: [disk])
        let other = USBStorageHost(vendorID: "1234", productID: "abcd", serialNumber: "other",
                                   locationID: 0x00300000, disks: [.init(bsdName: "disk9", registryID: 124)])
        XCTAssertEqual(try USBStorageService.disks(for: device(), hosts: [other, host]), [disk])
        XCTAssertEqual(try USBStorageService.disks(for: device(serial: nil), hosts: [other, host]), [disk])
        XCTAssertThrowsError(try USBStorageService.disks(for: device(), hosts: [host, host])) {
            XCTAssertEqual($0 as? USBStorageError, .ambiguousDevice)
        }
        XCTAssertThrowsError(try USBStorageService.disks(for: device(), hosts: [other]))
        XCTAssertThrowsError(try USBStorageService.disks(for: device(), hosts: []))
    }

    func testReResolveUsesSerialAndRejectsAmbiguityReplacementAndStateChanges() throws {
        let original = device()
        let changed = device(id: "00300000", enumeration: 2)
        XCTAssertEqual(try original.resolvedAfterUnmount(in: [changed]), changed)
        XCTAssertThrowsError(try original.resolvedAfterUnmount(in: [original, changed]))
        XCTAssertThrowsError(try original.resolvedAfterUnmount(in: [device(serial: "replacement")]))
        XCTAssertThrowsError(try original.resolvedAfterUnmount(in: []))
        for status in [USBDeviceState.attached, .forwarded, .unknown] {
            var unavailable = changed
            unavailable.state = status
            XCTAssertThrowsError(try original.resolvedAfterUnmount(in: [unavailable])) {
                XCTAssertEqual($0 as? USBStorageError, .stateChanged)
            }
        }
        XCTAssertEqual(try device(serial: nil).resolvedAfterUnmount(in: [device(serial: nil)]), device(serial: nil))
        XCTAssertThrowsError(try device(serial: nil).resolvedAfterUnmount(in: [device(serial: nil, enumeration: 2)]))
        XCTAssertThrowsError(try device(serial: nil).resolvedAfterUnmount(in: [device(id: "00300000", serial: nil)]))
    }

    func testUnmountRejectsInvalidOrReusedDiskBeforeRunningCommand() async {
        for disk in [USBStorageDisk(bsdName: "disk8;echo", registryID: 0), .init(bsdName: "disk8", registryID: 0)] {
            do {
                try await USBStorageService().unmountVolumes(on: [disk])
                XCTFail("Invalid media must not reach diskutil")
            } catch { XCTAssertTrue(error is USBStorageError) }
        }
    }

    func testStorageAttachUnmountsAllDisksThenUsesNewID() async throws {
        let fixture = try AttachFixture(before: device(), after: [device(id: "00300000", enumeration: 2)])
        defer { fixture.remove() }
        var phases: [USBOperationPhase] = []
        try await fixture.service.attachDevice(device(), machine: "linux") { phases.append($0) }
        XCTAssertEqual(phases, [.resolvingDisk, .unmountingVolumes, .resolvingUSBID, .attaching])
        let unmounted = await fixture.storage.unmountedDisks
        XCTAssertEqual(unmounted.map(\.bsdName), ["disk8", "disk9"])
        let calls = try fixture.calls()
        XCTAssertEqual(calls.last, "usb attach 00300000 -m linux")
        XCTAssertEqual(calls.first, "usb list -f json", "The post-unmount list must precede attach")
        XCTAssertFalse(calls.contains { $0.hasPrefix("usb attach 00200000") })
    }

    func testUnmountFailureNeverReresolvesOrAttaches() async throws {
        let fixture = try AttachFixture(before: device(), after: [device()], unmountError: .unmountFailed("Disk is busy"))
        defer { fixture.remove() }
        var phases: [USBOperationPhase] = []
        do {
            try await fixture.service.attachDevice(device(), machine: nil) { phases.append($0) }
            XCTFail("Unmount must fail")
        } catch { XCTAssertEqual(error as? USBStorageError, .unmountFailed("Disk is busy")) }
        XCTAssertEqual(phases, [.resolvingDisk, .unmountingVolumes])
        XCTAssertTrue(try fixture.calls().isEmpty)
    }

    func testDiskResolutionFailureNeverUnmountsOrAttaches() async throws {
        let fixture = try AttachFixture(before: device(), after: [device()], resolutionError: .diskNotFound)
        defer { fixture.remove() }
        do {
            try await fixture.service.attachDevice(device(), machine: nil) { _ in }
            XCTFail("Missing disk must fail")
        } catch { XCTAssertEqual(error as? USBStorageError, .diskNotFound) }
        let disks = await fixture.storage.unmountedDisks
        XCTAssertTrue(disks.isEmpty)
        XCTAssertTrue(try fixture.calls().isEmpty)
    }

    func testReresolutionFailureNeverAttaches() async throws {
        var forwarded = device(id: "00300000")
        forwarded.state = .forwarded
        for after in [[], [device(serial: "replacement")], [device(), device(id: "00300000")], [forwarded]] {
            let fixture = try AttachFixture(before: device(), after: after)
            defer { fixture.remove() }
            do {
                try await fixture.service.attachDevice(device(), machine: nil) { _ in }
                XCTFail("Unverified device must not attach")
            } catch { XCTAssertTrue(error is USBStorageError) }
            XCTAssertFalse(try fixture.calls().contains { $0.hasPrefix("usb attach") })
        }
    }

    func testExistingAttachByIDAlsoPreparesStorage() async throws {
        let fixture = try AttachFixture(before: device(), after: [device(id: "00300000", enumeration: 2)])
        defer { fixture.remove() }
        try await fixture.service.attachDevice(id: "00200000")
        let disks = await fixture.storage.unmountedDisks
        XCTAssertEqual(disks.count, 2)
        XCTAssertEqual(try fixture.calls().last, "usb attach 00300000")
    }

    func testNonStorageAndDetachSkipDiskPreparation() async throws {
        var audio = device()
        audio.type = "Audio"
        let fixture = try AttachFixture(before: audio, after: [audio], resolutionError: .diskNotFound)
        defer { fixture.remove() }
        var phases: [USBOperationPhase] = []
        try await fixture.service.attachDevice(audio, machine: nil) { phases.append($0) }
        try await fixture.service.detachDevice(id: audio.id)
        XCTAssertEqual(phases, [.attaching])
        XCTAssertEqual(try fixture.calls(), ["usb attach 00200000", "usb detach 00200000"])
        let disks = await fixture.storage.unmountedDisks
        XCTAssertTrue(disks.isEmpty)
    }

    #if !SWIFT_PACKAGE
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !(await condition()) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out waiting for operation")
    }

    func testAppStateUnmountFailureReturnsAvailableWithErrorAndAllowsRetry() async throws {
        let fixture = try AttachFixture(before: device(), after: [device()], unmountError: .unmountFailed("Disk is busy"))
        defer { fixture.remove() }
        let state = AppState(service: fixture.service, startMonitoring: false)
        defer { state.shutdown() }
        state.devices = [device()]
        state.toggle(device())
        XCTAssertEqual(state.operation(for: device())?.phase, .resolvingDisk)
        try await waitUntil { state.operations.isEmpty }
        XCTAssertEqual(state.devices.first?.state, .available)
        XCTAssertTrue(state.rowErrors[device().connectionKey]?.contains("Disk is busy") == true)
        XCTAssertFalse(try fixture.calls().contains { $0.hasPrefix("usb attach") })
        await fixture.storage.setUnmountError(nil)
        state.toggle(device())
        XCTAssertNil(state.rowErrors[device().connectionKey])
        try await waitUntil { state.operations.isEmpty }
        XCTAssertEqual(state.devices.first?.state, .attached)
        XCTAssertTrue(state.rowErrors.isEmpty)
    }

    func testAppStateLocksReenumeratedRowAndRefreshesAttachedState() async throws {
        let changed = device(id: "00300000", enumeration: 2)
        let fixture = try AttachFixture(before: device(), after: [changed], pauseUnmount: true)
        defer { fixture.remove() }
        let state = AppState(service: fixture.service, startMonitoring: false)
        defer { state.shutdown() }
        state.devices = [device()]
        state.toggle(device())
        state.toggle(device())
        try await waitUntil { await fixture.storage.isPaused }
        XCTAssertEqual(state.operation(for: changed)?.phase, .unmountingVolumes)
        // Simulate a hotplug refresh publishing the new ID during the operation.
        state.devices = [changed]
        state.toggle(changed)
        XCTAssertEqual(state.operations.count, 1)
        await fixture.storage.resume()
        try await waitUntil { state.operations.isEmpty }
        XCTAssertEqual(state.devices.first?.id, changed.id)
        XCTAssertEqual(state.devices.first?.state, .attached)
        XCTAssertEqual(try fixture.calls().filter { $0.hasPrefix("usb attach") }, ["usb attach 00300000"])
    }

    func testAppStateAttachErrorFollowsNewID() async throws {
        let changed = device(id: "00300000", enumeration: 2)
        let fixture = try AttachFixture(before: device(), after: [changed], failAttach: true)
        defer { fixture.remove() }
        let state = AppState(service: fixture.service, startMonitoring: false)
        defer { state.shutdown() }
        state.devices = [device()]
        state.toggle(device())
        try await waitUntil { state.operations.isEmpty }
        XCTAssertEqual(state.devices.first?.id, changed.id)
        XCTAssertEqual(state.devices.first?.state, .available)
        XCTAssertNotNil(state.rowErrors[changed.connectionKey])
        XCTAssertNil(state.rowErrors[device().connectionKey])
    }
    #endif
}

private actor StorageFixture: USBStoragePreparing {
    let directory: URL
    let resolutionError: USBStorageError?
    var unmountError: USBStorageError?
    let pauseUnmount: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var unmountedDisks: [USBStorageDisk] = []
    var isPaused: Bool { continuation != nil }

    init(directory: URL, resolutionError: USBStorageError?, unmountError: USBStorageError?, pauseUnmount: Bool) {
        self.directory = directory
        self.resolutionError = resolutionError
        self.unmountError = unmountError
        self.pauseUnmount = pauseUnmount
    }

    func resolveDisks(for device: USBDevice) async throws -> [USBStorageDisk] {
        if let resolutionError { throw resolutionError }
        return [.init(bsdName: "disk8", registryID: 123), .init(bsdName: "disk9", registryID: 124)]
    }

    func unmountVolumes(on disks: [USBStorageDisk]) async throws {
        unmountedDisks = disks
        if pauseUnmount { await withCheckedContinuation { continuation = $0 } }
        if let unmountError { throw unmountError }
        try Data().write(to: directory.appendingPathComponent("unmounted"))
    }

    func setUnmountError(_ error: USBStorageError?) { unmountError = error }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private struct AttachFixture {
    let directory: URL
    let storage: StorageFixture
    let service: OrbStackUSBService

    init(before: USBDevice, after: [USBDevice], resolutionError: USBStorageError? = nil,
         unmountError: USBStorageError? = nil, pauseUnmount: Bool = false, failAttach: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbUSB-Attach-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = StorageFixture(directory: directory, resolutionError: resolutionError,
                                 unmountError: unmountError, pauseUnmount: pauseUnmount)
        let executable = directory.appendingPathComponent("orb-fixture")
        service = OrbStackUSBService(executable: executable, storage: storage)
        for (prefix, devices) in [("before", [before]), ("after", after)] {
            let json: [String: Any] = ["devices": devices.map { device -> [String: Any] in
                var entry: [String: Any] = ["bus_id": device.id, "path": "Disk", "vendor_id": 0x1234,
                    "product_id": 0xabcd, "category": device.type ?? "Storage", "dev_num": device.enumeration ?? 1]
                if let serial = device.serialNumber { entry["serial_number"] = serial }
                return entry
            }, "ports": []]
            try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent(prefix + ".json"))
            let rows = devices.map { "\($0.id)  1234:abcd  Disk  \($0.state == .forwarded ? "forwarded" : "Not shared")" }.joined(separator: "\n")
            try rows.write(to: directory.appendingPathComponent(prefix + ".txt"), atomically: true, encoding: .utf8)
            for device in devices {
                let info = "Details:\nID: \(device.id)\nName: Disk\nType: \(device.type ?? "Storage")\nPassthrough:\nMachine: Not attached\n"
                try info.write(to: directory.appendingPathComponent(prefix + "-" + device.id + ".txt"), atomically: true, encoding: .utf8)
            }
        }
        let script = """
        #!/bin/sh
        base="$(dirname "$0")"
        if [ "$1" = version ]; then echo fixture; exit 0; fi
        printf '%s\\n' "$*" >> "$base/calls"
        prefix=before
        if [ -f "$base/unmounted" ]; then prefix=after; fi
        case "$2" in
          list)
            if [ "$4" = json ]; then
              /bin/cat "$base/$prefix.json"
            elif [ -f "$base/attached" ]; then
              /usr/bin/sed 's/Not shared/attached/g' "$base/$prefix.txt"
            else
              /bin/cat "$base/$prefix.txt"
            fi
            ;;
          info)
            if [ -f "$base/attached" ]; then
              /usr/bin/sed 's/Not attached/default/g' "$base/$prefix-$3.txt"
            else
              /bin/cat "$base/$prefix-$3.txt"
            fi
            ;;
          attach)
            if [ \(failAttach ? "1" : "0") = 1 ]; then echo 'Device is busy' >&2; exit 1; fi
            /usr/bin/touch "$base/attached"
            ;;
          detach) exit 0 ;;
          *) exit 1 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func calls() throws -> [String] {
        let url = directory.appendingPathComponent("calls")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
