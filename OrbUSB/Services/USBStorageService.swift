import Foundation
import IOKit
import DiskArbitration
import OSLog
import Darwin

enum USBStorageError: Error, LocalizedError, Sendable, Equatable {
    case operationInProgress
    case storageNotReady
    case diskStillMounted
    case diskNotFound
    case ambiguousDevice
    case identityChanged
    case stateChanged
    case unmountFailed(String)
    case ejectBusy
    case ejectPermission
    case ejectFailed(Int32)
    case ejectTimedOut
    case storageReleaseTimedOut
    case storageReappeared
    case quietCheckFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .operationInProgress: "A USB operation is already in progress."
        case .storageNotReady: "macOS is still preparing this disk. Wait and try again."
        case .diskStillMounted: "Unable to prepare disk for OrbStack. Close files using the disk and try again."
        case .diskNotFound: "Unable to find this USB device's disk. Refresh and try again."
        case .ambiguousDevice: "Unable to identify this USB disk uniquely."
        case .identityChanged: "The USB device changed or disconnected. Refresh and try again."
        case .stateChanged: "Device is no longer available. Review its current state and try again."
        case .unmountFailed: "Unable to unmount volumes. Close files using the disk and try again."
        case .ejectBusy: "Disk is busy. Close files using the disk and try again. The device was not attached."
        case .ejectPermission: "macOS denied permission to eject the disk. The device was not attached."
        case .ejectFailed(let status): "Disk eject failed (\(status)). The device was not attached."
        case .ejectTimedOut: "Disk eject timed out. The device was not attached; retry is blocked until macOS completes the request."
        case .storageReleaseTimedOut: "USB storage stack did not quiesce before timeout. The device was not attached to avoid a macOS kernel panic."
        case .storageReappeared: "USB storage remounted or changed during handoff. The device was not attached."
        case .quietCheckFailed(let status): "Unable to verify IOKit quiet state (\(status)). The device was not attached."
        }
    }
}

struct USBStorageDisk: Equatable, Sendable {
    let bsdName: String
    let registryID: UInt64
}

struct USBStorageHost: Sendable {
    let vendorID: String?
    let productID: String?
    let serialNumber: String?
    let locationID: UInt32?
    let disks: [USBStorageDisk]
}

protocol USBStoragePreparing: Sendable {
    // Pins physical identity for ALL devices; returns whether storage preparation is required.
    func begin(for device: USBDevice) async throws -> Bool
    func end(for device: USBDevice) async
    func resolveDisks(for device: USBDevice) async throws -> [USBStorageDisk]
    func waitForMount(on disks: [USBStorageDisk]) async throws
    func unmountVolumes(on disks: [USBStorageDisk]) async throws
    func verifyUnmount(on disks: [USBStorageDisk]) async throws
    func finalCheck(for device: USBDevice, on disks: [USBStorageDisk]) async throws
    func ejectDisks(for device: USBDevice, on disks: [USBStorageDisk]) async throws
    func waitForStorageRelease(for device: USBDevice) async throws
    func launchValidation(for device: USBDevice) -> @Sendable () throws -> Void
    func ensureNoPendingOperations(for id: String?) async throws
}

struct USBStorageService: USBStoragePreparing {
    private let arbitration = StorageArbitration.shared

    func begin(for device: USBDevice) async throws -> Bool {
        try await arbitration.access { try $0.begin(device) }
    }

    func end(for device: USBDevice) async {
        _ = try? await arbitration.access { $0.end(device) }
    }

    func ensureNoPendingOperations(for id: String?) async throws {
        try await arbitration.access { bridge in
            guard id.map({ id in !bridge.pending.keys.contains {
                $0 == id || (UInt32($0, radix: 16) != nil && UInt32($0, radix: 16) == UInt32(id, radix: 16))
            } }) ?? bridge.pending.isEmpty else {
                throw USBStorageError.operationInProgress
            }
        }
    }

