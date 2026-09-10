import XCTest
#if SWIFT_PACKAGE
@testable import OrbUSBCore
#else
@testable import OrbUSB
#endif

@MainActor
final class OrbUSBTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        #if SWIFT_PACKAGE
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
        #else
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
        #endif
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testCapturedMultipleDevices() throws {
        let devices = try USBParser.listJSON(fixture("list-captured-redacted.json"))
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].id, "00200000")
        XCTAssertEqual(devices[0].vidPID, "0bda:9210")
        XCTAssertEqual(devices[1].name, "Apple, Inc. EarPods")
        XCTAssertEqual(devices[0].state, .unknown, "JSON alone has no verified state")
    }

    func testCapturedSingleDeviceInfo() throws {
        let device = try XCTUnwrap(USBParser.listJSON(fixture("list-captured-redacted.json")).first)
        let info = try USBParser.info(fixture("info-captured-redacted.txt"), device: device)
        XCTAssertEqual(info.state, .available)
        XCTAssertEqual(info.speed, "USB 3.1 (10 Gbps)")
        XCTAssertEqual(info.serialNumber, "REDACTED-FIXTURE-1")
        XCTAssertNil(info.passthroughMachine)
    }

    func testCapturedAttachedAndDetached() throws {
        let devices = try USBParser.listJSON(fixture("list-attached-captured-redacted.json"))
        let earPods = try XCTUnwrap(devices.first { $0.id == "01100000" })
        XCTAssertEqual(earPods.state, .attached)
        let attached = try USBParser.info(fixture("info-attached-captured-redacted.txt"), device: earPods)
        XCTAssertEqual(attached.state, .attached)
        XCTAssertEqual(attached.passthroughMachine, "default")
        let detached = try USBParser.info(fixture("info-detached-captured-redacted.txt"), device: earPods)
        XCTAssertEqual(detached.state, .available)
        XCTAssertNil(detached.passthroughMachine)
        XCTAssertEqual(try USBParser.listTextStates(fixture("list-attached-captured.txt"))["01100000"], .attached)
    }

    func testNoDevices() throws {
        XCTAssertTrue(try USBParser.listJSON(fixture("list-empty-captured.json")).isEmpty)
        XCTAssertTrue(try USBParser.listTextStates(fixture("list-empty-captured.txt")).isEmpty)
        XCTAssertTrue(try USBParser.listJSON(#"{"devices":[],"ports":[]}"#).isEmpty)
        XCTAssertTrue(try USBParser.listTextStates("").isEmpty)
        XCTAssertTrue(try USBParser.listJSON(#"{"devices":null,"ports":null}"#).isEmpty)
    }

    func testFutureJSONFieldsIgnored() throws {
        let text = #"{"devices":[{"bus_id":"00000001","path":"Future","vendor_id":1,"product_id":2,"new_field":{"a":true}}],"ports":[{"future":true}],"future_version":100}"#
        let devices = try USBParser.listJSON(text)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].vidPID, "0001:0002")
    }

    func testInvalidAndDuplicateIdentifiersRejected() throws {
        for text in [
            #"{"devices":[{}]}"#,
            #"{"devices":[{"bus_id":""}]}"#,
            #"{"devices":[{"bus_id":"-f"}]}"#,
            #"{"devices":[{"bus_id":"1"},{"bus_id":"1"}]}"#,
            #"{"devices":[{"bus_id":"1","vendor_id":65536}]}"#,
            #"{"error":"unexpected"}"#, "not JSON"
        ] {
            XCTAssertThrowsError(try USBParser.listJSON(text))
        }
    }

    func testInfoUnknownFieldsAndColons() throws {
        let device = USBDevice(id: "1234", name: "Original")
        let text = "Details:\nID: 1234\nName: Device: With Colon\nNew field: Value\nPassthrough:\nMachine: Not attached\nInfo:\nSpeed: Future speed\nNew Section:\nID: Ignore me\n"
        let parsed = try USBParser.info(text, device: device)
        XCTAssertEqual(parsed.product, "Device: With Colon")
        XCTAssertEqual(parsed.speed, "Future speed")
        XCTAssertEqual(parsed.state, .available)
    }

    func testMismatchedInfoRejected() {
        XCTAssertThrowsError(try USBParser.info("Details:\nID: 9999", device: USBDevice(id: "1234", name: "A")))
    }

    func testSyntheticAttachedInfo() throws {
        let text = "Details:\nID: 1234\nPassthrough:\nMachine: default\n"
        let device = try USBParser.info(text, device: USBDevice(id: "1234", name: "A"))
        XCTAssertEqual(device.state, .attached)
        XCTAssertEqual(device.passthroughMachine, "default")
    }

    func testCapturedTextNotShared() throws {
        let states = try USBParser.listTextStates(fixture("list-captured.txt"))
        XCTAssertEqual(states["00200000"], .available)
        XCTAssertEqual(states["01100000"], .available)
    }

    func testSyntheticTextStatesAndFutureColumns() throws {
        let text = """
        ID        VID:PID    NAME           STATE       FUTURE
        --        -------    ----           -----       ------
        00000001  1234:0001  USB Storage    attached    ignored
        00000002  1234:0002  UART           forwarded   ignored
        00000003  1234:0003  Keyboard       Not shared  ignored
        00000004  1234:0004  Future         surprising  ignored
        """
        let states = try USBParser.listTextStates(text)
        XCTAssertEqual(states["00000001"], .attached)
        XCTAssertEqual(states["00000002"], .forwarded)
        XCTAssertEqual(states["00000003"], .available)
        XCTAssertEqual(states["00000004"], .unknown)
    }

    func testUnknownInfoStateRemainsUnknown() throws {
        let device = try USBParser.info("Details:\nID: 1\nPassthrough:\nState: newState\n",
                                        device: USBDevice(id: "1", name: "A"))
        XCTAssertEqual(device.state, .unknown)
    }

    func testReenumerationKeepsPreferenceButChangesConnection() {
        let first = USBDevice(id: "1", name: "Drive", vendorID: "1234", productID: "abcd", product: "Drive", serialNumber: "S", enumeration: 1)
        let next = USBDevice(id: "2", name: "Drive", vendorID: "1234", productID: "abcd", product: "Drive", serialNumber: "S", enumeration: 2)
        XCTAssertEqual(first.preferenceKey, next.preferenceKey)
        XCTAssertNotEqual(first.connectionKey, next.connectionKey)
        XCTAssertEqual(next.id, "2")
    }

    func testProcessCapturesAndPassesLiteralArguments() async throws {
        let result = try await OrbCLI().run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                           arguments: ["%s", "$(touch /tmp/orbusb-not-executed); `id`"])
        XCTAssertEqual(result.stdout, "$(touch /tmp/orbusb-not-executed); `id`")
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testCommandFailedExitStatus() async throws {
        let result = try await OrbCLI().run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        XCTAssertNotEqual(result.terminationStatus, 0)
        XCTAssertEqual(OrbStackError.commandFailure("Device is busy").errorDescription, "Device is busy")
        XCTAssertEqual(OrbStackError.commandFailure("OrbStack is not running"), .orbStackNotRunning)
        XCTAssertEqual(OrbStackError.commandFailure(#"Error: USB device "ffffffff" not found"#), .deviceNotFound)
    }

    func testMissingExecutable() async {
        do {
            _ = try await OrbCLI().run(executable: URL(fileURLWithPath: "/nonexistent/OrbUSB/orb"), arguments: [])
            XCTFail("Missing executable should fail")
        } catch { }
    }

    func testPreferencesPersistAcrossReenumeration() {
        let suite = "OrbUSBTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.refreshInterval, 2)
        XCTAssertTrue(preferences.showForwarded)
        XCTAssertFalse(preferences.showSerialNumbers)
        let first = USBDevice(id: "1", name: "Drive", serialNumber: "fixture")
        let next = USBDevice(id: "2", name: "Drive", serialNumber: "fixture")
        preferences.toggleFavorite(first)
        XCTAssertTrue(Preferences(defaults: defaults).isFavorite(next))
        preferences.toggleFavorite(next)
        XCTAssertFalse(preferences.isFavorite(first))
    }

    func testServiceMissingExecutable() async {
        do {
            _ = try await OrbStackUSBService(executable: URL(fileURLWithPath: "/nonexistent/OrbUSB/orb")).refresh()
            XCTFail("Expected discovery failure")
        } catch {
            XCTAssertEqual(error as? OrbStackError, .executableNotFound)
        }
    }

    func testServiceCommandFailure() async {
        do {
            _ = try await OrbStackUSBService(executable: URL(fileURLWithPath: "/usr/bin/false")).refresh()
            XCTFail("Expected command failure")
        } catch {
            guard case .commandFailed = error as? OrbStackError else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testLargeStdoutAndStderrDoNotDeadlock() async throws {
        let result = try await OrbCLI().run(executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: [#"BEGIN {for(i=0;i<100000;i++){print "output";print "errors" > "/dev/stderr"}}"#], timeout: 5)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout.utf8.count, 700000)
        XCTAssertEqual(result.stderr.utf8.count, 700000)
    }

    func testCancellationAfterLaunch() async throws {
        let task = Task { try await OrbCLI().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    #if !SWIFT_PACKAGE
    private func fixtureService(script: String) throws -> (OrbStackUSBService, URL) {
        let directory = URL(fileURLWithPath: "/tmp/OrbUSBTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("orb-fixture")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (OrbStackUSBService(executable: executable), directory)
    }

    private func waitForRefresh(_ state: AppState) async throws {
        let deadline = Date().addingTimeInterval(4)
        while state.isRefreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isRefreshing)
    }

    func testAppStateOrbStackNotRunning() async throws {
        let (service, directory) = try fixtureService(script: "echo 'OrbStack is not running' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(service: service, startMonitoring: false)
        state.requestRefresh()
        try await waitForRefresh(state)
        XCTAssertEqual(state.error, "OrbStack is not running")
        XCTAssertTrue(state.devices.isEmpty)
        state.shutdown()
    }

    func testAppStateRefreshCoalescingAndClosedMenu() async throws {
        let script = """
        if [ "$1" = version ]; then echo 'Version: fixture'; exit 0; fi
        echo list >> "$(dirname "$0")/calls"
        sleep 0.1
        if [ "$4" = json ]; then printf '{"devices":[],"ports":[]}'; fi
        """
        let (service, directory) = try fixtureService(script: script)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "OrbUSBTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.refreshInterval = 1
        let state = AppState(service: service, preferences: preferences, startMonitoring: false)
        state.openMenu()
        for _ in 0..<20 { state.requestRefresh() }
        try await waitForRefresh(state)
        let calls = directory.appendingPathComponent("calls")
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 2)
        state.requestRefresh()
        state.requestRefresh(force: true)
        try await waitForRefresh(state)
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 6)
        state.closeMenu()
        let before = state.lastRefreshDate
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(state.lastRefreshDate, before)
        state.shutdown()
    }
    #endif

    func testTimeoutAndCancellation() async throws {
        let start = Date()
        do {
            _ = try await OrbCLI().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch let error as OrbStackError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let task = Task { try await OrbCLI().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
