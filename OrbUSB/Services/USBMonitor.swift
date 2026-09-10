import Foundation
import IOKit
import IOKit.usb
import OSLog

@MainActor
final class USBMonitor {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var onChange: (@MainActor @Sendable () -> Void)?
    private(set) var isRunning = false

    func start(onChange: @escaping @MainActor @Sendable () -> Void) -> Bool {
        stop()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        self.port = port
        self.onChange = onChange
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<USBMonitor>.fromOpaque(context).takeUnretainedValue()
                if USBMonitor.drain(iterator) { monitor.onChange?() }
            }
        }
        guard IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                  IOServiceMatching(kIOUSBDeviceClassName), callback, context, &added) == KERN_SUCCESS else {
            stop()
            return false
        }
        _ = USBMonitor.drain(added) // Arm the iterator; existing devices aren't hotplug events.
        guard IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                  IOServiceMatching(kIOUSBDeviceClassName), callback, context, &removed) == KERN_SUCCESS else {
            stop()
            return false
        }
        _ = USBMonitor.drain(removed)
        isRunning = true
        Log.usb.debug("USB hotplug monitoring started")
        return true
    }

    func stop() {
        if let port {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port)
        }
        port = nil
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        onChange = nil
        isRunning = false
    }

    isolated deinit { stop() }

    private static func drain(_ iterator: io_iterator_t) -> Bool {
        var changed = false
        while true {
            let object = IOIteratorNext(iterator)
            guard object != 0 else { break }
            IOObjectRelease(object)
            changed = true
        }
        return changed
    }
}
