import Foundation
import OSLog

enum USBRecoveryEvent: Sendable { case changed, deadline }

struct USBRecoveryObservation: Sendable {
    let events: AsyncStream<USBRecoveryEvent>
    let stop: @Sendable () async -> Void

    @MainActor static func start(timeout: Duration) throws -> USBRecoveryObservation {
        let watcher = USBRecoveryWatcher()
        return try watcher.start(timeout: timeout)
    }
}

@MainActor private final class USBRecoveryWatcher {
    private let monitor = USBMonitor()
    private var timer: Task<Void, Never>?
    private var continuation: AsyncStream<USBRecoveryEvent>.Continuation?

    func start(timeout: Duration) throws -> USBRecoveryObservation {
        let (events, continuation) = AsyncStream<USBRecoveryEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        guard monitor.start(onChange: { continuation.yield(.changed) }) else {
            stop()
            throw USBHostRecoveryError.observationUnavailable
        }
        continuation.yield(.changed)
        let deadline = ContinuousClock.now + timeout
        timer = Task {
            while ContinuousClock.now < deadline {
                do { try await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: deadline))) }
                catch { return }
                // Supplement notifications for properties published after first-match (BSD Name).
                // A tick never means ready: every tick must converge on a fresh topology.
                continuation.yield(ContinuousClock.now < deadline ? .changed : .deadline)
            }
            continuation.finish()
        }
        return USBRecoveryObservation(events: events, stop: { await self.stop() })
    }

    func stop() {
        timer?.cancel()
        timer = nil
        monitor.stop()
        continuation?.finish()
        continuation = nil
    }
}

protocol USBHostRecoveryBackend: Sendable {
    func snapshots() async throws -> [USBHostSnapshot]
    func observe(timeout: Duration) async throws -> USBRecoveryObservation
    // false means a final TOCTOU check found the host already healthy; no reset occurred.
    func reset(_ device: USBDevice, anchor: USBHostIdentity, function: USBHostFunction, operationID: UUID) async throws -> Bool
}