    func resolveDisks(for device: USBDevice) async throws -> [USBStorageDisk] {
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
            try Task.checkCancellation()
            if let disks = try await arbitration.access({ bridge -> [USBStorageDisk]? in
                try bridge.validateHost(device)
                do { return try Self.disks(for: device, hosts: Self.hosts()) }
                catch USBStorageError.diskNotFound { return nil }
            }) {
                for disk in disks { Log.usb.debug("[USB Attach] physical disk discovered \(disk.bsdName, privacy: .public)") }
                return disks
            }
            guard ContinuousClock.now < deadline else { throw USBStorageError.diskNotFound }
            try await Task.sleep(for: .milliseconds(50)) // bounded condition polling, never a readiness proof
        }
    }

    func waitForMount(on disks: [USBStorageDisk]) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        var media: [USBStorageDisk] = []
        while media.isEmpty {
            try Task.checkCancellation()
            media = try await arbitration.access { bridge in
                guard try bridge.ready(disks, unmounted: false, requireLifecycle: false) else { return [] }
                return bridge.lastMedia
            }
            if media.isEmpty {
                guard ContinuousClock.now < deadline else { throw USBStorageError.storageNotReady }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        for disk in media {
            try Task.checkCancellation()
            try await arbitration.mountBarrier(disk, deadline: deadline)
        }
        try await wait(disks, unmounted: false)
    }

    func verifyUnmount(on disks: [USBStorageDisk]) async throws {
        try await wait(disks, unmounted: true)
        try await arbitration.access { bridge in
            guard try bridge.ready(disks, unmounted: true) else { throw USBStorageError.diskStillMounted }
        }
    }

    func finalCheck(for device: USBDevice, on disks: [USBStorageDisk]) async throws {
        try await arbitration.access { try $0.checkForLaunch(device) }
    }

    func launchValidation(for device: USBDevice) -> @Sendable () throws -> Void {
        // Runs on the process queue immediately before Process.run(), after all
        // actor hops. No DA object escapes its own serial queue.
        { try arbitration.validateForLaunch(device) }
    }

    func ejectDisks(for device: USBDevice, on disks: [USBStorageDisk]) async throws {
        try Task.checkCancellation()
        try await arbitration.access { try $0.recordEjectPlan(device, disks: disks) }
        for disk in disks {
            try Task.checkCancellation()
            try await arbitration.eject(disk, device: device)
        }
        try Task.checkCancellation()
        try await arbitration.access { $0.preparedDevices.insert(device.id) }
    }

    func waitForStorageRelease(for device: USBDevice) async throws {
        let start = ContinuousClock.now
        let deadline = start + .seconds(5)
        var gate = USBStorageReleaseGate(deadline: deadline)
        var lastReason = ""
        Log.usb.info("[USBTransfer] waiting for storage quiescence id=\(device.id, privacy: .public)")
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw USBStorageError.storageReleaseTimedOut }
            let (snapshot, revision) = try await arbitration.access { bridge in
                (try bridge.validatedQuiescenceSnapshot(device), bridge.revisions[device.id, default: 0])
            }
            let now = ContinuousClock.now
            guard now < deadline else { throw USBStorageError.storageReleaseTimedOut }
            let reason = snapshot.quiescenceDiagnostic
            if reason != lastReason {
                Self.logQuiescence(snapshot)
                lastReason = reason
            }
            if gate.quietSince == nil && snapshot.storageQuiescent {
                Log.usb.info("[USBTransfer] first quiet state observed after \(String(describing: start.duration(to: now)), privacy: .public); checking 250ms stability")
            }
            if try gate.observe(released: snapshot.storageQuiescent, revision: revision, now: now,
                                    topology: Set(snapshot.ioServiceNodes.values.map(\.identity))) {
                try await arbitration.access { bridge in
                    let final = try bridge.validatedQuiescenceSnapshot(device)
                    guard ContinuousClock.now < deadline else { throw USBStorageError.storageReleaseTimedOut }
                    guard bridge.revisions[device.id, default: 0] == revision, final.storageQuiescent,
                          final.ioServiceNodes.mapValues(\.identity) == snapshot.ioServiceNodes.mapValues(\.identity) else {
                        throw USBStorageError.storageReappeared
                    }
                    bridge.releasedRevisions[device.id] = revision
                    bridge.verifiedNodes[device.id] = Set(final.ioServiceNodes.values.map(\.identity))
                }
                Log.usb.info("[USBTransfer] quiescence and stable window verified after \(String(describing: start.duration(to: .now)), privacy: .public)")
                return
            }
            try await Task.sleep(for: min(.milliseconds(75), now.duration(to: deadline)))
        }
    }

    fileprivate static func logQuiescence(_ host: USBHostSnapshot) {
        Log.usb.info("[USBStorage] mounted=\(host.mountedVolumes.count) DA-mounted=\(host.daMountedMedia.count) mountAudit=\(host.storageAuditComplete) DAAudit=\(host.diskArbitrationAuditComplete) quiet=\(host.storageQuiescent)")
        // One record per node: a single concatenated tree can exceed OSLog's
        // message limit and silently omit the exact node that blocks handoff.
        for node in host.ioServiceNodes.values.sorted(by: { $0.identity.registryID < $1.identity.registryID }) {
            let detail = host.diagnostic(for: node)
            Log.usb.info("[USBStorage] \(detail, privacy: .public)")
        }
    }

    private func wait(_ disks: [USBStorageDisk], unmounted: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
            try Task.checkCancellation()
            if try await arbitration.access({ try $0.ready(disks, unmounted: unmounted) }) { return }
            guard ContinuousClock.now < deadline else {
                throw unmounted ? USBStorageError.diskStillMounted : USBStorageError.storageNotReady
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func disks(for device: USBDevice, hosts: [USBStorageHost]) throws -> [USBStorageDisk] {
        guard let vendorID = device.vendorID, let productID = device.productID else {
            throw USBStorageError.diskNotFound
        }
        let candidates = hosts.filter { host in
            guard host.vendorID == vendorID, host.productID == productID else { return false }
            if let serial = device.serialNumber, !serial.isEmpty, host.serialNumber != serial { return false }
            // OrbStack's macOS bus ID is the hexadecimal USB location ID.
            guard let location = UInt32(device.id, radix: 16) else { return false }
            return host.locationID == location
        }
        guard !candidates.isEmpty else { throw USBStorageError.diskNotFound }
        guard candidates.count == 1 else { throw USBStorageError.ambiguousDevice }
        let disks = candidates[0].disks
        return disks.sorted { $0.bsdName < $1.bsdName }
    }

    func unmountVolumes(on disks: [USBStorageDisk]) async throws {
        let targets = try await arbitration.access { try $0.unmountTargets(disks) }
        for disk in targets {
            try Task.checkCancellation()
            try await arbitration.unmount(disk)
        }
    }

    fileprivate static func validate(_ disk: USBStorageDisk) throws {
        guard disk.bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw USBStorageError.diskNotFound
        }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(disk.registryID))
        guard media != 0 else { throw USBStorageError.identityChanged }
        defer { IOObjectRelease(media) }
        guard IOObjectConformsTo(media, "IOMedia") != 0,
              property(media, "Whole") as? Bool == true,
              property(media, "BSD Name") as? String == disk.bsdName else {
            throw USBStorageError.identityChanged
        }
    }

    fileprivate static func hosts() throws -> [USBStorageHost] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            throw USBStorageError.diskNotFound
        }
        defer { IOObjectRelease(iterator) }
        var hosts: [USBStorageHost] = []
        while true {
            let host = IOIteratorNext(iterator)
            guard host != 0 else { break }
            defer { IOObjectRelease(host) }
            func hex(_ key: String) -> String? {
                (property(host, key) as? NSNumber).map { String(format: "%04x", $0.uint16Value) }
            }
            hosts.append(USBStorageHost(vendorID: hex("idVendor"), productID: hex("idProduct"),
                serialNumber: property(host, "USB Serial Number") as? String,
                locationID: (property(host, "locationID") as? NSNumber)?.uint32Value,
                disks: try wholeDisks(below: host)))
        }
        guard IOIteratorIsValid(iterator) != 0 else { throw USBStorageError.identityChanged }
        return hosts
    }

    fileprivate static func wholeDisks(below entry: io_registry_entry_t) throws -> [USBStorageDisk] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            throw USBStorageError.diskNotFound
        }
        defer { IOObjectRelease(iterator) }
        var disks: [USBStorageDisk] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }
            // Do not traverse a hub into a different USB device, or traverse a
            // physical whole disk into synthesized APFS/container media.
            if IOObjectConformsTo(child, "IOUSBHostDevice") != 0 { continue }
            if IOObjectConformsTo(child, "IOMedia") != 0, property(child, "Whole") as? Bool == true {
                guard let name = property(child, "BSD Name") as? String else { throw USBStorageError.diskNotFound }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(child, &id) == KERN_SUCCESS else { throw USBStorageError.diskNotFound }
                disks.append(USBStorageDisk(bsdName: name, registryID: id))
            } else {
                disks += try wholeDisks(below: child)
            }
        }
        guard IOIteratorIsValid(iterator) != 0 else { throw USBStorageError.identityChanged }
        return disks
    }

    fileprivate static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

