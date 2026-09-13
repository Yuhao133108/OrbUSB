import Foundation
import IOKit
import IOUSBHost
import DiskArbitration
import Darwin

// All IOKit references are scoped to synchronous calls. Only snapshots cross actors.
enum USBHostTopology {
    static func snapshots(quietHost: UInt64? = nil) throws -> [USBHostSnapshot] {
        var hosts: [USBHostSnapshot] = []
        try matching("IOUSBHostDevice") { service in
            hosts.append(try snapshot(service, checkQuiet: quietHost == registryID(service)))
        }
        try auditMediaAndMounts(&hosts, quietHost: quietHost)
        return hosts
    }

    static func snapshot(_ service: io_service_t, checkQuiet: Bool = false) throws -> USBHostSnapshot {
        guard IOObjectConformsTo(service, "IOUSBHostDevice") != 0,
              let vendor = number(service, "idVendor"), let product = number(service, "idProduct"),
              let location = number(service, "locationID"), let deviceClass = number(service, "bDeviceClass") else {
            throw USBHostRecoveryError.registryReadFailed("Required USB device descriptors are missing.")
        }
        var parent: io_registry_entry_t = 0
        let parentResult = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
        guard parentResult == KERN_SUCCESS else {
            throw USBHostRecoveryError.registryReadFailed("USB parent lookup: \(parentResult)")
        }
        defer { IOObjectRelease(parent) }
        var path = [CChar](repeating: 0, count: 1024)
        guard IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS else {
            throw USBHostRecoveryError.registryReadFailed("USB topology path unavailable.")
        }
        let identity = USBHostIdentity(vendorID: vendor.uint16Value, productID: product.uint16Value,
            serialNumber: (property(service, "USB Serial Number") as? String).flatMap { $0.isEmpty ? nil : $0 },
            locationID: location.uint32Value, registryEntryID: try registryID(service),
            topologyPath: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) },
            parentRegistryEntryID: try registryID(parent))
        var host = USBHostSnapshot(identity: identity, deviceClass: deviceClass.intValue,
            isController: IOObjectConformsTo(service, "IOUSBHostController") != 0,
            configuration: number(service, "kUSBCurrentConfiguration")?.intValue,
            preferredConfiguration: number(service, "kUSBPreferredConfiguration")?.intValue)
        try collect(service, root: true, checkQuiet: checkQuiet, into: &host)
        host.quietChecksComplete = checkQuiet
        // A raced teardown invalidates the entire snapshot, not just missing children.
        guard try registryID(service) == identity.registryEntryID else { throw USBHostRecoveryError.identityChanged }
        return host
    }

    private static func collect(_ entry: io_registry_entry_t, root: Bool, checkQuiet: Bool, into host: inout USBHostSnapshot) throws {
        if !root, IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 { return }
        let node = try storageNode(entry, checkQuiet: checkQuiet)
        host.ioServiceNodes[node.identity.registryID] = node
        host.busy = host.busy || node.busyState != 0
        let className = node.identity.className
        if try isStorageService(entry) {
            host.storageServices[try registryID(entry)] = className
        }
        if let owner = property(entry, "UsbExclusiveOwner") {
            guard let name = owner as? String, !name.isEmpty else { throw USBHostRecoveryError.safetyUnresolved }
            host.exclusiveOwners.append(name)
        }
        if IOObjectConformsTo(entry, "AppleUSBHostFrameworkDeviceClient") != 0 {
            host.userClients.append(property(entry, "IOUserClientCreator") as? String ?? "Unknown USB userspace client")
        } else if !root, IOObjectConformsTo(entry, "IOUSBHostInterface") != 0 {
            guard let interfaceClass = number(entry, "bInterfaceClass")?.intValue else {
                throw USBHostRecoveryError.safetyUnresolved
            }
            host.interfaceClasses.insert(interfaceClass)
            host.interfaceDescriptions.append("\(number(entry, "bInterfaceNumber")?.intValue ?? -1):\(interfaceClass)/\(number(entry, "bInterfaceSubClass")?.intValue ?? -1)/\(number(entry, "bInterfaceProtocol")?.intValue ?? -1)")
        } else if !root, className != "AppleUSBHostCompositeDevice" {
            // Any live functional child (including a partially started driver) vetoes reset.
            host.hasFunctionalDriver = true
        }
        if className.contains("SCSI") { host.hasSCSI = true }
        if IOObjectConformsTo(entry, "IOMedia") != 0 {
            host.mediaIDs.insert(try registryID(entry))
            if property(entry, "Whole") as? Bool == true, let bsd = property(entry, "BSD Name") as? String {
                host.wholeDisks.append(bsd)
            }
        }
        if IOObjectConformsTo(entry, "IOEthernetInterface") != 0, let bsd = property(entry, "BSD Name") as? String, !bsd.isEmpty {
            host.networkInterfaces.append(bsd)
        }
        var iterator: io_iterator_t = 0
        let childrenResult = IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator)
        guard childrenResult == KERN_SUCCESS else {
            throw USBHostRecoveryError.registryReadFailed("Child iterator: \(childrenResult)")
        }
        defer { IOObjectRelease(iterator) }
        try drain(iterator) { try collect($0, root: false, checkQuiet: checkQuiet, into: &host) }
    }

    // Inspect ALL parent edges, including APFS physical stores and synthesized media.
    // BSD names are outputs of this traversal, never USB identity inputs.
    private static func ancestors(_ entry: io_registry_entry_t, into ids: inout Set<UInt64>) throws {
        guard ids.insert(try registryID(entry)).inserted else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            throw USBHostRecoveryError.safetyUnresolved
        }
        defer { IOObjectRelease(iterator) }
        try drain(iterator) { try ancestors($0, into: &ids) }
    }

    private static func auditMediaAndMounts(_ hosts: inout [USBHostSnapshot], quietHost: UInt64?) throws {
        do {
            try matching("IOMedia") { media in
                var ids: Set<UInt64> = []
                try ancestors(media, into: &ids)
                let id = try registryID(media)
                for index in hosts.indices where ids.contains(hosts[index].identity.registryEntryID) {
                    hosts[index].mediaIDs.insert(id)
                    // APFS media can be reached through more than one parent.
                    if hosts[index].ioServiceNodes[id] == nil {
                        let node = try storageNode(media, checkQuiet: hosts[index].identity.registryEntryID == quietHost)
                        hosts[index].ioServiceNodes[id] = node
                        hosts[index].busy = hosts[index].busy || node.busyState != 0
                    }
                    if let bsd = property(media, "BSD Name") as? String, property(media, "Whole") as? Bool == true,
                       !hosts[index].wholeDisks.contains(bsd) { hosts[index].wholeDisks.append(bsd) }
                }
            }
            guard let session = DASessionCreate(kCFAllocatorDefault) else { throw USBHostRecoveryError.safetyUnresolved }
            let mounts = try USBHostTopology.mountedFilesystems()
            for index in mounts.indices {
                let source = withUnsafePointer(to: mounts[index].f_mntfromname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
                }
                let fileSystem = withUnsafePointer(to: mounts[index].f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
                }
                guard isDiskBackedMount(source: source, fileSystem: fileSystem) else { continue }
                let path = withUnsafePointer(to: mounts[index].f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
                }
                // Volume-path resolution also covers a mounted snapshot with no own IOMedia.
                guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL),
                      let whole = DADiskCopyWholeDisk(disk) else { throw USBHostRecoveryError.safetyUnresolved }
                let media = DADiskCopyIOMedia(whole)
                guard media != 0 else { throw USBHostRecoveryError.safetyUnresolved }
                var ids: Set<UInt64> = []
                do { try ancestors(media, into: &ids) }
                catch { IOObjectRelease(media); throw error }
                IOObjectRelease(media)
                for hostIndex in hosts.indices where ids.contains(hosts[hostIndex].identity.registryEntryID) {
                    hosts[hostIndex].mountedVolumes.append(path)
                }
            }
        } catch {
            // Read-only status can still show a healthy driver; reset requires a complete audit.
            for index in hosts.indices { hosts[index].storageAuditComplete = false }
        }
    }

    static func mountedFilesystems() throws -> [statfs] {
        // Caller-owned storage avoids getmntinfo's shared buffer when UI/recovery
        // snapshots and handoff audits run on different queues.
        for _ in 0..<3 {
            let count = getfsstat(nil, 0, MNT_NOWAIT)
            guard count > 0, count < 100_000 else { throw USBStorageError.storageNotReady }
            var records: [statfs] = .init(repeating: .init(), count: Int(count) + 16)
            let bytes = Int32(records.count * MemoryLayout<statfs>.stride)
            let read = records.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, bytes, MNT_NOWAIT) }
            guard read > 0 else { throw USBStorageError.storageNotReady }
            if Int(read) < records.count { return Array(records.prefix(Int(read))) }
            // Mount list grew to fill the buffer: never accept a truncated list.
        }
        throw USBStorageError.storageNotReady
    }

    static func isDiskBackedMount(source: String, fileSystem: String) -> Bool {
        // APFS snapshots may expose a name@device source, not a /dev/ prefix.
        source.hasPrefix("/dev/") || ["apfs", "hfs"].contains(fileSystem.lowercased())
    }

    static func matching(_ name: String, body: (io_service_t) throws -> Void) throws {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator)
        guard result == KERN_SUCCESS else {
            throw USBHostRecoveryError.registryReadFailed("Matching \(name): \(result)")
        }
        // IOKit explicitly returns IO_OBJECT_NULL on a successful empty match.
        guard iterator != 0 else { return }
        defer { IOObjectRelease(iterator) }
        try drain(iterator, body: body)
    }

    private static func drain(_ iterator: io_iterator_t, body: (io_registry_entry_t) throws -> Void) throws {
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            try body(entry)
        }
        guard IOIteratorIsValid(iterator) != 0 else { throw USBHostRecoveryError.registryReadFailed("Iterator invalidated during enumeration.") }
    }

    static func registryID(_ service: io_registry_entry_t) throws -> UInt64 {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id != 0 else {
            throw USBHostRecoveryError.identityChanged
        }
        return id
    }

    private static func className(_ entry: io_registry_entry_t) throws -> String {
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &name) == KERN_SUCCESS else { throw USBHostRecoveryError.safetyUnresolved }
        return name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func storageNode(_ entry: io_registry_entry_t, checkQuiet: Bool) throws -> USBStorageNode {
        var parents: Set<UInt64> = []
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            throw USBHostRecoveryError.safetyUnresolved
        }
        defer { IOObjectRelease(iterator) }
        try drain(iterator) { parents.insert(try registryID($0)) }
        var busy: UInt32 = 0
        guard IOServiceGetBusyState(entry, &busy) == KERN_SUCCESS else { throw USBHostRecoveryError.safetyUnresolved }
        var status: Int32?
        if checkQuiet {
            // Zero-duration bounded probe, NEVER NULL (which means forever).
            // Polling supplies the aggregate 5s deadline without blocking the DA
            // queue and its mount-veto callbacks for each node. WaitQuiet only
            // reports IOKit lifecycle busy work, not every private SCSI request.
            var wait = mach_timespec_t(tv_sec: 0, tv_nsec: 0)
            let result = IOServiceWaitQuiet(entry, &wait)
            guard result == KERN_SUCCESS || result == kIOReturnTimeout else {
                throw USBStorageError.quietCheckFailed(result)
            }
            status = result
            var after: UInt32 = 0
            guard IOServiceGetBusyState(entry, &after) == KERN_SUCCESS else { throw USBHostRecoveryError.safetyUnresolved }
            busy = max(busy, after)
        }
        return USBStorageNode(identity: USBStorageNodeIdentity(registryID: try registryID(entry),
            className: try className(entry), bsdName: property(entry, "BSD Name") as? String, parents: parents),
            busyState: busy, waitQuietStatus: status)
    }

    static func isStorageService(_ entry: io_registry_entry_t) throws -> Bool {
        let name = try className(entry)
        return IOObjectConformsTo(entry, "IOStorage") != 0
            || IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0
            || name.contains("SCSI") || name.contains("MassStorage") || name.contains("BlockStorage")
    }

    private static func number(_ entry: io_registry_entry_t, _ key: String) -> NSNumber? { property(entry, key) as? NSNumber }
    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

