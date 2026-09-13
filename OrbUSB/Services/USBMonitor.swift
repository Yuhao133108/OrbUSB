import Foundation
import IOKit
import IOKit.usb
import OSLog

@MainActor
final class USBMonitor {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
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
        // The physical device can remain present while every functional driver vanishes.
        for name in ["IOUSBHostDevice", "IOUSBHostInterface", "IOMedia", "IOEthernetInterface"] {
            for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(port, notification,
                          IOServiceMatching(name), callback, context, &iterator) == KERN_SUCCESS else {
                    if iterator != 0 { IOObjectRelease(iterator) }
                    stop()
                    return false
                }
                iterators.append(iterator)
                _ = USBMonitor.drain(iterator) // Subscribe and arm BEFORE the caller takes a snapshot.
            }
        }
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
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
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