// Disk Arbitration's synchronous approval callbacks cannot await an actor.
// This process-lifetime bridge confines ALL DA objects and mutable state to queue.
// The service actor owns transaction exclusion; only Sendable values cross here.
private final class StorageArbitration: @unchecked Sendable {
    static let shared = StorageArbitration()
    private let queue = DispatchQueue(label: "dev.orbusb.disk-arbitration")
    private var session: DASession?
    private var notificationPort: IONotificationPortRef?
    private var notificationIterators: [io_iterator_t] = []
    private var serviceAncestors: [UInt64: Set<UInt64>] = [:]
    private var busyObservers: [String: io_object_t] = [:]
    fileprivate var pending: [String: UInt64] = [:]
    private var lifecycle = USBMountLifecycle()
    fileprivate var revisions: [String: UInt64] = [:]
    fileprivate var releasedRevisions: [String: UInt64] = [:]
    private var anchors: [String: USBHostIdentity] = [:]
    private var ejectPlans: [String: USBStorageHandoffEvidence] = [:]
    fileprivate var preparedDevices: Set<String> = []
    fileprivate var verifiedNodes: [String: Set<USBStorageNodeIdentity>] = [:]
    private var invalidatedPreparations: Set<String> = []
    private var storageRequired: Set<String> = []
    private var requestMedia: [String: Set<UInt64>] = [:]
    private var ended: Set<String> = []
    fileprivate var lastMedia: [USBStorageDisk] = []
    private var claimRequests = USBUnmountRequests()
    private var claimDisks: [Int: USBStorageDisk] = [:]
    private var knownAncestors: [String: Set<UInt64>] = [:]
    private var requests = USBUnmountRequests()
    private var lastWaitReason = ""

    private func waiting(_ reason: String) -> Bool {
        if reason != lastWaitReason {
            lastWaitReason = reason
            Log.usb.info("[USB Attach] waiting: \(reason, privacy: .public)")
        }
        return false
    }

