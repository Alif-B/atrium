import AppKit
import OSLog
import AtriumCore

private let log = Logger(subsystem: "com.alif.atrium", category: "switcher")

/// Handles a sidebar click: launch/activate the app and keep the UI honest about what actually happened.
@MainActor
final class AppSwitcher {
    private let store: AppStore
    private let prefs: Preferences
    private var task: Task<Void, Never>?
    /// The app a sidebar-initiated switch is currently working on (WorkspaceMonitor uses it to avoid double handling).
    private(set) var inFlightBundleID: String?

    init(store: AppStore, prefs: Preferences) {
        self.store = store
        self.prefs = prefs
    }

    func switchTo(_ app: ManagedApp) {
        guard let url = store.resolvedURL(for: app) else { return }
        let id = app.bundleIdentifier
        task?.cancel()
        inFlightBundleID = id
        store.activeBundleID = id                       // the lens starts moving on this frame
        prefs.lastActiveBundleID = id
        if Launcher.runningApp(bundleID: id) == nil { store.launchingBundleIDs.insert(id) }
        task = Task { await run(id: id, url: url) }
    }

    func bringLastActiveForward() {
        guard let id = prefs.lastActiveBundleID, let app = store.apps.first(where: { $0.bundleIdentifier == id }) else { return }
        switchTo(app)
    }

    private func run(id: String, url: URL) async {
        defer { if inFlightBundleID == id { inFlightBundleID = nil } }

        // Atrium is the active app after a click on its window; yield so the target can take over.
        if NSApp.isActive, let running = Launcher.runningApp(bundleID: id) { NSApp.yieldActivation(to: running) }

        let running: NSRunningApplication
        do {
            running = try await Launcher.open(url)
            log.debug("opened \(id, privacy: .public) via openApplication")
        } catch {
            log.error("open failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            store.launchingBundleIDs.remove(id)
            return
        }

        // Fallback: activation from a background request can be ignored on macOS 14+.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
            log.debug("not frontmost after openApplication; activate(options:) for \(id, privacy: .public)")
            running.activate(options: [.activateAllWindows])
        }

        // Reconcile: after a second, show what is really in front.
        try? await Task.sleep(for: .milliseconds(750))
        guard !Task.isCancelled else { return }
        reconcile()

        try? await Task.sleep(for: .seconds(9))
        guard !Task.isCancelled else { return }
        store.launchingBundleIDs.remove(id)
    }

    private func reconcile() {
        guard let front = NSWorkspace.shared.frontmostApplication, let frontID = front.bundleIdentifier else { return }
        if frontID == Bundle.main.bundleIdentifier { return }        // Atrium itself: leave as is
        let managed = store.apps.contains { $0.bundleIdentifier == frontID }
        if !managed || store.activeBundleID != frontID {
            log.debug("reconcile: frontmost is \(frontID, privacy: .public)")
        }
        store.activeBundleID = managed ? frontID : nil
    }
}
