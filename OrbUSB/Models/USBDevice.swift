import Foundation

enum USBOperationPhase: String, Sendable {
    case resolvingDisk = "Resolving disk"
    case unmountingVolumes = "Unmounting volumes"
    case resolvingUSBID = "Re-resolving OrbStack USB ID"
    case attaching = "Attaching"
    case detaching = "Detaching"
}

struct USBDeviceOperation {
    let device: USBDevice
    var phase: USBOperationPhase

    func matches(_ other: USBDevice) -> Bool {
        device.id == other.id || device.hasSameSerialIdentity(as: other)
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
        case "network": "network"
        default: "cable.connector"
        }
    }
}