actor USBHostRecoveryService {
    private let backend: any USBHostRecoveryBackend
    private let timeout: Duration
    private let returnGrace: TimeInterval
    private var missingSince: [USBHostIdentity: Date] = [:]
    private var failures: [USBHostIdentity: String] = [:]
    private var active: USBHostIdentity?
    private var lastVerifiedIdentity: USBHostIdentity?
    private var observationRevision: UInt64 = 0

    init(backend: any USBHostRecoveryBackend = SystemUSBHostRecoveryBackend(),
         timeout: Duration = .seconds(12), returnGrace: TimeInterval = 8) {
        self.backend = backend
        self.timeout = timeout
        self.returnGrace = returnGrace
    }

    func decorate(_ devices: [USBDevice], now: Date = Date()) async -> [USBDevice] {
        let devices = devices.map { device in
            var current = device
            current.hostIdentity = nil
            current.hostBindingState = .unknown
            current.recoveryEligibility = nil
            current.recoveryError = nil
            return current
        }
        let revision = observationRevision
        let hosts: [USBHostSnapshot]
        do { hosts = try await backend.snapshots() }
        catch { return devices } // Unverified state never exposes recovery.
        guard revision == observationRevision else { return devices }
        let currentIdentities = Set(hosts.map(\.identity))
        missingSince = missingSince.filter { currentIdentities.contains($0.key) }
        failures = failures.filter { currentIdentities.contains($0.key) }
        return devices.map { device in
            var value = device
            guard let host = try? USBRecoveryPolicy.resolve(device, in: hosts) else { return value }
            value.hostIdentity = host.identity
            guard let function = host.function(for: device), !host.isHub, !host.isController else { return value }
            if active?.sameConnection(as: host.identity, requireGeneration: false) == true {
                value.hostBindingState = .recovering
                return value
            }
            guard device.state == .available else {
                missingSince[host.identity] = nil
                failures[host.identity] = nil
                return value
            }
            if host.ready(for: function) {
                missingSince[host.identity] = nil
                failures[host.identity] = nil
                value.hostBindingState = .available
                value.recoveryEligibility = .alreadyRecovered
                return value
            }
            let start = missingSince[host.identity] ?? now
            missingSince[host.identity] = start
            value.hostBindingState = now.timeIntervalSince(start) >= returnGrace ? .driverUnavailable : .returning
            do { value.recoveryEligibility = try USBRecoveryPolicy.validate(host, device: device, allHosts: hosts, function: function) }
            catch { value.recoveryEligibility = .ineligible((error as? USBHostRecoveryError) ?? .safetyUnresolved) }
            if let failure = failures[host.identity] {
                value.hostBindingState = .failed
                value.recoveryError = failure
            }
            return value
        }
    }

    func canRecover(_ device: USBDevice) async -> RecoveryEligibility {
        guard active == nil else { return .ineligible(.operationInProgress) }
        guard device.hostBindingState == .driverUnavailable, let anchor = device.hostIdentity else { return .ineligible(.notEligible) }
        do {
            let hosts = try await backend.snapshots()
            let host = try USBRecoveryPolicy.resolve(device, in: hosts, anchor: anchor)
            guard let function = host.function(for: device) else { throw USBHostRecoveryError.unsupportedDevice }
            return try USBRecoveryPolicy.validate(host, device: device, allHosts: hosts, function: function)
        } catch { return .ineligible((error as? USBHostRecoveryError) ?? .safetyUnresolved) }
    }

    // Only OrbStackUSBService calls this while holding the shared mutation transaction.
    func recover(_ displayed: USBDevice,
                 orbSnapshot: @Sendable () async throws -> [USBDevice]) async throws -> RecoveryResult {
        guard active == nil else { throw USBHostRecoveryError.operationInProgress }
        guard displayed.hostBindingState == .driverUnavailable, let anchor = displayed.hostIdentity else {
            throw USBHostRecoveryError.notEligible
        }
        active = anchor
        observationRevision &+= 1
        lastVerifiedIdentity = anchor
        let operationID = UUID()
        defer { active = nil; lastVerifiedIdentity = nil; observationRevision &+= 1 }
        RecoveryLog.event(operationID, "begin identity=\(anchor) OrbStack=\(displayed.state)")
        do {
            let result = try await perform(displayed, anchor: anchor, operationID: operationID, orbSnapshot: orbSnapshot)
            missingSince[anchor] = nil
            failures[anchor] = nil
            RecoveryLog.event(operationID, "result=\(result)")
            return result
        } catch {
            failures[lastVerifiedIdentity ?? anchor] = error.localizedDescription
            RecoveryLog.event(operationID, "failed: \(error)")
            throw error
        }
    }

    private func perform(_ displayed: USBDevice, anchor: USBHostIdentity, operationID: UUID,
                         orbSnapshot: @Sendable () async throws -> [USBDevice]) async throws -> RecoveryResult {
        // Subscription is established and armed before ANY validation snapshot or reset.
        let observation = try await backend.observe(timeout: timeout)
        do {
            let result = try await runObserved(displayed, anchor: anchor, operationID: operationID,
                                               orbSnapshot: orbSnapshot, observation: observation)
            await observation.stop()
            return result
        } catch {
            await observation.stop()
            throw error
        }
    }

    private func runObserved(_ displayed: USBDevice, anchor: USBHostIdentity, operationID: UUID,
                             orbSnapshot: @Sendable () async throws -> [USBDevice],
                             observation: USBRecoveryObservation) async throws -> RecoveryResult {
        let deadline = ContinuousClock.now + timeout
        let freshOrb = try await orbSnapshot()
        let current = try validateOrb(displayed, in: freshOrb)
        RecoveryLog.event(operationID, "fresh OrbStack=\(current.state) bus=\(current.id) enumeration=\(current.enumeration ?? -1)")
        let hosts = try await backend.snapshots()
        let before = try USBRecoveryPolicy.resolve(current, in: hosts, anchor: anchor)
        guard let function = before.function(for: current) else { throw USBHostRecoveryError.unsupportedDevice }
        RecoveryLog.event(operationID, "preflight=\(before)")
        if try USBRecoveryPolicy.validate(before, device: current, allHosts: hosts, function: function) == .alreadyRecovered {
            return result(operationID, .alreadyRecovered, before, before, Date())
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw USBHostRecoveryError.reenumerationTimedOut }
        let didReset = try await backend.reset(current, anchor: anchor, function: function, operationID: operationID)
        var usbObservedAt: Date?
        var observedGeneration: UInt64?
        var absent = false
        // Take an immediate snapshot as well: reenumeration may have completed inside reset().
        var events = observation.events.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw absent ? USBHostRecoveryError.deviceDisappeared : USBHostRecoveryError.functionalDriverTimedOut
            }
            let snapshots = try await backend.snapshots()
            do {
                let host = try USBRecoveryPolicy.resolve(current, in: snapshots, anchor: anchor, afterReset: didReset)
                guard snapshots.filter({ $0.identity.vendorID == anchor.vendorID && $0.identity.productID == anchor.productID
                    && $0.identity.serialNumber == anchor.serialNumber }).count == 1 else { throw USBHostRecoveryError.ambiguousIdentity }
                if let observedGeneration, observedGeneration != host.identity.registryEntryID { throw USBHostRecoveryError.identityChanged }
                lastVerifiedIdentity = host.identity
                // A changed generation is evidence, not a prerequisite: a rematch can keep the ID.
                if host.identity.registryEntryID != anchor.registryEntryID || host.ready(for: function) {
                    observedGeneration = host.identity.registryEntryID
                    if usbObservedAt == nil {
                        usbObservedAt = Date()
                        RecoveryLog.event(operationID, "USB observed at \(usbObservedAt!) new registry=\(host.identity.registryEntryID)")
                    }
                }
                absent = false
                if host.ready(for: function) {
                    _ = try validateOrb(current, in: await orbSnapshot(), afterReset: didReset)
                    // CLI verification awaits; validate the functional stack AGAIN afterwards.
                    let finalHosts = try await backend.snapshots()
                    let final = try USBRecoveryPolicy.resolve(current, in: finalHosts, anchor: host.identity)
                    guard final.ready(for: function) else { continue }
                    guard ContinuousClock.now < deadline else { throw USBHostRecoveryError.functionalDriverTimedOut }
                    try Task.checkCancellation()
                    RecoveryLog.event(operationID, "functional driver observed at \(Date()) final=\(final)")
                    return result(operationID, didReset ? .recovered : .alreadyRecovered, before, final, usbObservedAt ?? Date())
                }
            } catch USBHostRecoveryError.deviceNotFound {
                if observedGeneration != nil { throw USBHostRecoveryError.deviceDisappeared }
                absent = true
            }
            guard ContinuousClock.now < deadline, let event = await events.next(), event != .deadline else {
                if absent { throw USBHostRecoveryError.deviceDisappeared }
                throw usbObservedAt == nil ? USBHostRecoveryError.reenumerationTimedOut : USBHostRecoveryError.functionalDriverTimedOut
            }
        }
    }

    private func validateOrb(_ expected: USBDevice, in devices: [USBDevice], afterReset: Bool = false) throws -> USBDevice {
        let matches = devices.filter { $0.id == expected.id }
        guard matches.count == 1, let current = matches.first else { throw USBHostRecoveryError.identityChanged }
        guard current.vendorID == expected.vendorID, current.productID == expected.productID,
              current.serialNumber == expected.serialNumber,
              afterReset || current.enumeration == expected.enumeration else { throw USBHostRecoveryError.identityChanged }
        guard current.state == .available, current.detailError == nil else { throw USBHostRecoveryError.stillAttachedToOrbStack }
        return current
    }

    private func result(_ id: UUID, _ outcome: RecoveryResult.Outcome, _ before: USBHostSnapshot,
                        _ after: USBHostSnapshot, _ usbAt: Date) -> RecoveryResult {
        RecoveryResult(operationID: id, outcome: outcome, before: before, after: after,
                       usbObservedAt: usbAt, functionalDriverObservedAt: Date())
    }
}

enum RecoveryLog {
    static func event(_ operationID: UUID, _ message: @autoclosure () -> String) {
        #if DEBUG
        let detail = message()
        Log.usb.debug("[Recover \(operationID.uuidString, privacy: .public)] \(detail, privacy: .private)")
        #endif
    }
}