    private init() {
        queue.async { [self] in
            guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
            self.session = session
            let context = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskPeekCallback(session, nil, 0, { disk, context in
                let bridge = StorageArbitration.bridge(context)
                if let name = bridge.name(disk) { bridge.lifecycle.probing(name) }
                bridge.changed(disk, kind: "probing")
            }, context)
            DARegisterDiskAppearedCallback(session, nil, { disk, context in
                let bridge = StorageArbitration.bridge(context)
                if let name = bridge.name(disk), let id = bridge.mediaID(disk) {
                    bridge.lifecycle.appeared(name, registryID: id)
                }
                bridge.changed(disk, kind: "volume appeared")
            }, context)
            DARegisterDiskDisappearedCallback(session, nil, { disk, context in
                let bridge = StorageArbitration.bridge(context)
                if let name = bridge.name(disk) {
                    bridge.lifecycle.disappeared(name)
                }
                bridge.changed(disk, kind: "volume disappeared")
                if let name = bridge.name(disk) { bridge.knownAncestors[name] = nil }
            }, context)
            // Observe all description keys: topology and protocol changes matter too.
            DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
                let bridge = StorageArbitration.bridge(context)
                if bridge.isMounted(disk), let name = bridge.name(disk) { bridge.lifecycle.mounted(name) }
                bridge.changed(disk, kind: "mount state changed")
            }, context)
            DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
                let bridge = StorageArbitration.bridge(context)
                if bridge.belongsToPending(disk) {
                    bridge.changed(disk, kind: "mount prevented")
                    return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), nil))
                }
                if let name = bridge.name(disk) { bridge.lifecycle.mountApproved(name) }
                return nil
            }, context)
            DASessionSetDispatchQueue(session, queue)
            // Observe transient storage publication/termination between polls.
            // If observation cannot be armed, no transfer can start.
            if !startRegistryObservation() { self.session = nil }
        }
    }

    private func startRegistryObservation() -> Bool {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(port, notification, IOServiceMatching("IOService"),
                { context, iterator in
                    guard let context else { return }
                    StorageArbitration.bridge(context).registryChanged(iterator)
                }, context, &iterator)
            guard status == KERN_SUCCESS else {
                if iterator != 0 { IOObjectRelease(iterator) }
                notificationIterators.forEach { IOObjectRelease($0) }
                notificationIterators.removeAll()
                IONotificationPortDestroy(port); notificationPort = nil
                return false
            }
            notificationIterators.append(iterator)
            registryChanged(iterator) // drain and arm before any transaction
        }
        return true
    }

    private func registryChanged(_ iterator: io_iterator_t) {
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            do {
                guard try USBHostTopology.isStorageService(entry) else { continue }
                let id = try USBHostTopology.registryID(entry)
                var ids: Set<UInt64> = []
                let complete = ancestors(entry, visited: &ids)
                // A terminated service can already have lost its parent edge.
                ids.formUnion(serviceAncestors[id, default: []])
                if notificationIterators.last == iterator && notificationIterators.count == 2 {
                    serviceAncestors[id] = nil
                } else {
                    serviceAncestors[id] = ids
                }
                for (key, host) in pending where ids.contains(host) || !complete {
                    revisions[key, default: 0] &+= 1
                    if let plan = ejectPlans[key], !plan.nodeIDs.contains(id) { invalidatedPreparations.insert(key) }
                }
            } catch {
                for key in pending.keys { revisions[key, default: 0] &+= 1 }
            }
        }
        if IOIteratorIsValid(iterator) == 0 {
            for key in pending.keys { revisions[key, default: 0] &+= 1 }
        }
    }

    private static func bridge(_ context: UnsafeMutableRawPointer?) -> StorageArbitration {
        Unmanaged<StorageArbitration>.fromOpaque(context!).takeUnretainedValue()
    }

    func access<T: Sendable>(_ body: @escaping @Sendable (StorageArbitration) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in continuation.resume(with: Result { try body(self) }) }
        }
    }

    private func name(_ disk: DADisk) -> String? { DADiskGetBSDName(disk).map(String.init(cString:)) }
    private func mediaID(_ disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
    }
    private func isMounted(_ disk: DADisk) -> Bool {
        (DADiskCopyDescription(disk) as? [String: Any])?[kDADiskDescriptionVolumePathKey as String] != nil
    }

    // Walk every IOService parent, including APFS synthesized media and physical
    // stores. Never infer physical ancestry by trimming BSD partition suffixes.
    @discardableResult
    private func ancestors(_ entry: io_registry_entry_t, visited: inout Set<UInt64>) -> Bool {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return false }
        guard visited.insert(id).inserted else { return true }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while true {
            let parent = IOIteratorNext(iterator)
            guard parent != 0 else { break }
            let complete = ancestors(parent, visited: &visited)
            IOObjectRelease(parent)
            if !complete { return false }
        }
        return IOIteratorIsValid(iterator) != 0
    }
    private func belongsToPending(_ disk: DADisk) -> Bool {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return false }
        defer { IOObjectRelease(media) }
        var ids: Set<UInt64> = []
        ancestors(media, visited: &ids)
        return pending.values.contains { ids.contains($0) }
    }
    private func changed(_ disk: DADisk, kind: String) {
        Log.usb.info("[USB Lifecycle] \(kind, privacy: .public) \(self.name(disk) ?? "unknown", privacy: .public)")
        var ids: Set<UInt64> = []
        let media = DADiskCopyIOMedia(disk)
        if media != 0 {
            ancestors(media, visited: &ids)
            IOObjectRelease(media)
        }
        if let name = name(disk) {
            // Disappearance can arrive after IOMedia was terminated. Remember
            // its previous ancestry so teardown still invalidates verification.
            ids.formUnion(knownAncestors[name] ?? [])
            knownAncestors[name] = ids
        }
        if !ids.isDisjoint(with: Set(pending.values)) {
            for (key, host) in pending where ids.contains(host) {
                revisions[key, default: 0] &+= 1
                if ejectPlans[key] != nil, isMounted(disk) { invalidatedPreparations.insert(key) }
            }
            Log.usb.debug("[USB Attach] \(kind, privacy: .public) \(self.name(disk) ?? "unknown", privacy: .public)")
        }
    }

    fileprivate func begin(_ device: USBDevice) throws -> Bool {
        guard let session else { throw USBStorageError.storageNotReady }
        guard pending[device.id] == nil else { throw USBStorageError.operationInProgress }
        guard let location = UInt32(device.id, radix: 16),
              let vendor = device.vendorID, let product = device.productID else { throw USBStorageError.ambiguousDevice }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            throw USBStorageError.diskNotFound
        }
        defer { IOObjectRelease(iterator) }
        var matches: [UInt64] = []
        while true {
            let host = IOIteratorNext(iterator)
            guard host != 0 else { break }
            defer { IOObjectRelease(host) }
            let property = USBStorageService.property
            guard (property(host, "locationID") as? NSNumber)?.uint32Value == location,
                  (property(host, "idVendor") as? NSNumber)?.uint16Value == UInt16(vendor, radix: 16),
                  (property(host, "idProduct") as? NSNumber)?.uint16Value == UInt16(product, radix: 16) else { continue }
            if let serial = device.serialNumber, !serial.isEmpty,
               property(host, "USB Serial Number") as? String != serial { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(host, &id) == KERN_SUCCESS else { continue }
            matches.append(id)
        }
        guard IOIteratorIsValid(iterator) != 0, matches.count == 1 else { throw USBStorageError.identityChanged }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(matches[0]))
        guard entry != 0 else { throw USBStorageError.identityChanged }
        defer { IOObjectRelease(entry) }
        let snapshot = try USBHostTopology.snapshot(entry)
        guard !pending.values.contains(snapshot.identity.registryEntryID) else { throw USBStorageError.operationInProgress }
        if let displayed = device.hostIdentity,
           !displayed.sameConnection(as: snapshot.identity, requireGeneration: true) { throw USBStorageError.identityChanged }
        let needsStorage = snapshot.requiresStorageHandoff(device)
        // A Mac may itself boot from USB. Never prepare the startup filesystem.
        if needsStorage {
            guard let startup = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: "/") as CFURL) else {
                throw USBStorageError.storageNotReady
            }
            let startupMedia = DADiskCopyIOMedia(DADiskCopyWholeDisk(startup) ?? startup)
            guard startupMedia != 0 else { throw USBStorageError.storageNotReady }
            var startupAncestors: Set<UInt64> = []
            let complete = ancestors(startupMedia, visited: &startupAncestors)
            IOObjectRelease(startupMedia)
            guard complete else { throw USBStorageError.storageNotReady }
            guard !startupAncestors.contains(matches[0]) else { throw USBStorageError.stateChanged }
        }
        if needsStorage {
            guard let notificationPort else { throw USBStorageError.storageNotReady }
            var observer: io_object_t = 0
            let result = IOServiceAddInterestNotification(notificationPort, entry, kIOBusyInterest,
                { context, service, _, _ in
                    guard let context else { return }
                    let bridge = StorageArbitration.bridge(context)
                    // Root busy transitions include client busy work. Remember
                    // even a busy->quiet pulse entirely between polling samples.
                    let id = try? USBHostTopology.registryID(service)
                    for (key, host) in bridge.pending where id == nil || host == id {
                        bridge.revisions[key, default: 0] &+= 1
                    }
                }, Unmanaged.passUnretained(self).toOpaque(), &observer)
            guard result == KERN_SUCCESS else {
                if observer != 0 { IOObjectRelease(observer) }
                throw USBStorageError.quietCheckFailed(result)
            }
            busyObservers[device.id] = observer
        }
        pending[device.id] = matches[0]
        anchors[device.id] = snapshot.identity
        revisions[device.id] = 0
        if needsStorage { storageRequired.insert(device.id) }
        Log.usb.info("[USBTransfer] physical USB id=\(device.id, privacy: .public) registry=\(matches[0]) storage=\(needsStorage)")
        Log.usb.debug("[USB Attach] pending mount prevention enabled device=\(device.id, privacy: .public)")
        return needsStorage
    }

    fileprivate func end(_ device: USBDevice) {
        ended.insert(device.id)
        clearFinishedTransactions()
    }

    private func clearFinishedTransactions() {
        for key in Array(ended) {
            let media = requestMedia[key, default: []]
            guard !requests.containsAny(media), !claimRequests.containsAny(media) else { continue }
            pending[key] = nil; anchors[key] = nil; requestMedia[key] = nil
            revisions[key] = nil; releasedRevisions[key] = nil
            ejectPlans[key] = nil; verifiedNodes[key] = nil
            if let observer = busyObservers.removeValue(forKey: key) { IOObjectRelease(observer) }
            preparedDevices.remove(key); invalidatedPreparations.remove(key)
            storageRequired.remove(key); ended.remove(key)
        }
    }

    private func track(_ disk: USBStorageDisk) throws {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(disk.registryID))
        guard media != 0 else { throw USBStorageError.identityChanged }
        defer { IOObjectRelease(media) }
        var ids: Set<UInt64> = []
        guard ancestors(media, visited: &ids) else { throw USBStorageError.storageNotReady }
        for (key, host) in pending where ids.contains(host) { requestMedia[key, default: []].insert(disk.registryID) }
    }

    fileprivate func validateHost(_ device: USBDevice) throws {
        _ = try liveHost(device)
    }

    private func liveHost(_ device: USBDevice, checkQuiet: Bool = false) throws -> USBHostSnapshot {
        guard let anchor = anchors[device.id] else { throw USBStorageError.identityChanged }
        let host = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(anchor.registryEntryID))
        guard host != 0 else { throw USBStorageError.identityChanged }
        defer { IOObjectRelease(host) }
        let snapshot = try USBHostTopology.snapshot(host, checkQuiet: checkQuiet)
        guard anchor.sameConnection(as: snapshot.identity, requireGeneration: true) else { throw USBStorageError.identityChanged }
        return snapshot
    }

    fileprivate func releaseSnapshot(_ device: USBDevice) throws -> USBHostSnapshot {
        guard let anchor = anchors[device.id] else { throw USBStorageError.identityChanged }
        let snapshots = try USBHostTopology.snapshots(quietHost: anchor.registryEntryID)
        guard var host = snapshots.first(where: { $0.identity == anchor }) else { throw USBStorageError.identityChanged }
        // The global mount audit takes time. Re-read the target subtree AFTER it
        // so a driver/media created during that audit cannot use the old snapshot.
        let final = try liveHost(device, checkQuiet: true)
        host.ioServiceNodes.merge(final.ioServiceNodes) { old, new in
            var result = new
            result.busyState = max(old.busyState, new.busyState)
            if old.waitQuietStatus != 0 { result.waitQuietStatus = old.waitQuietStatus }
            return result
        }
        host.mediaIDs.formUnion(final.mediaIDs)
        host.wholeDisks += final.wholeDisks
        host.storageServices.merge(final.storageServices) { _, new in new }
        host.hasSCSI = host.hasSCSI || final.hasSCSI
        host.busy = host.busy || final.busy
        host.exclusiveOwners += final.exclusiveOwners
        host.userClients += final.userClients
        try auditDiskArbitration(&host)
        return host
    }

    private func auditDiskArbitration(_ host: inout USBHostSnapshot) throws {
        guard let session else { throw USBStorageError.storageNotReady }
        for id in host.mediaIDs {
            guard let name = host.ioServiceNodes[id]?.identity.bsdName,
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/" + name),
                  mediaID(disk) == id,
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  description[kDADiskDescriptionMediaBSDNameKey as String] as? String == name else {
                throw USBStorageError.storageNotReady
            }
            if description[kDADiskDescriptionVolumePathKey as String] != nil { host.daMountedMedia.insert(id) }
        }
        host.diskArbitrationAuditComplete = true
    }

    fileprivate func recordEjectPlan(_ device: USBDevice, disks: [USBStorageDisk]) throws {
        let host = try releaseSnapshot(device)
        let physical = try USBStorageService.disks(for: device, hosts: USBStorageService.hosts())
        guard physical == disks.sorted(by: { $0.bsdName < $1.bsdName }),
              !physical.isEmpty || host.mediaIDs.isEmpty else { throw USBStorageError.diskNotFound }
        guard host.storageAuditComplete, host.diskArbitrationAuditComplete,
              host.mountedVolumes.isEmpty, host.daMountedMedia.isEmpty else { throw USBStorageError.diskStillMounted }
        ejectPlans[device.id] = USBStorageHandoffEvidence(host)
        preparedDevices.remove(device.id)
    }

    fileprivate func validatedQuiescenceSnapshot(_ device: USBDevice) throws -> USBHostSnapshot {
        guard preparedDevices.contains(device.id), let evidence = ejectPlans[device.id] else {
            throw USBStorageError.storageNotReady
        }
        guard !invalidatedPreparations.contains(device.id) else { throw USBStorageError.storageReappeared }
        let media = requestMedia[device.id, default: []]
        guard !requests.containsAny(media), !claimRequests.containsAny(media) else { throw USBStorageError.operationInProgress }
        let host = try releaseSnapshot(device)
        try evidence.validate(host)
        return host
    }

    fileprivate func checkForLaunch(_ device: USBDevice, logBoundary: Bool = false) throws {
        if storageRequired.contains(device.id) {
            let host = try validatedQuiescenceSnapshot(device)
            guard releasedRevisions[device.id] == revisions[device.id], releasedRevisions[device.id] != nil,
                  host.storageQuiescent,
                  verifiedNodes[device.id] == Set(host.ioServiceNodes.values.map(\.identity)) else {
                throw USBStorageError.storageReappeared
            }
            if logBoundary {
                Log.usb.info("[USBTransfer] host filesystem quiescent id=\(device.id, privacy: .public)")
                Log.usb.info("[USBTransfer] persistent storage services: \(host.storageServices.values.sorted().joined(separator: ", "), privacy: .public)")
                Log.usb.info("[USBTransfer] busy states follow; every relevant node must be quiet")
                USBStorageService.logQuiescence(host)
            }
        } else {
            guard try !liveHost(device).requiresStorageHandoff(device) else { throw USBStorageError.storageReappeared }
        }
    }

    func validateForLaunch(_ device: USBDevice) throws {
        try queue.sync { try checkForLaunch(device, logBoundary: true) }
    }

    fileprivate func ready(_ disks: [USBStorageDisk], unmounted: Bool, requireLifecycle: Bool = true) throws -> Bool {
        guard let session, !disks.isEmpty else { throw USBStorageError.diskNotFound }
        var targetHosts: Set<UInt64> = []
        for disk in disks {
            try USBStorageService.validate(disk)
            if requests.contains(disk) { return waiting("unfinished unmount " + disk.bsdName) }
            let media = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(disk.registryID))
            guard media != 0 else { throw USBStorageError.identityChanged }
            var ids: Set<UInt64> = []
            let complete = ancestors(media, visited: &ids)
            IOObjectRelease(media)
            guard complete else { throw USBStorageError.storageNotReady }
            let hosts = Set(pending.values).intersection(ids)
            guard !hosts.isEmpty else { throw USBStorageError.identityChanged }
            targetHosts.formUnion(hosts)
        }
        // A newly discovered LUN/whole disk invalidates this preparation. It has
        // not received the whole-disk unmount completion we are relying on.
        var physicalDisks: [USBStorageDisk] = []
        // IOKit busy includes asynchronous registration/probe work in descendants.
        for id in targetHosts {
            let host = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
            guard host != 0 else { throw USBStorageError.identityChanged }
            do { physicalDisks += try USBStorageService.wholeDisks(below: host) }
            catch { IOObjectRelease(host); throw error }
            var busy: UInt32 = 0
            let result = IOServiceGetBusyState(host, &busy)
            IOObjectRelease(host)
            guard result == KERN_SUCCESS, busy == 0 else { return waiting("IOKit busy=\(busy) status=\(result)") }
        }
        guard physicalDisks.sorted(by: { $0.bsdName < $1.bsdName }) == disks.sorted(by: { $0.bsdName < $1.bsdName }) else {
            throw USBStorageError.storageNotReady
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else {
            throw USBStorageError.storageNotReady
        }
        defer { IOObjectRelease(iterator) }
        var names: Set<String> = []
        var currentMedia: [USBStorageDisk] = []
        while true {
            let media = IOIteratorNext(iterator)
            guard media != 0 else { break }
            defer { IOObjectRelease(media) }
            var ids: Set<UInt64> = []
            guard ancestors(media, visited: &ids) else { throw USBStorageError.storageNotReady }
            guard !ids.isDisjoint(with: targetHosts) else { continue }
            guard let name = USBStorageService.property(media, "BSD Name") as? String,
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/" + name),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let id = mediaID(disk) else { return waiting("incomplete disk description") }
            if claimRequests.contains(USBStorageDisk(bsdName: name, registryID: id)) {
                return waiting("unfinished arbitration barrier " + name)
            }
            guard !requireLifecycle || lifecycle.isReady(name, registryID: id) else {
                return waiting("\(name): " + lifecycle.reason(name, registryID: id))
            }
            names.insert(name)
            currentMedia.append(USBStorageDisk(bsdName: name, registryID: id))
            if unmounted && description[kDADiskDescriptionVolumePathKey as String] != nil { return waiting("mounted " + name) }
        }
        guard IOIteratorIsValid(iterator) != 0, Set(disks.map(\.bsdName)).isSubset(of: names) else { return false }
        if unmounted {
            let mounts = try USBHostTopology.mountedFilesystems()
            for index in mounts.indices {
                let source = withUnsafePointer(to: mounts[index].f_mntfromname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
                }
                guard source.hasPrefix("/dev/disk") else { continue }
                if names.contains(String(source.dropFirst(5))) { return false }
                // Mounted APFS snapshots can have a BSD source without their
                // own IOMedia. Resolve the whole disk through DA as well.
                guard let mounted = DADiskCreateFromBSDName(kCFAllocatorDefault, session, source),
                      let whole = DADiskCopyWholeDisk(mounted) else { throw USBStorageError.storageNotReady }
                let media = DADiskCopyIOMedia(whole)
                guard media != 0 else { throw USBStorageError.storageNotReady }
                var ids: Set<UInt64> = []
                let complete = ancestors(media, visited: &ids)
                IOObjectRelease(media)
                guard complete else { throw USBStorageError.storageNotReady }
                if !ids.isDisjoint(with: targetHosts) { return false }
            }
        }
        lastMedia = currentMedia.sorted { $0.bsdName < $1.bsdName }
        lastWaitReason = ""
        return true
    }

    func mountBarrier(_ target: USBStorageDisk, deadline: ContinuousClock.Instant) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard let session, ContinuousClock.now < deadline,
                      let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/" + target.bsdName),
                      mediaID(disk) == target.registryID,
                      !claimRequests.contains(target) else {
                    continuation.resume(throwing: USBStorageError.storageNotReady)
                    return
                }
                do { try track(target) }
                catch { continuation.resume(throwing: error); return }
                let token = claimRequests.insert(target, continuation: continuation)
                claimDisks[token] = target
                // DA dispatches claim only after initial appearance and after the
                // disk's active command completes. This also covers a failed mount
                // which produces no VolumePath notification (notably EFI).
                // Never force an in-flight mount to stop. Keep the pending mount
                // veto across this barrier and all subsequent unmount operations.
                DADiskClaim(disk, DADiskClaimOptions(kDADiskClaimOptionDefault), nil, nil, { disk, dissenter, context in
                    guard let context else { return }
                    let bridge = StorageArbitration.shared
                    defer { bridge.clearFinishedTransactions() }
                    let token = Int(bitPattern: context)
                    guard let target = bridge.claimDisks.removeValue(forKey: token) else { return }
                    if let dissenter {
                        Log.usb.error("[USB Attach] arbitration barrier refused status=\(DADissenterGetStatus(dissenter))")
                        bridge.claimRequests.complete(token, result: .failure(USBStorageError.storageNotReady))
                    } else {
                        // Unclaim even after timeout/cancellation: never leave a
                        // late successful claim holding a disk indefinitely.
                        DADiskUnclaim(disk)
                        guard bridge.mediaID(disk) == target.registryID else {
                            bridge.claimRequests.complete(token, result: .failure(USBStorageError.identityChanged))
                            return
                        }
                        bridge.lifecycle.arbitrationCompleted(target.bsdName, registryID: target.registryID)
                        Log.usb.info("[USB Attach] arbitration barrier completed \(target.bsdName, privacy: .public)")
                        bridge.claimRequests.complete(token, result: .success(()))
                    }
                }, UnsafeMutableRawPointer(bitPattern: token))
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let seconds = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
                queue.asyncAfter(deadline: .now() + seconds) { [self] in claimRequests.timeout(token) }
            }
        }
        try Task.checkCancellation()
    }

    fileprivate func unmountTargets(_ physical: [USBStorageDisk]) throws -> [USBStorageDisk] {
        // DA whole-disk unmount on a physical store does not necessarily unmount
        // its synthesized APFS whole disk. Include those containers explicitly,
        // resolving ancestry through IOKit, and finish each callback in sequence.
        guard try ready(physical, unmounted: false) else { throw USBStorageError.storageNotReady }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else {
            throw USBStorageError.storageNotReady
        }
        defer { IOObjectRelease(iterator) }
        var wholeMedia: [USBStorageWholeMedia] = []
        while true {
            let media = IOIteratorNext(iterator)
            guard media != 0 else { break }
            defer { IOObjectRelease(media) }
            guard USBStorageService.property(media, "Whole") as? Bool == true else { continue }
            var ids: Set<UInt64> = []
            guard ancestors(media, visited: &ids) else { throw USBStorageError.storageNotReady }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS,
                  let name = USBStorageService.property(media, "BSD Name") as? String else {
                throw USBStorageError.storageNotReady
            }
            wholeMedia.append(USBStorageWholeMedia(disk: USBStorageDisk(bsdName: name, registryID: id), ancestors: ids))
        }
        guard IOIteratorIsValid(iterator) != 0 else { throw USBStorageError.storageNotReady }
        return USBStorageWholeMedia.unmountTargets(physical: physical, media: wholeMedia)
    }

    func eject(_ target: USBStorageDisk, device: USBDevice) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    do {
                        try validateHost(device)
                        // Resolve afresh by registry generation; never send an old
                        // DA object or a potentially reused BSD name to eject.
                        try USBStorageService.validate(target)
                        guard let session, !requests.contains(target),
                              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/" + target.bsdName),
                              mediaID(disk) == target.registryID,
                              let whole = DADiskCopyWholeDisk(disk), mediaID(whole) == target.registryID else {
                            throw USBStorageError.identityChanged
                        }
                        try track(target)
                        let token = requests.insert(target, continuation: continuation)
                        Log.usb.info("[USBTransfer] eject whole disk \(target.bsdName, privacy: .public)")
                        DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                            guard let context else { return }
                            let bridge = StorageArbitration.shared
                            defer { bridge.clearFinishedTransactions() }
                            let token = Int(bitPattern: context)
                            if let dissenter {
                                let status = DADissenterGetStatus(dissenter)
                                let error: USBStorageError
                                switch status {
                                case DAReturn(kDAReturnBusy): error = .ejectBusy
                                case DAReturn(kDAReturnNotPermitted), DAReturn(kDAReturnNotPrivileged): error = .ejectPermission
                                default: error = .ejectFailed(Int32(truncatingIfNeeded: status))
                                }
                                Log.usb.error("[USBTransfer] eject callback failed status=\(status)")
                                bridge.requests.complete(token, result: .failure(error))
                            } else {
                                Log.usb.info("[USBTransfer] eject callback completed; storage release is NOT yet verified")
                                bridge.requests.complete(token, result: .success(()))
                            }
                        }, UnsafeMutableRawPointer(bitPattern: token))
                        queue.asyncAfter(deadline: .now() + 8) { [self] in
                            requests.timeout(token, error: .ejectTimedOut)
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } catch let error as USBStorageError {
            // A vanished medium can race eject. Timeout and permission failures
            // never qualify. The physical USB anchor must still be the same.
            switch error {
            case .identityChanged, .ejectBusy, .ejectFailed:
                let absent = try await access { bridge in
                    let host = try bridge.releaseSnapshot(device)
                    return host.storageAuditComplete && host.mediaIDs.isEmpty && host.mountedVolumes.isEmpty
                }
                guard absent else { throw error }
                Log.usb.info("[USBTransfer] media vanished during eject; full release verification still required")
            default: throw error
            }
        }
        try Task.checkCancellation()
    }

    func unmount(_ disk: USBStorageDisk) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try USBStorageService.validate(disk)
                    guard let session,
                          !requests.contains(disk),
                          let volume = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/" + disk.bsdName),
                          let whole = DADiskCopyWholeDisk(volume), name(whole) == disk.bsdName else {
                        throw USBStorageError.storageNotReady
                    }
                    try track(disk)
                    let token = requests.insert(disk, continuation: continuation)
                    Log.usb.debug("[USB Attach] unmount whole disk requested \(disk.bsdName, privacy: .public)")
                    // Context is an opaque request number, not a retained Swift object.
                    // Timeout removes the continuation but keeps a quarantine until DA
                    // completes. A late callback cannot double-resume or use freed memory.
                    DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
                        guard let context else { return }
                        let bridge = StorageArbitration.shared
                        defer { bridge.clearFinishedTransactions() }
                        let token = Int(bitPattern: context)
                        if let dissenter {
                            let status = DADissenterGetStatus(dissenter)
                            let detail = DADissenterGetStatusString(dissenter) as String? ?? "Disk is busy"
                            Log.usb.error("[USB Attach] unmount failed status=\(status) reason=\(detail, privacy: .private)")
                            bridge.requests.complete(token, result: .failure(USBStorageError.unmountFailed("\(status): \(detail)")))
                        } else {
                            Log.usb.debug("[USB Attach] unmount callback success")
                            bridge.requests.complete(token, result: .success(()))
                        }
                    }, UnsafeMutableRawPointer(bitPattern: token))
                    queue.asyncAfter(deadline: .now() + 8) { [self] in
                        requests.timeout(token)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
    }
}

