import AppKit
import SwiftUI

// MenuBarExtra can retain its content between openings. Observe the actual
// AppKit window as well as SwiftUI appearance to reliably stop polling.
struct MenuWindowObserver: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.state = state
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {}

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class ObserverView: NSView {
        weak var state: AppState?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    let opened = notification.name == NSWindow.didBecomeKeyNotification
                    MainActor.assumeIsolated {
                        if opened { self?.state?.openMenu() }
                        else { self?.state?.closeMenu() }
                    }
                })
            }
            if window.isKeyWindow { state?.openMenu() }
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}
