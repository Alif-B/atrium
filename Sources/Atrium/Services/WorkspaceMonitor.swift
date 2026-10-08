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

    init(store: AppStore, prefs: Preferences, switcher: AppSwitcher, onManagedActivated: @escaping @MainActor (String) -> Void) {
        self.store = store
        self.prefs = prefs
        self.switcher = switcher
        self.onManagedActivated = onManagedActivated

        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        store.runningBundleIDs = Set(running)
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
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] id in
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