// Value state confined to the DA queue. Kept independent of DA/IOKit so timeout
// and late-callback ownership can be regression-tested without touching a disk.
struct USBUnmountRequests {
    private struct Request {
        let disk: USBStorageDisk
        var continuation: CheckedContinuation<Void, any Error>?
    }
    private var nextToken = 1
    private var entries: [Int: Request] = [:]

    func contains(_ disk: USBStorageDisk) -> Bool {
        entries.values.contains { $0.disk.registryID == disk.registryID }
    }

    func containsAny(_ ids: Set<UInt64>) -> Bool {
        entries.values.contains { ids.contains($0.disk.registryID) }
    }

    mutating func insert(_ disk: USBStorageDisk, continuation: CheckedContinuation<Void, any Error>) -> Int {
        let token = nextToken
        nextToken += 1
        entries[token] = Request(disk: disk, continuation: continuation)
        return token
    }

    mutating func complete(_ token: Int, result: Result<Void, any Error>) {
        entries.removeValue(forKey: token)?.continuation?.resume(with: result)
    }

    mutating func timeout(_ token: Int, error: USBStorageError = .storageNotReady) {
        let continuation = entries[token]?.continuation
        entries[token]?.continuation = nil
        continuation?.resume(throwing: error)
        // Keep only a small tombstone. No continuation, Task or CF object is
        // retained; another request for this IOMedia cannot pass until completion.
    }
}

