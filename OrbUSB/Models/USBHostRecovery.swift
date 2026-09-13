import Foundation

enum HostBindingState: String, Sendable {
    case unknown = "Host state unverified"
    case available = "Available"
    case returning = "Returning to macOS"
    case driverUnavailable = "Host driver unavailable"
    case recovering = "Recovering…"
    case failed = "Recovery failed"
}

// Values only: never retain an IOKit handle, framework client, or disk identifier.
struct USBHostIdentity: Equatable, Hashable, Sendable {
    var vendorID: UInt16
    var productID: UInt16
    var serialNumber: String?
    var locationID: UInt32
    var registryEntryID: UInt64
    var topologyPath: String
    var parentRegistryEntryID: UInt64

    var generationKey: String { "\(locationID):\(registryEntryID):\(parentRegistryEntryID)" }

    func sameConnection(as other: Self, requireGeneration: Bool) -> Bool {
        vendorID == other.vendorID && productID == other.productID
            && serialNumber == other.serialNumber && locationID == other.locationID
            && topologyPath == other.topologyPath && parentRegistryEntryID == other.parentRegistryEntryID
            && (!requireGeneration || registryEntryID == other.registryEntryID)
    }

    // Missing, placeholder, and visibly defective serials cannot bridge a reset.
    // A port alone cannot distinguish unplug/replacement while the device is absent.
    var hasUsableSerial: Bool {
        guard let serialNumber, (4...126).contains(serialNumber.utf8.count),
              serialNumber == serialNumber.trimmingCharacters(in: .whitespacesAndNewlines),
              serialNumber.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              Set(serialNumber).count > 1 else { return false }
        return !["unknown", "none", "null", "default", "serial", "serialnumber", "123456789", "1234567890", "0123456789"].contains(serialNumber.lowercased())
    }
}

enum USBHostFunction: String, Sendable {
    case network, storage
}

struct USBHostSnapshot: Equatable, Sendable {
    var identity: USBHostIdentity
    var deviceClass: Int = 0
    var isController = false
    var configuration: Int?
    var preferredConfiguration: Int?
    var interfaceClasses: Set<Int> = []
    var interfaceDescriptions: [String] = []
    var exclusiveOwners: [String] = []
    var userClients: [String] = []
    var busy = false
    var topologyComplete = true
    var hasFunctionalDriver = false
    var hasSCSI = false
    var mediaIDs: Set<UInt64> = []
    var wholeDisks: [String] = []
    var networkInterfaces: [String] = []
    var mountedVolumes: [String] = []
    var storageAuditComplete = true
    // Persistent services are diagnostic information, not a handoff veto.
    var storageServices: [UInt64: String] = [:]
    var ioServiceNodes: [UInt64: USBStorageNode] = [:]
    var diskArbitrationAuditComplete = false
    var daMountedMedia: Set<UInt64> = []
    var quietChecksComplete = false

    var isHub: Bool { deviceClass == 9 || interfaceClasses.contains(9) }
    var hasOrbStackOwner: Bool {
        (exclusiveOwners + userClients).contains { $0.localizedCaseInsensitiveContains("orbstack") }
    }
    var hasStorage: Bool { deviceClass == 8 || interfaceClasses.contains(8) || hasSCSI || !mediaIDs.isEmpty || !wholeDisks.isEmpty || !storageServices.isEmpty }

    func requiresStorageHandoff(_ device: USBDevice) -> Bool {
        if device.isStorage || hasStorage { return true }
        // Only a complete, configured, positively identified interface set gets
        // the fast path. Vendor-specific or missing descriptors are uncertain.
        return !topologyComplete || busy || configuration == nil || configuration == 0
            || interfaceClasses.isEmpty || !interfaceClasses.isSubset(of: [1, 2, 3, 7, 9, 10, 14, 224])
    }

