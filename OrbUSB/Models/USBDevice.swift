import Foundation

enum USBOperationPhase: String, Sendable {
    case ejecting = "Ejecting disks"
    case waitingForStorageRelease = "Waiting for storage to become idle"
    case waitingForMount = "Waiting for macOS"
    case verifyingUnmount = "Verifying volumes"
    case settling = "Preparing"
    case resolvingDisk = "Resolving disk"
    case unmountingVolumes = "Unmounting volumes"
    case resolvingUSBID = "Re-resolving OrbStack USB ID"
    case attaching = "Attaching"
    case detaching = "Detaching"
    case recovering = "Recovering"
}

enum USBTransferState: String, Sendable {
    case idle, preparing, ejecting, waitingForStorageRelease, attaching, attached, detaching, failed
}

struct USBDeviceOperation {
    let device: USBDevice
    var phase: USBOperationPhase

    func matches(_ other: USBDevice) -> Bool {
        if let identity = device.hostIdentity, let otherIdentity = other.hostIdentity {
            return identity.sameConnection(as: otherIdentity, requireGeneration: true)
        }
        return device.id == other.id || device.hasSameSerialIdentity(as: other)
    }
}

enum USBDeviceState: String, CaseIterable, Sendable {
    case available, attached, forwarded, unknown

    var title: String {
        switch self {
        case .available: "Available"
        case .attached: "Connected to Linux"
        case .forwarded: "Forwarded"
        case .unknown: "Unknown"
        }
    }
}

struct USBDevice: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var vendorID: String?
    var productID: String?
    var manufacturer: String?
    var product: String?
    var serialNumber: String?
    var speed: String?
    var state: USBDeviceState = .unknown
    var passthroughMachine: String?
    var type: String?
    var enumeration: Int?
    var detailError: String?
    var hostIdentity: USBHostIdentity?
    var hostBindingState: HostBindingState = .unknown
    var recoveryEligibility: RecoveryEligibility?
    var recoveryError: String?

    var vidPID: String { "\(vendorID ?? "—"):\(productID ?? "—")" }
    var preferenceKey: String {
        // Length-prefix components so separators inside device strings cannot collide.
        func key(_ parts: [String]) -> String { parts.map { "\($0.utf8.count):\($0)" }.joined() }
        if let serialNumber, !serialNumber.isEmpty {
            return "serial:" + key([vendorID ?? "", productID ?? "", serialNumber])
        }
        if let vendorID, let productID, let product, !product.isEmpty {
            return "product:" + key([vendorID, productID, product])
        }
        return "id:" + id
    }
    var connectionKey: String { "\(id)|\(preferenceKey)|\(enumeration ?? -1)" }
    var mutationKey: String { UInt32(id, radix: 16).map { String($0, radix: 16) } ?? id }
    var isStorage: Bool {
        ["storage", "massstorage"].contains(type?.lowercased() ?? "")
    }

    func hasSameSerialIdentity(as other: USBDevice) -> Bool {
        guard let vendorID, let productID, let serialNumber, !serialNumber.isEmpty else { return false }
        return vendorID == other.vendorID && productID == other.productID && serialNumber == other.serialNumber
    }

    func resolvedAfterUnmount(in devices: [USBDevice]) throws -> USBDevice {
        // A product/favorite key is not sufficient to identify a re-enumerated device.
        let matches = devices.filter {
            if let serialNumber, !serialNumber.isEmpty {
                return hasSameSerialIdentity(as: $0)
            }
            return connectionKey == $0.connectionKey
        }
        guard matches.count == 1, let current = matches.first else {
            throw USBStorageError.identityChanged
        }
        guard current.state == .available else {
            throw USBStorageError.stateChanged
        }
        return current
    }
    var symbol: String {
        switch type?.lowercased() {
        case "massstorage", "storage": "externaldrive"
        case "audio": "headphones"
        case "network", "ethernet": "network"
        default: "cable.connector"
        }
    }
}