// An appearance is DA's completed initial probe/automount stage. Merely finding
// an IOMedia or seeing a peek callback is insufficient. A later approved mount
// remains in flight until a mounted description (or disappearance) arrives;
// if no completion is observable, the caller times out and aborts.
struct USBMountLifecycle {
    private var appearedIDs: [String: UInt64] = [:]
    private var mounting: Set<String> = []

    mutating func probing(_ name: String) { appearedIDs[name] = nil }
    mutating func appeared(_ name: String, registryID: UInt64) {
        appearedIDs[name] = registryID
        mounting.remove(name)
    }
    mutating func arbitrationCompleted(_ name: String, registryID: UInt64) {
        appearedIDs[name] = registryID
        mounting.remove(name)
    }
    mutating func mountApproved(_ name: String) { mounting.insert(name) }
    mutating func mounted(_ name: String) { mounting.remove(name) }
    mutating func disappeared(_ name: String) {
        appearedIDs[name] = nil
        mounting.remove(name)
    }
    func reason(_ name: String, registryID: UInt64) -> String {
        if mounting.contains(name) { return "mount completion pending" }
        if appearedIDs[name] == nil { return "appearance pending" }
        if appearedIDs[name] != registryID { return "appearance identity mismatch" }
        return "ready"
    }
    func isReady(_ name: String, registryID: UInt64) -> Bool {
        appearedIDs[name] == registryID && !mounting.contains(name)
    }
}

