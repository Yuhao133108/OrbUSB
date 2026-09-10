import Foundation
import IOKit

enum USBStorageError: Error, LocalizedError, Sendable, Equatable {
    case diskNotFound
    case ambiguousDevice
    case identityChanged
    case stateChanged
    case unmountFailed(String)

    var errorDescription: String? {
        switch self {
        case .diskNotFound: "Unable to find this USB device's disk. Refresh and try again."
        case .ambiguousDevice: "Unable to identify this USB disk uniquely."
        case .identityChanged: "The USB device changed or disconnected. Refresh and try again."
        case .stateChanged: "Device is no longer available. Review its current state and try again."
        case .unmountFailed(let reason): "Unable to unmount volumes. \(reason)"
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
    func resolveDisks(for device: USBDevice) async throws -> [USBStorageDisk]
    func unmountVolumes(on disks: [USBStorageDisk]) async throws
}

struct USBStorageService: USBStoragePreparing {
    func resolveDisks(for device: USBDevice) async throws -> [USBStorageDisk] {
        try Task.checkCancellation()
        return try Self.disks(for: device, hosts: Self.hosts())
    }

    static func disks(for device: USBDevice, hosts: [USBStorageHost]) throws -> [USBStorageDisk] {
        guard let vendorID = device.vendorID, let productID = device.productID else {
            throw USBStorageError.diskNotFound
        }
        let candidates = hosts.filter { host in
            guard host.vendorID == vendorID, host.productID == productID else { return false }
            if let serial = device.serialNumber, !serial.isEmpty { return host.serialNumber == serial }
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
        for disk in disks {
            try Task.checkCancellation()
            // BSD names can be reused after unplugging. Verify the original IOMedia
            // still owns this name immediately before invoking diskutil.
            try Self.validate(disk)
            do {
                let result = try await OrbCLI().run(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
                    arguments: ["unmountDisk", "/dev/" + disk.bsdName], timeout: 75)
                guard result.terminationStatus == 0 else {
                    let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw USBStorageError.unmountFailed(detail.isEmpty ? "Close apps using the disk and try again." : detail)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as USBStorageError {
                throw error
            } catch OrbStackError.timedOut {
                throw USBStorageError.unmountFailed("The disk did not respond in time. Close apps using it and try again.")
            } catch {
                throw USBStorageError.unmountFailed(error.localizedDescription)
            }
        }
    }

    private static func validate(_ disk: USBStorageDisk) throws {
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

    private static func hosts() throws -> [USBStorageHost] {
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

    private static func wholeDisks(below entry: io_registry_entry_t) throws -> [USBStorageDisk] {
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

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
