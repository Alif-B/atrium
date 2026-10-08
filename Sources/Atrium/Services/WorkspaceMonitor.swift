import AppKit
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "switcher")

/// Keeps the store in sync with reality: which apps run, which one is frontmost (from any source: ⌘-Tab, Dock, clicks).
@MainActor
final class WorkspaceMonitor {
    private let store: AppStore
    private let prefs: Preferences
    private let switcher: AppSwitcher
    private let onManagedActivated: @MainActor (String) -> Void
    private var observers: [NSObjectProtocol] = []
    /// For apps that host several sidebar items (a browser with web apps): which item is in front, if any.
    var slotResolver: (@MainActor (String) -> String?)?
    private let onTerminated: @MainActor (pid_t) -> Void

    init(store: AppStore, prefs: Preferences, switcher: AppSwitcher, onManagedActivated: @escaping @MainActor (String) -> Void,
         onTerminated: @escaping @MainActor (pid_t) -> Void) {
        self.onTerminated = onTerminated
        self.store = store
        self.prefs = prefs
        self.switcher = switcher
        self.onManagedActivated = onManagedActivated

        let runningApps = NSWorkspace.shared.runningApplications
        store.runningBundleIDs = Set(runningApps.compactMap(\.bundleIdentifier))
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { handleActivate(front) }

        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: NSNotification.Name, _ handler: @escaping @MainActor (String, pid_t) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Extract Sendable values before hopping into the main-actor closure. Use the notification's own
                // process: an app can briefly have two (e.g. the helper instance used to open an Edge web app).
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier
                let pid = app?.processIdentifier ?? 0
                MainActor.assumeIsolated { if let id { handler(id, pid) } }
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] id, _ in
            self?.store.runningBundleIDs.insert(id)
            self?.store.launchingBundleIDs.remove(id)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] id, pid in
            self?.onTerminated(pid)
            // Only "not running" if no other instance of that app is still alive.
            guard Launcher.runningApp(bundleID: id) == nil else { return }
            if self?.store.activeBundleID == id { self?.store.activeBundleID = nil }     // it quit: no lens on a closed app
            self?.store.runningBundleIDs.remove(id)
            self?.store.launchingBundleIDs.remove(id)
            self?.store.badges[id] = nil
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] id, _ in self?.handleActivate(id) }
    }

    private func handleActivate(_ id: String) {
        if id == Bundle.main.bundleIdentifier { return }                     // clicking Atrium's own window: leave state alone
        if let slot = slotResolver?(id) {                                    // a web app's browser window came forward
            store.activeBundleID = slot
            prefs.lastActiveBundleID = slot
            onManagedActivated(slot)
            return
        }
        guard store.apps.contains(where: { $0.bundleIdentifier == id }) else {
            store.activeBundleID = nil                                        // some other app: the lens fades out
            return
        }
        store.activeBundleID = id
        store.runningBundleIDs.insert(id)
        prefs.lastActiveBundleID = id
        log.debug("activated managed app \(id, privacy: .public)")
        if switcher.inFlightBundleID != id { onManagedActivated(id) }
    }
}