actor SystemUSBHostRecoveryBackend: USBHostRecoveryBackend {
    func snapshots() throws -> [USBHostSnapshot] { try USBHostTopology.snapshots() }

    func observe(timeout: Duration) async throws -> USBRecoveryObservation {
        try await USBRecoveryObservation.start(timeout: timeout)
    }

    func reset(_ device: USBDevice, anchor: USBHostIdentity, function: USBHostFunction, operationID: UUID) throws -> Bool {
        try Task.checkCancellation()
        // This scope is synchronous: no suspension between final validation, ordinary open, and reset.
        return try autoreleasepool {
            let hosts = try USBHostTopology.snapshots()
            let before = try USBRecoveryPolicy.resolve(device, in: hosts, anchor: anchor)
            if try USBRecoveryPolicy.validate(before, device: device, allHosts: hosts, function: function) == .alreadyRecovered {
                return false
            }
            var target: io_service_t = 0
            defer { if target != 0 { IOObjectRelease(target) } }
            // Enumerate again. An old registry ID is only a generation check, never a lookup key.
            try USBHostTopology.matching("IOUSBHostDevice") { entry in
                let current = try USBHostTopology.snapshot(entry)
                if current.identity == anchor {
                    guard target == 0 else { throw USBHostRecoveryError.ambiguousIdentity }
                    IOObjectRetain(entry)
                    target = entry
                }
            }
            guard target != 0 else { throw USBHostRecoveryError.identityChanged }
            let client: IOUSBHostDevice
            do {
                // __ioService is Swift's imported spelling of the public NS_REFINED_FOR_SWIFT initializer.
                client = try IOUSBHostDevice(__ioService: target, options: [], queue: nil, interestHandler: nil)
                RecoveryLog.event(operationID, "ordinary open succeeded")
            } catch {
                RecoveryLog.event(operationID, "ordinary open failed: \(error)")
                throw USBHostRecoveryError.openFailed(Self.describe(error))
            }
            defer { client.destroy() } // Cleanup only; never query the old client after reset.
            let currentHosts = try USBHostTopology.snapshots()
            let current = try USBRecoveryPolicy.resolve(device, in: currentHosts, anchor: anchor)
            let ownClient = "pid \(getpid()), \(ProcessInfo.processInfo.processName)"
            if try USBRecoveryPolicy.validate(current, device: device, allHosts: currentHosts,
                                              function: function, ownClient: ownClient) == .alreadyRecovered { return false }
            try Task.checkCancellation()
            // Drop our old Mach-port reference before reset. Framework cleanup owns its reference.
            IOObjectRelease(target)
            target = 0
            do {
                try client.reset()
                RecoveryLog.event(operationID, "reset succeeded at \(Date())")
            } catch {
                RecoveryLog.event(operationID, "reset failed: \(error)")
                throw USBHostRecoveryError.resetFailed(Self.describe(error))
            }
            return true
        }
    }

    private static func describe(_ error: any Error) -> String {
        let value = error as NSError
        return "\(value.domain) (\(value.code)): \(value.localizedDescription)"
    }
}