    var storageQuiescent: Bool {
        topologyComplete && storageAuditComplete && diskArbitrationAuditComplete
            && quietChecksComplete && !busy && !hasOrbStackOwner && (configuration ?? 0) > 0
            && mountedVolumes.isEmpty && daMountedMedia.isEmpty
            && ioServiceNodes[identity.registryEntryID] != nil
            && mediaIDs.isSubset(of: Set(ioServiceNodes.keys))
            && Set(storageServices.keys).isSubset(of: Set(ioServiceNodes.keys))
            && ioServiceNodes.values.allSatisfy(\.isQuiet)
    }

    func function(for device: USBDevice) -> USBHostFunction? {
        // Composite HID/audio/serial and unknown functions need separate policies.
        if device.isStorage || hasStorage {
            return interfaceClasses.isSubset(of: [8]) ? .storage : nil
        }
        if ["network", "ethernet"].contains(device.type?.lowercased() ?? "") || interfaceClasses.isSuperset(of: [2, 10]) {
            return interfaceClasses.isSubset(of: [2, 10, 255]) ? .network : nil
        }
        return nil
    }

    func ready(for function: USBHostFunction) -> Bool {
        guard topologyComplete, !hasOrbStackOwner, let configuration, configuration > 0 else { return false }
        switch function {
        case .network:
            if let preferredConfiguration, configuration != preferredConfiguration { return false }
            return !interfaceClasses.isEmpty && !networkInterfaces.isEmpty
        case .storage:
            return interfaceClasses.contains(8) && hasSCSI && !mediaIDs.isEmpty && !wholeDisks.isEmpty
        }
    }
}

struct USBStorageNodeIdentity: Equatable, Hashable, Sendable {
    let registryID: UInt64
    let className: String
    let bsdName: String?
    let parents: Set<UInt64>
}

struct USBStorageNode: Equatable, Sendable {
    let identity: USBStorageNodeIdentity
    var busyState: UInt32
    var waitQuietStatus: Int32?

    var isQuiet: Bool { busyState == 0 && waitQuietStatus == 0 }
    var diagnostic: String { diagnostic(blockedByFilesystem: false) }
    func diagnostic(blockedByFilesystem: Bool) -> String {
        "class=\(identity.className) registry=\(identity.registryID) bsd=\(identity.bsdName ?? "none") parents=\(identity.parents.sorted()) present=yes busy=\(busyState) waitQuiet=\(waitQuietStatus.map(String.init) ?? "unchecked") blocking=\(!isQuiet || blockedByFilesystem)"
    }
}

enum USBHostRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case deviceNotFound, ambiguousIdentity, identityChanged, unsupportedIdentity
    case stillAttachedToOrbStack, deviceBusy, storageInUse, safetyUnresolved
    case unsupportedDevice, operationInProgress, notEligible
    case openFailed(String), resetFailed(String), observationUnavailable
    case registryReadFailed(String)
    case deviceDisappeared, reenumerationTimedOut, functionalDriverTimedOut

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: "The USB device is no longer present. Refresh and try again."
        case .ambiguousIdentity: "Unable to identify this device uniquely. No reset was performed."
        case .identityChanged: "The USB device or its connection changed. Refresh and review the device."
        case .unsupportedIdentity: "Unable to safely recover this device: a unique, valid serial number and unchanged USB port are required."
        case .stillAttachedToOrbStack: "The device is still attached, forwarded, or owned by OrbStack. Detach it first."
        case .deviceBusy: "The device has an active driver or owner, or macOS is still preparing it. No reset was performed."
        case .storageInUse: "The device is currently in use by macOS and cannot be reset safely. IOMedia, a BSD disk, or a mounted volume still exists."
        case .safetyUnresolved: "Unable to safely recover this device: its topology or mounted-volume ancestry could not be verified."
        case .unsupportedDevice: "Recovery is currently supported only for identifiable USB network and mass-storage devices with no active functional stack."
        case .operationInProgress: "Another USB operation is in progress. Wait for it to finish."
        case .notEligible: "Recovery is available only after the macOS host driver has failed to return."
        case .openFailed(let detail): "Unable to open the USB device normally. Recovery stopped: \(detail)"
        case .resetFailed(let detail): "USB reset failed: \(detail)"
        case .observationUnavailable: "Unable to subscribe to host topology changes. No reset was performed."
        case .registryReadFailed(let detail): "Unable to verify current IORegistry topology: \(detail)"
        case .deviceDisappeared: "The device disappeared during recovery. Check its physical connection. No second reset was attempted."
        case .reenumerationTimedOut: "USB recovery could not be confirmed before the timeout. No second reset was attempted."
        case .functionalDriverTimedOut: "The USB device is present, but its macOS functional driver has not recovered before the timeout. No second reset was attempted."
        }
    }
}

