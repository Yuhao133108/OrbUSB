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
    func begin(for device: USBDevice) async throws
    func end(for device: USBDevice) async
    func resolveDisks(for device: USBDevice) async throws -> [USBStorageDisk]
    func waitForMount(on disks: [USBStorageDisk]) async throws
    func unmountVolumes(on disks: [USBStorageDisk]) async throws
    func verifyUnmount(on disks: [USBStorageDisk]) async throws
    func finalCheck(for device: USBDevice, on disks: [USBStorageDisk]) async throws
}

struct USBStorageService: USBStoragePreparing {
    private let arbitration = StorageArbitration.shared

    func begin(for device: USBDevice) async throws {
        try await arbitration.access { try $0.begin(device) }
    }

    func end(for device: USBDevice) async {
        _ = try? await arbitration.access { $0.pending[device.id] = nil; $0.verified.removeAll(); $0.verifiedTopology.removeAll() }
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
            for disk in disks {
                bridge.verified[disk.registryID] = bridge.generation
                bridge.verifiedTopology[disk.registryID] = bridge.lastTopology
            }
        }
    }

    func finalCheck(for device: USBDevice, on disks: [USBStorageDisk]) async throws {
        try await arbitration.access { bridge in
            try bridge.validateHost(device)
            guard disks.allSatisfy({ bridge.verified[$0.registryID] == bridge.generation }),
                  try bridge.ready(disks, unmounted: true),
                  disks.allSatisfy({ bridge.verifiedTopology[$0.registryID] == bridge.lastTopology }) else { throw USBStorageError.storageNotReady }
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
        guard !disks.isEmpty else { throw USBStorageError.diskNotFound }
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
    fileprivate var pending: [String: UInt64] = [:]
    private var lifecycle = USBMountLifecycle()
    fileprivate var generation: UInt64 = 0
    fileprivate var verified: [UInt64: UInt64] = [:]
    fileprivate var verifiedTopology: [UInt64: Set<UInt64>] = [:]
    fileprivate var lastTopology: Set<UInt64> = []
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
            generation &+= 1
            verified.removeAll()
            verifiedTopology.removeAll()
            Log.usb.debug("[USB Attach] \(kind, privacy: .public) \(self.name(disk) ?? "unknown", privacy: .public)")
        }
    }

    fileprivate func begin(_ device: USBDevice) throws {
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
        guard matches.count == 1 else { throw USBStorageError.identityChanged }
        // A Mac may itself boot from USB. Never prepare the startup filesystem.
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
        pending[device.id] = matches[0]
        Log.usb.debug("[USB Attach] pending mount prevention enabled device=\(device.id, privacy: .public)")
    }

    fileprivate func validateHost(_ device: USBDevice) throws {
        guard let id = pending[device.id] else { throw USBStorageError.identityChanged }
        let host = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard host != 0 else { throw USBStorageError.identityChanged }
        defer { IOObjectRelease(host) }
        guard (USBStorageService.property(host, "locationID") as? NSNumber)?.uint32Value == UInt32(device.id, radix: 16) else {
            throw USBStorageError.identityChanged
        }
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
        var topology: Set<UInt64> = []
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
            topology.insert(id)
            currentMedia.append(USBStorageDisk(bsdName: name, registryID: id))
            if unmounted && description[kDADiskDescriptionVolumePathKey as String] != nil { return waiting("mounted " + name) }
        }
        guard IOIteratorIsValid(iterator) != 0, Set(disks.map(\.bsdName)).isSubset(of: names) else { return false }
        if unmounted {
            var mounts: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&mounts, MNT_NOWAIT)
            guard count > 0, let mounts else { throw USBStorageError.storageNotReady }
            for index in 0..<Int(count) {
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
        lastTopology = topology
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
                    let token = requests.insert(disk, continuation: continuation)
                    Log.usb.debug("[USB Attach] unmount whole disk requested \(disk.bsdName, privacy: .public)")
                    // Context is an opaque request number, not a retained Swift object.
                    // Timeout removes the continuation but keeps a quarantine until DA
                    // completes. A late callback cannot double-resume or use freed memory.
                    DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
                        guard let context else { return }
                        let bridge = StorageArbitration.shared
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

    mutating func insert(_ disk: USBStorageDisk, continuation: CheckedContinuation<Void, any Error>) -> Int {
        let token = nextToken
        nextToken += 1
        entries[token] = Request(disk: disk, continuation: continuation)
        return token
    }

    mutating func complete(_ token: Int, result: Result<Void, any Error>) {
        entries.removeValue(forKey: token)?.continuation?.resume(with: result)
    }

    mutating func timeout(_ token: Int) {
        let continuation = entries[token]?.continuation
        entries[token]?.continuation = nil
        continuation?.resume(throwing: USBStorageError.storageNotReady)
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
