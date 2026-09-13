import XCTest
#if SWIFT_PACKAGE
@testable import OrbUSBCore
#else
@testable import OrbUSB
#endif

@MainActor
final class USBHostRecoveryTests: XCTestCase {
    private func host(serial: String? = "fixture-001", location: UInt32 = 0x01220000,
                      generation: UInt64 = 100, storage: Bool = false, ready: Bool = false) -> USBHostSnapshot {
        var host = USBHostSnapshot(identity: USBHostIdentity(vendorID: 0x0bda, productID: storage ? 0x9210 : 0x8156,
            serialNumber: serial, locationID: location, registryEntryID: generation,
            topologyPath: "IOService:/controller/port/USB@\(location)", parentRegistryEntryID: 50),
            configuration: ready && !storage ? 2 : 1, interfaceClasses: storage ? [8] : ready ? [2, 10] : [255])
        if ready {
            host.hasFunctionalDriver = true
            if storage {
                host.hasSCSI = true
                host.mediaIDs = [501, 502]
                host.wholeDisks = ["disk27"]
                host.mountedVolumes = ["/Volumes/Fixture"]
            } else { host.networkInterfaces = ["en37"] }
        }
        return host
    }

    private func device(_ host: USBHostSnapshot) -> USBDevice {
        USBDevice(id: String(format: "%08x", host.identity.locationID), name: "Fixture",
            vendorID: String(format: "%04x", host.identity.vendorID), productID: String(format: "%04x", host.identity.productID),
            serialNumber: host.identity.serialNumber, state: .available, type: host.hasStorage ? "Storage" : "Network",
            enumeration: 3, hostIdentity: host.identity, hostBindingState: .driverUnavailable, recoveryEligibility: .eligible)
    }

    func testIdentityUsesSerialLocationTopologyAndCurrentGeneration() throws {
        let original = host()
        let expected = device(original)
        let other = host(serial: "fixture-002", location: 0x01230000, generation: 101)
        XCTAssertEqual(try USBRecoveryPolicy.resolve(expected, in: [other, original], anchor: original.identity), original)
        for replacement in [host(serial: "fixture-002"), host(location: 0x01230000), host(generation: 102)] {
            XCTAssertThrowsError(try USBRecoveryPolicy.resolve(expected, in: [replacement], anchor: original.identity))
        }
        let next = host(generation: 102)
        XCTAssertEqual(try USBRecoveryPolicy.resolve(expected, in: [next], anchor: original.identity, afterReset: true), next)
        var moved = next
        moved.identity.parentRegistryEntryID = 51
        XCTAssertThrowsError(try USBRecoveryPolicy.resolve(expected, in: [moved], anchor: original.identity, afterReset: true))
        moved = next
        moved.identity.topologyPath += "/different-port"
        XCTAssertThrowsError(try USBRecoveryPolicy.resolve(expected, in: [moved], anchor: original.identity, afterReset: true))
    }

    func testNoSerialAndAbnormalSerialRefuseRecovery() throws {
        for serial in [nil, "", "00000000", "1234567890", "unknown", " aaaa ", "abc\n123"] as [String?] {
            let value = host(serial: serial)
            XCTAssertThrowsError(try USBRecoveryPolicy.validate(value, device: device(value), allHosts: [value], function: .network)) {
                XCTAssertEqual($0 as? USBHostRecoveryError, .unsupportedIdentity)
            }
        }
    }

    func testDuplicateSerialAtDifferentLocationAndAmbiguousLocationRefuse() throws {
        let original = host()
        let duplicate = host(location: 0x01230000, generation: 102)
        XCTAssertThrowsError(try USBRecoveryPolicy.validate(original, device: device(original), allHosts: [original, duplicate], function: .network)) {
            XCTAssertEqual($0 as? USBHostRecoveryError, .ambiguousIdentity)
        }
        XCTAssertThrowsError(try USBRecoveryPolicy.resolve(device(original), in: [original, original])) {
            XCTAssertEqual($0 as? USBHostRecoveryError, .ambiguousIdentity)
        }
    }

