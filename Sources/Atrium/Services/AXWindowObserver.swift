import ApplicationServices

/// Delivers AX notifications for one element on the main run loop. Swift 6 safe: the C callback carries an unretained
/// pointer to this main-actor object and hops in with `assumeIsolated` (the run-loop source is on the main run loop).
@MainActor
final class AXWindowObserver {
    private var observer: AXObserver?
    private let element: AXUIElement
    private let notifications: [String]
    private let handler: @MainActor (String, AXUIElement) -> Void

    convenience init?(pid: pid_t, element: AXUIElement, notifications: [String], handler: @escaping @MainActor (String) -> Void) {
        self.init(pid: pid, element: element, notifications: notifications, elementHandler: { name, _ in handler(name) })
    }

    /// `elementHandler` also receives the element the notification is about (for window-created: the new window).
    init?(pid: pid_t, element: AXUIElement, notifications: [String], elementHandler: @escaping @MainActor (String, AXUIElement) -> Void) {
        self.element = element
        self.notifications = notifications
        self.handler = elementHandler
        let callback: AXObserverCallback = { _, subject, notification, refcon in
            guard let refcon else { return }
            let name = notification as String
            let me = Unmanaged<AXWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            nonisolated(unsafe) let subject = subject           // only touched on the main thread, right here
            MainActor.assumeIsolated { me.handler(name, subject) }
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for n in notifications where AXObserverAddNotification(created, element, n as CFString, refcon) == .success { registered = true }
        guard registered else { observer = nil; return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    /// Must be called before release (the refcon is unretained). Never from inside the handler.
    func invalidate() {
        guard let observer else { return }
        for n in notifications { AXObserverRemoveNotification(observer, element, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}