enum RecoveryEligibility: Equatable, Sendable {
    case eligible, alreadyRecovered, ineligible(USBHostRecoveryError)
}

struct RecoveryResult: Equatable, Sendable {
    enum Outcome: String, Sendable { case recovered, alreadyRecovered }
    var operationID: UUID
    var outcome: Outcome
    var before: USBHostSnapshot
    var after: USBHostSnapshot
    var usbObservedAt: Date
    var functionalDriverObservedAt: Date
}

enum USBRecoveryPolicy {
    static func resolve(_ device: USBDevice, in hosts: [USBHostSnapshot],
                        anchor: USBHostIdentity? = nil, afterReset: Bool = false) throws -> USBHostSnapshot {
        guard let vendor = device.vendorID.flatMap({ UInt16($0, radix: 16) }),
              let product = device.productID.flatMap({ UInt16($0, radix: 16) }),
              let location = UInt32(device.id, radix: 16), location != 0 else {
            throw USBHostRecoveryError.unsupportedIdentity
        }
        let candidates = hosts.filter { $0.identity.locationID == location }
        guard !candidates.isEmpty else { throw USBHostRecoveryError.deviceNotFound }
        guard candidates.count == 1 else { throw USBHostRecoveryError.ambiguousIdentity }
        let host = candidates[0]
        guard host.identity.vendorID == vendor, host.identity.productID == product,
              host.identity.serialNumber == device.serialNumber?.nilIfBlank else { throw USBHostRecoveryError.identityChanged }
        if let anchor, !anchor.sameConnection(as: host.identity, requireGeneration: !afterReset) {
            throw USBHostRecoveryError.identityChanged
        }
        return host
    }

    static func validate(_ host: USBHostSnapshot, device: USBDevice, allHosts: [USBHostSnapshot],
                         function: USBHostFunction, ownClient: String? = nil) throws -> RecoveryEligibility {
        guard device.state == .available, device.detailError == nil, !host.hasOrbStackOwner else {
            throw USBHostRecoveryError.stillAttachedToOrbStack
        }
        guard !host.isHub, !host.isController, host.function(for: device) == function else {
            throw USBHostRecoveryError.unsupportedDevice
        }
        guard host.topologyComplete else { throw USBHostRecoveryError.safetyUnresolved }
        // This MUST precede the storage-in-use gate: a lagging UI never resets a recovered disk.
        if host.ready(for: function) { return .alreadyRecovered }
        guard host.identity.hasUsableSerial else { throw USBHostRecoveryError.unsupportedIdentity }
        guard allHosts.filter({ $0.identity.vendorID == host.identity.vendorID
            && $0.identity.productID == host.identity.productID
            && $0.identity.serialNumber == host.identity.serialNumber }).count == 1 else {
            throw USBHostRecoveryError.ambiguousIdentity
        }
        guard host.storageAuditComplete else { throw USBHostRecoveryError.safetyUnresolved }
        guard host.mediaIDs.isEmpty, host.wholeDisks.isEmpty, host.mountedVolumes.isEmpty else {
            throw USBHostRecoveryError.storageInUse
        }
        let otherOwners = (host.exclusiveOwners + host.userClients).filter { $0 != ownClient }
        guard !host.busy, !host.hasFunctionalDriver, otherOwners.isEmpty else { throw USBHostRecoveryError.deviceBusy }
        return .eligible
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