struct USBStorageWholeMedia {
    let disk: USBStorageDisk
    let ancestors: Set<UInt64>

    static func unmountTargets(physical: [USBStorageDisk], media: [USBStorageWholeMedia]) -> [USBStorageDisk] {
        let physicalIDs = Set(physical.map(\.registryID))
        let containers = media.filter {
            !physicalIDs.contains($0.disk.registryID) && !$0.ancestors.isDisjoint(with: physicalIDs)
        }.map(\.disk)
        return containers.sorted { $0.bsdName < $1.bsdName } + physical
    }
}

// Pure policy: multiple fresh observations across the settle window, never a
// delay that converts busy work into readiness. Persistent quiet nodes may stay.
struct USBStorageReleaseGate {
    private(set) var quietSince: ContinuousClock.Instant?
    private var revision: UInt64?
    private var topology: Set<USBStorageNodeIdentity>?
    var settle: Duration = .milliseconds(250)
    var deadline: ContinuousClock.Instant?

    mutating func observe(released: Bool, revision: UInt64, now: ContinuousClock.Instant,
                          topology: Set<USBStorageNodeIdentity> = []) throws -> Bool {
        if let deadline, now >= deadline { throw USBStorageError.storageReleaseTimedOut }
        if let quietSince {
            guard released, self.revision == revision, self.topology == topology else { throw USBStorageError.storageReappeared }
            return quietSince.duration(to: now) >= settle
        }
        if released { quietSince = now; self.revision = revision; self.topology = topology }
        return false
    }
}

