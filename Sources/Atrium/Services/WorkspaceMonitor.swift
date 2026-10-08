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
    private var pidByBundleID: [String: pid_t] = [:]
    private let onTerminated: @MainActor (pid_t) -> Void

    init(store: AppStore, prefs: Preferences, switcher: AppSwitcher, onManagedActivated: @escaping @MainActor (String) -> Void,
         onTerminated: @escaping @MainActor (pid_t) -> Void) {
        self.onTerminated = onTerminated
        self.store = store
        self.prefs = prefs
        self.switcher = switcher
        self.onManagedActivated = onManagedActivated

        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps { if let id = app.bundleIdentifier { pidByBundleID[id] = app.processIdentifier } }
        store.runningBundleIDs = Set(runningApps.compactMap(\.bundleIdentifier))
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { handleActivate(front) }

        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: NSNotification.Name, _ handler: @escaping @MainActor (String) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Extract Sendable values before hopping into the main-actor closure.
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { if let id { handler(id) } }
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] id in
            self?.store.runningBundleIDs.insert(id)
            self?.store.launchingBundleIDs.remove(id)
            if let app = Launcher.runningApp(bundleID: id) { self?.pidByBundleID[id] = app.processIdentifier }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] id in
            if let pid = self?.pidByBundleID[id] { self?.onTerminated(pid) }
            self?.store.runningBundleIDs.remove(id)
            self?.store.launchingBundleIDs.remove(id)
            self?.store.badges[id] = nil
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] id in self?.handleActivate(id) }
    }

    private func handleActivate(_ id: String) {
        if id == Bundle.main.bundleIdentifier { return }                     // clicking Atrium's own window: leave state alone
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
