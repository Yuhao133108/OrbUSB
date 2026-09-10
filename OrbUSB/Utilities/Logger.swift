import OSLog

enum Log {
    static let cli = Logger(subsystem: "dev.orbusb.OrbUSB", category: "CLI")
    static let usb = Logger(subsystem: "dev.orbusb.OrbUSB", category: "USB")
    static let ui = Logger(subsystem: "dev.orbusb.OrbUSB", category: "UI")
    static let parser = Logger(subsystem: "dev.orbusb.OrbUSB", category: "Parser")
}