    func testSafetyVetoesOwnersAttachedForwardedHubControllerAndPartialDriver() throws {
        let original = host()
        for state in [USBDeviceState.attached, .forwarded, .unknown] {
            var value = device(original)
            value.state = state
            XCTAssertThrowsError(try USBRecoveryPolicy.validate(original, device: value, allHosts: [original], function: .network))
        }
        let mutations: [(inout USBHostSnapshot) -> Void] = [
            { $0.exclusiveOwners = ["pid 99, OrbStack Helper"] },
            { $0.userClients = ["pid 99, Other app"] },
            { $0.exclusiveOwners = ["Unknown owner"] },
            { $0.deviceClass = 9 }, { $0.interfaceClasses = [9] }, { $0.isController = true },
            { $0.hasFunctionalDriver = true }, { $0.busy = true }, { $0.topologyComplete = false },
            { $0.storageAuditComplete = false }, { $0.interfaceClasses = [3] }
        ]
        for mutate in mutations {
            var value = original
            mutate(&value)
            XCTAssertThrowsError(try USBRecoveryPolicy.validate(value, device: device(original), allHosts: [value], function: .network))
        }
    }

    func testMediaDiskVolumeAndSnapshotIndividuallyVetoStorageReset() {
        let original = host(storage: true)
        let mutations: [(inout USBHostSnapshot) -> Void] = [
            { $0.mediaIDs = [42] }, { $0.wholeDisks = ["disk4"] },
            { $0.mountedVolumes = ["/Volumes/Disk"] },
            { $0.mountedVolumes = ["/Volumes/.timemachine/snapshot"] }
        ]
        for mutate in mutations {
            var value = original
            mutate(&value)
            XCTAssertThrowsError(try USBRecoveryPolicy.validate(value, device: device(original), allHosts: [value], function: .storage)) {
                XCTAssertEqual($0 as? USBHostRecoveryError, .storageInUse)
            }
        }
    }

    func testReadyRequiresFunctionalStackAndDoesNotDependOnBSDNumbers() throws {
        XCTAssertFalse(host().ready(for: .network))
        XCTAssertFalse(host(storage: true).ready(for: .storage))
        for number in [4, 5, 27, 99] {
            var disk = host(storage: true, ready: true)
            disk.wholeDisks = ["disk\(number)"]
            XCTAssertTrue(disk.ready(for: .storage))
            XCTAssertEqual(try USBRecoveryPolicy.validate(disk, device: device(disk), allHosts: [disk], function: .storage), .alreadyRecovered)
            var network = host(ready: true)
            network.networkInterfaces = ["en\(number)"]
            XCTAssertTrue(network.ready(for: .network))
        }
    }

