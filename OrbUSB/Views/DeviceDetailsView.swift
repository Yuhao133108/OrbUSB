import SwiftUI

struct DeviceDetailsView: View {
    let device: USBDevice
    var showSerial = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            field("Name", device.name)
            field("Device ID", device.id)
            field("Vendor ID", device.vendorID)
            field("Product ID", device.productID)
            field("Manufacturer", device.manufacturer)
            field("Product", device.product)
            if showSerial { field("Serial", device.serialNumber) }
            field("USB Speed", device.speed)
            field("OrbStack State", device.state.title)
            field("Machine", device.passthroughMachine)
            field("Type", device.type)
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(.leading, 32)
        .padding(.bottom, 8)
    }

    private func field(_ label: String, _ value: String?) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
