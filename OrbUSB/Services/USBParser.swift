import Foundation

enum USBParser {
    private struct DeviceList: Decodable {
        let devices: [Entry]
        let ports: [Port]?
        private enum CodingKeys: String, CodingKey { case devices, ports }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.devices) else {
                throw OrbStackError.parseFailed("USB JSON has no devices field")
            }
            devices = try container.decodeIfPresent([Entry].self, forKey: .devices) ?? []
            ports = try container.decodeIfPresent([Port].self, forKey: .ports)
        }
    }
    private struct Port: Decodable {
        let bus_id: String?
        let vendor_id: Int?
        let product_id: Int?
        let serial_number: String?
    }
    private struct Entry: Decodable {
        let bus_id: String
        let path: String?
        let manufacturer: String?
        let serial_number: String?
        let vendor_id: Int?
        let product_id: Int?
        let category: String?
        let dev_num: Int?
    }

    static func listJSON(_ text: String) throws -> [USBDevice] {
        do {
            let list = try JSONDecoder().decode(DeviceList.self, from: Data(text.utf8))
            var ids = Set<String>()
            return try list.devices.map { entry in
                guard validID(entry.bus_id), ids.insert(entry.bus_id).inserted else {
                    throw OrbStackError.parseFailed("Invalid or duplicate bus_id")
                }
                func hex(_ value: Int?) throws -> String? {
                    guard let value else { return nil }
                    guard (0...65535).contains(value) else { throw OrbStackError.parseFailed("Invalid USB VID/PID") }
                    return String(format: "%04x", value)
                }
                let attached = list.ports?.contains { port in
                    port.bus_id == entry.bus_id
                    && (port.vendor_id == nil || port.vendor_id == entry.vendor_id)
                    && (port.product_id == nil || port.product_id == entry.product_id)
                    && (port.serial_number == nil || port.serial_number == entry.serial_number)
                } ?? false
                return USBDevice(id: entry.bus_id,
                    name: [entry.manufacturer, entry.path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty ?? "USB device",
                    vendorID: try hex(entry.vendor_id), productID: try hex(entry.product_id),
                    manufacturer: entry.manufacturer, product: entry.path, serialNumber: entry.serial_number,
                    state: attached ? .attached : .unknown, type: entry.category, enumeration: entry.dev_num)
            }
        } catch let error as OrbStackError { throw error }
        catch { throw OrbStackError.parseFailed("Unrecognized USB JSON: \(error)") }
    }

    static func info(_ text: String, device: USBDevice) throws -> USBDevice {
        var sections: [String: [String: String]] = [:]
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { section = key }
            else { sections[section, default: [:]][key] = value }
        }
        guard sections["details"]?["id"] == device.id else {
            throw OrbStackError.parseFailed("USB info ID missing or mismatched")
        }
        var result = device
        let details = sections["details"] ?? [:]
        let info = sections["info"] ?? [:]
        result.manufacturer = details["manufacturer"] ?? device.manufacturer
        result.product = details["name"] ?? device.product
        result.name = [result.manufacturer, result.product].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty ?? device.name
        if let identifiers = info["vendor/product id"]?.lowercased(),
           identifiers.range(of: #"^[0-9a-f]{4}:[0-9a-f]{4}$"#, options: .regularExpression) != nil {
            let parts = identifiers.split(separator: ":")
            result.vendorID = String(parts[0])
            result.productID = String(parts[1])
        }
        result.serialNumber = info["serial"] ?? device.serialNumber
        result.speed = info["speed"]
        result.type = details["type"] ?? device.type
        result.state = .unknown
        result.passthroughMachine = nil
        if let machine = sections["passthrough"]?["machine"], !machine.isEmpty {
            if machine.lowercased() == "not attached" {
                result.state = .available
            } else {
                result.state = .attached
                result.passthroughMachine = machine
            }
        }
        // Forwarding is read from an explicit CLI status; never infer it from device class.
        if result.state != .attached,
           let state = sections["passthrough"]?["state"] ?? sections["forwarding"]?["state"] {
            result.state = stateValue(state)
        }
        return result
    }

    // list JSON does not expose forwarding consistently. Use the CLI's explicit
    // STATE column as supplementary evidence, keyed by the current bus ID.
    static func listTextStates(_ text: String) throws -> [String: USBDeviceState] {
        let separator = try NSRegularExpression(pattern: #" {2,}|\t+"#)
        var result: [String: USBDeviceState] = [:]
        var stateIndex = 3
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let spaced = separator.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "\t")
            let columns = spaced.components(separatedBy: "\t")
            if columns.first?.uppercased() == "ID" {
                stateIndex = columns.firstIndex(where: { $0.uppercased() == "STATE" }) ?? 3
                continue
            }
            if line.allSatisfy({ $0 == "-" || $0.isWhitespace }) { continue }
            guard columns.count >= 3, let id = columns.first, validID(id),
                  columns[1].range(of: #"^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$"#, options: .regularExpression) != nil else {
                throw OrbStackError.parseFailed("Unrecognized USB text row")
            }
            result[id] = columns.count > stateIndex ? stateValue(columns[stateIndex]) : .available
        }
        return result
    }

    static func stateValue(_ value: String) -> USBDeviceState {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "attached": .attached
        case "forwarded", "shared with macos": .forwarded
        case "not shared", "not attached", "available": .available
        default: .unknown
        }
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:")).contains($0)
        } && !id.hasPrefix("-")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