    func testReturningUnavailableRecoveringAvailableAndSubscribeBeforeSnapshot() async throws {
        let original = host()
        let backend = RecoveryBackendFixture(initial: [original], afterReset: [[host(generation: 102)], [host(generation: 102, ready: true)]])
        let recovery = USBHostRecoveryService(backend: backend, returnGrace: 8)
        let now = Date()
        let returning = await recovery.decorate([device(original)], now: now)
        XCTAssertEqual(returning[0].hostBindingState, .returning)
        let unavailable = await recovery.decorate([device(original)], now: now.addingTimeInterval(9))
        XCTAssertEqual(unavailable[0].hostBindingState, .driverUnavailable)
        let expected = unavailable[0]
        let result = try await recovery.recover(expected) { [expected] }
        XCTAssertEqual(result.outcome, .recovered)
        XCTAssertEqual(result.after.identity.registryEntryID, 102)
        XCTAssertEqual(result.after.networkInterfaces, ["en37"])
        let calls = await backend.calls
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "subscribe")), try XCTUnwrap(calls.firstIndex(of: "reset")))
        XCTAssertEqual(calls.filter { $0 == "reset" }.count, 1)
        XCTAssertEqual(calls.last, "stop")
        let available = await recovery.decorate([expected])
        XCTAssertEqual(available[0].hostBindingState, .available)
    }

    func testEventBetweenSubscriptionAndSnapshotIsNotLostAndSameGenerationCanRecover() async throws {
        let original = host()
        let expected = device(original)
        let backend = RecoveryBackendFixture(initial: [original], afterReset: [[host(ready: true)]])
        let service = USBHostRecoveryService(backend: backend)
        let result = try await service.recover(expected) { [expected] }
        XCTAssertEqual(result.before.identity.registryEntryID, result.after.identity.registryEntryID)
        let calls = await backend.calls
        XCTAssertEqual(Array(calls.prefix(2)), ["subscribe", "snapshot"])
        XCTAssertEqual(result.outcome, .recovered)
    }

    func testDriverRecoversAfterClickAndBeforeOpenSkipsReset() async throws {
        let original = host()
        let expected = device(original)
        let backend = RecoveryBackendFixture(initial: [host(ready: true)])
        let result = try await USBHostRecoveryService(backend: backend).recover(expected) { [expected] }
        XCTAssertEqual(result.outcome, .alreadyRecovered)
        let calls = await backend.calls
        XCTAssertFalse(calls.contains("reset"))
        XCTAssertFalse(calls.contains("open"))
    }

    func testFinalOpenCheckFindsDriverRecoveredSkipsReset() async throws {
        let original = host(storage: true)
        let expected = device(original)
        let backend = RecoveryBackendFixture(initial: [original], afterReset: [[host(storage: true, ready: true)]], skipReset: true)
        let result = try await USBHostRecoveryService(backend: backend).recover(expected) { [expected] }
        XCTAssertEqual(result.outcome, .alreadyRecovered)
        let calls = await backend.calls
        XCTAssertTrue(calls.contains("open"))
        XCTAssertFalse(calls.contains("reset"))
    }

    func testOpenAndResetFailureStopWithoutRetryAndPreserveUnderlyingError() async throws {
        for error in [USBHostRecoveryError.openFailed("IOKit (busy): exclusive access"), .resetFailed("IOKit: not responding")] {
            let original = host()
            let expected = device(original)
            let backend = RecoveryBackendFixture(initial: [original], failure: error)
            let service = USBHostRecoveryService(backend: backend, returnGrace: 0)
            do { _ = try await service.recover(expected) { [expected] }; XCTFail("Expected failure") }
            catch let actual { XCTAssertEqual(actual as? USBHostRecoveryError, error) }
            let calls = await backend.calls
            XCTAssertEqual(calls.filter { $0 == "open" }.count, 1)
            XCTAssertLessThanOrEqual(calls.filter { $0 == "reset" }.count, 1)
            XCTAssertEqual(calls.last, "stop")
            let failed = await service.decorate([expected])
            XCTAssertEqual(failed[0].hostBindingState, .failed)
            XCTAssertEqual(failed[0].recoveryError, error.localizedDescription)
        }
    }

    func testFreshOrbAttachedRefusesBeforeOpen() async throws {
        let original = host()
        let expected = device(original)
        var attached = expected
        attached.state = .attached
        let fresh = attached
        let backend = RecoveryBackendFixture(initial: [original])
        do { _ = try await USBHostRecoveryService(backend: backend).recover(expected) { [fresh] }; XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? USBHostRecoveryError, .stillAttachedToOrbStack) }
        let calls = await backend.calls
        XCTAssertFalse(calls.contains("open"))
    }

    func testPhysicalDisconnectAndReplacementNeverReportSuccess() async throws {
        let original = host()
        let expected = device(original)
        let cases: [([[USBHostSnapshot]], USBHostRecoveryError)] = [
            ([[]], .deviceDisappeared),
            ([[host(generation: 101)], []], .deviceDisappeared),
            ([[host(serial: "replacement-123", generation: 101, ready: true)]], .identityChanged),
            ([[host(generation: 101)], [host(generation: 102, ready: true)]], .identityChanged)
        ]
        for (sequence, failure) in cases {
            let backend = RecoveryBackendFixture(initial: [original], afterReset: sequence)
            do { _ = try await USBHostRecoveryService(backend: backend).recover(expected) { [expected] }; XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? USBHostRecoveryError, failure) }
            let calls = await backend.calls
            XCTAssertEqual(calls.filter { $0 == "reset" }.count, 1)
            XCTAssertEqual(calls.last, "stop")
        }
    }

    func testUSBAndFunctionalTimeoutAndLateEventNeverRetry() async throws {
        let original = host()
        let expected = device(original)
        for (after, failure) in [(host(), USBHostRecoveryError.reenumerationTimedOut), (host(generation: 101), .functionalDriverTimedOut)] {
            let backend = RecoveryBackendFixture(initial: [original], afterReset: [[after]])
            let service = USBHostRecoveryService(backend: backend)
            do { _ = try await service.recover(expected) { [expected] }; XCTFail("Expected timeout") }
            catch { XCTAssertEqual(error as? USBHostRecoveryError, failure) }
            await backend.lateEvent(host(generation: 101, ready: true))
            let calls = await backend.calls
            XCTAssertEqual(calls.filter { $0 == "reset" }.count, 1)
            XCTAssertEqual(calls.last, "stop")
        }
    }

    func testFailureRemainsOnNewRegistryGeneration() async throws {
        let original = host()
        let expected = device(original)
        let next = host(generation: 101)
        let backend = RecoveryBackendFixture(initial: [original], afterReset: [[next]])
        let service = USBHostRecoveryService(backend: backend, returnGrace: 0)
        do { _ = try await service.recover(expected) { [expected] }; XCTFail("Expected unresolved driver") }
        catch { XCTAssertEqual(error as? USBHostRecoveryError, .functionalDriverTimedOut) }
        let list = await service.decorate([device(next)])
        XCTAssertEqual(list[0].hostBindingState, .failed)
        XCTAssertEqual(list[0].recoveryError, USBHostRecoveryError.functionalDriverTimedOut.localizedDescription)
    }

    func testSecondRecoveryRefusedWhileFirstAwaitsAndCancellationUnlocks() async throws {
        let original = host()
        let expected = device(original)
        let backend = RecoveryBackendFixture(initial: [original], afterReset: [[host(generation: 101)]], holdEvents: true)
        let service = USBHostRecoveryService(backend: backend)
        let first = Task { try await service.recover(expected) { [expected] } }
        await backend.waitUntilReset()
        let status = await service.decorate([expected])
        XCTAssertEqual(status[0].hostBindingState, .recovering)
        do { _ = try await service.recover(expected) { [expected] }; XCTFail("Expected lock") }
        catch { XCTAssertEqual(error as? USBHostRecoveryError, .operationInProgress) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch { }
        let eligibility = await service.canRecover(expected)
        XCTAssertNotEqual(eligibility, .ineligible(.operationInProgress))
        let calls = await backend.calls
        XCTAssertEqual(calls.last, "snapshot")
        XCTAssertTrue(calls.contains("stop"))
    }

    func testLiveIORegistrySnapshotReadOnly() async throws {
        let snapshots = try await SystemUSBHostRecoveryBackend().snapshots()
        for snapshot in snapshots {
            XCTAssertNotEqual(snapshot.identity.registryEntryID, 0)
            XCTAssertFalse(snapshot.identity.topologyPath.isEmpty)
        }
        // This integration test NEVER opens or resets hardware.
    }

    func testEmptyIORegistryMatchIsSuccessfulEmptySnapshot() throws {
        var count = 0
        try USBHostTopology.matching("OrbUSBNonexistentClassForEmptyMatchingTest") { _ in count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testMountedSnapshotSourceWithoutDevPrefixIsAudited() {
        XCTAssertTrue(USBHostTopology.isDiskBackedMount(source: "snapshot@/dev/disk9s2", fileSystem: "apfs"))
        XCTAssertTrue(USBHostTopology.isDiskBackedMount(source: "/dev/disk4s1", fileSystem: "msdos"))
        XCTAssertFalse(USBHostTopology.isDiskBackedMount(source: "server:/share", fileSystem: "nfs"))
    }

    func testOldDecorationCannotEraseNewGenerationFailure() async throws {
        let original = host()
        let expected = device(original)
        let backend = RecoveryBackendFixture(initial: [original], afterReset: [[host(generation: 101)]], pauseFirstSnapshot: true)
        let service = USBHostRecoveryService(backend: backend, returnGrace: 0)
        let old = Task { await service.decorate([expected]) }
        await backend.waitForPausedSnapshot()
        do { _ = try await service.recover(expected) { [expected] }; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? USBHostRecoveryError, .functionalDriverTimedOut) }
        await backend.releaseSnapshot()
        let discarded = await old.value
        XCTAssertEqual(discarded[0].hostBindingState, .unknown)
        let current = await service.decorate([expected])
        XCTAssertEqual(current[0].hostBindingState, .failed)
        XCTAssertEqual(current[0].hostIdentity?.registryEntryID, 101)
    }

    func testRecoveryHonorsJSONPortsWhenInfoAndTextConflict() async throws {
        let original = host()
        let expected = device(original)
        let backend = RecoveryBackendFixture(initial: [original])
        let fixture = try RecoveryCLIFixture(device: expected, backend: backend, reportedAttached: true)
        defer { fixture.remove() }
        do { _ = try await fixture.service.recoverDevice(expected); XCTFail("Expected JSON attached veto") }
        catch { XCTAssertEqual(error as? USBHostRecoveryError, .stillAttachedToOrbStack) }
        let calls = await backend.calls
        XCTAssertFalse(calls.contains("open"))
    }

    func testRecoverySharesMutationLockWithAttachAndDetach() async throws {
        let original = host()
        let expected = device(original)
        let backend = RecoveryBackendFixture(initial: [original], afterReset: [[host(generation: 101)]], holdEvents: true)
        let fixture = try RecoveryCLIFixture(device: expected, backend: backend)
        defer { fixture.remove() }
        let first = Task { try await fixture.service.recoverDevice(expected) }
        await backend.waitUntilReset()
        var unrelated = expected
        unrelated = USBDevice(id: "01230000", name: "Other", state: .available)
        do { try await fixture.service.attachDevice(unrelated, machine: nil) { _ in }; XCTFail("Expected lock") }
        catch { XCTAssertEqual(error as? USBHostRecoveryError, .operationInProgress) }
        do { try await fixture.service.detachDevice(id: unrelated.id); XCTFail("Expected lock") }
        catch { XCTAssertEqual(error as? USBHostRecoveryError, .operationInProgress) }
        do { _ = try await fixture.service.recoverDevice(expected); XCTFail("Expected lock") }
        catch { XCTAssertEqual(error as? USBHostRecoveryError, .operationInProgress) }
        first.cancel()
        _ = try? await first.value
        try await fixture.service.detachDevice(id: unrelated.id)
        let calls = await backend.calls
        XCTAssertEqual(calls.filter { $0 == "reset" }.count, 1)
    }

    #if !SWIFT_PACKAGE
    func testOldRefreshCannotOverwriteRecoveryAndLockLastsThroughRescan() async throws {
        let original = host()
        let expected = device(original)
        let backend = RecoveryBackendFixture(initial: [original], afterReset: [[host(generation: 101, ready: true)]], pauseFirstSnapshot: true)
        let fixture = try RecoveryCLIFixture(device: expected, backend: backend)
        defer { fixture.remove() }
        let state = AppState(service: fixture.service, startMonitoring: false)
        defer { state.shutdown() }
        state.devices = [expected]
        state.requestRefresh()
        await backend.waitForPausedSnapshot()
        state.recover(expected)
        await backend.waitUntilReset()
        state.toggle(expected)
        state.recover(expected)
        XCTAssertEqual(state.operations.count, 1)
        await backend.releaseSnapshot()
        let deadline = ContinuousClock.now + .seconds(5)
        while !state.operations.isEmpty || state.isRefreshing {
            guard ContinuousClock.now < deadline else { return XCTFail("Operation did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.devices.first?.hostBindingState, .available)
        XCTAssertEqual(state.devices.first?.hostIdentity?.registryEntryID, 101)
        XCTAssertTrue(state.rowErrors.isEmpty)
        let calls = await backend.calls
        XCTAssertEqual(calls.filter { $0 == "reset" }.count, 1)
    }
    #endif
}

actor RecoveryBackendFixture: USBHostRecoveryBackend {
    private var current: [USBHostSnapshot]
    private var afterReset: [[USBHostSnapshot]]
    private let failure: USBHostRecoveryError?
    private let skipReset: Bool
    private let holdEvents: Bool
    private var pauseFirstSnapshot: Bool
    private var pausedSnapshot: CheckedContinuation<Void, Never>?
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private var didOpen = false
    private var resetWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: AsyncStream<USBRecoveryEvent>.Continuation?
    private(set) var calls: [String] = []

    init(initial: [USBHostSnapshot], afterReset: [[USBHostSnapshot]] = [], failure: USBHostRecoveryError? = nil,
         skipReset: Bool = false, holdEvents: Bool = false, pauseFirstSnapshot: Bool = false) {
        current = initial
        self.afterReset = afterReset
        self.failure = failure
        self.skipReset = skipReset
        self.holdEvents = holdEvents
        self.pauseFirstSnapshot = pauseFirstSnapshot
    }

    func snapshots() async -> [USBHostSnapshot] {
        calls.append("snapshot")
        if pauseFirstSnapshot {
            pauseFirstSnapshot = false
            let old = current
            await withCheckedContinuation { continuation in
                pausedSnapshot = continuation
                snapshotWaiters.forEach { $0.resume() }
                snapshotWaiters.removeAll()
            }
            return old
        }
        if didOpen, !afterReset.isEmpty { current = afterReset.removeFirst() }
        return current
    }

    func observe(timeout: Duration) -> USBRecoveryObservation {
        calls.append("subscribe")
        let (events, continuation) = AsyncStream<USBRecoveryEvent>.makeStream()
        self.continuation = continuation
        // Deliberately enqueue an event BEFORE the service can take its first snapshot.
        continuation.yield(.changed)
        if !holdEvents {
            for _ in 0..<6 { continuation.yield(.changed) }
            continuation.yield(.deadline)
        }
        return USBRecoveryObservation(events: events, stop: { await self.stop() })
    }

    func reset(_ device: USBDevice, anchor: USBHostIdentity, function: USBHostFunction, operationID: UUID) throws -> Bool {
        calls.append("open")
        if case .openFailed = failure { throw failure! }
        if !skipReset { calls.append("reset") }
        if let failure { throw failure }
        didOpen = true
        resetWaiters.forEach { $0.resume() }
        resetWaiters.removeAll()
        return !skipReset
    }

    func waitUntilReset() async {
        if didOpen { return }
        await withCheckedContinuation { resetWaiters.append($0) }
    }

    func waitForPausedSnapshot() async {
        if pausedSnapshot != nil { return }
        await withCheckedContinuation { snapshotWaiters.append($0) }
    }

    func releaseSnapshot() {
        pausedSnapshot?.resume()
        pausedSnapshot = nil
    }

    private func stop() {
        calls.append("stop")
        continuation?.finish()
        continuation = nil
    }

    func lateEvent(_ host: USBHostSnapshot) {
        current = [host]
        continuation?.yield(.changed)
    }
}

private struct RecoveryCLIFixture {
    let directory: URL
    let service: OrbStackUSBService

    init(device: USBDevice, backend: any USBHostRecoveryBackend, reportedAttached: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbUSBRecoveryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("orb-fixture")
        let entry: [String: Any] = ["bus_id": device.id, "vendor_id": Int(device.vendorID!, radix: 16)!,
            "product_id": Int(device.productID!, radix: 16)!, "serial_number": device.serialNumber!,
            "category": "ethernet", "dev_num": device.enumeration!]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["devices": [entry], "ports": reportedAttached ? [entry] : []]), as: UTF8.self)
        let info = "Details:\nID: \(device.id)\nType: Ethernet\nPassthrough:\nMachine: Not attached\nInfo:\nVendor/Product ID: \(device.vidPID)\nSerial: \(device.serialNumber!)\n"
        func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        if [ "$1" = version ]; then printf 'Fixture'; exit 0; fi
        case "$2" in
        list) if [ "$4" = json ]; then printf '%s' \(quote(json)); else printf '%s\\n' \(quote("\(device.id)  \(device.vidPID)  Fixture  Available")); fi;;
        info) printf '%s' \(quote(info));;
        attach|detach) exit 0;;
        *) exit 1;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        service = OrbStackUSBService(executable: executable, hostRecovery: USBHostRecoveryService(backend: backend, returnGrace: 0))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