// This is preparation evidence, not a cache of live DA/IOKit objects. Removal
// during eject is allowed; newly created media, nodes or changed ancestry are not.
struct USBStorageHandoffEvidence {
    let identity: USBHostIdentity
    let mediaIDs: Set<UInt64>
    let nodes: Set<USBStorageNodeIdentity>
    let configuration: Int?
    let interfaceClasses: Set<Int>
    var nodeIDs: Set<UInt64> { Set(nodes.map(\.registryID)) }

    init(_ host: USBHostSnapshot) {
        identity = host.identity; mediaIDs = host.mediaIDs
        nodes = Set(host.ioServiceNodes.values.map(\.identity))
        configuration = host.configuration; interfaceClasses = host.interfaceClasses
    }

    func validate(_ host: USBHostSnapshot) throws {
        guard host.identity == identity else { throw USBStorageError.identityChanged }
        guard host.mediaIDs.isSubset(of: mediaIDs),
              Set(host.ioServiceNodes.values.map(\.identity)).isSubset(of: nodes),
              configuration == host.configuration, interfaceClasses == host.interfaceClasses else {
            throw USBStorageError.storageReappeared
        }
    }
}

extension USBHostSnapshot {
    func diagnostic(for node: USBStorageNode) -> String {
        let mounted = daMountedMedia.contains(node.identity.registryID)
        return node.diagnostic(blockedByFilesystem: mounted)
            + (mediaIDs.contains(node.identity.registryID) ? " DA-mounted=\(mounted)" : "")
    }

    var quiescenceDiagnostic: String {
        let nodes = ioServiceNodes.values.sorted { $0.identity.registryID < $1.identity.registryID }
            .map { diagnostic(for: $0) }.joined(separator: "; ")
        return "mounts=\(mountedVolumes.count) DA-mounted=\(daMountedMedia.count) mountAudit=\(storageAuditComplete) DAAudit=\(diskArbitrationAuditComplete) quiet=\(storageQuiescent); " + nodes
    }
}
