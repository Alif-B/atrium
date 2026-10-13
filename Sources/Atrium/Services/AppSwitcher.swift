import AppKit
import OSLog
import AtriumCore

private let log = Logger(subsystem: "com.alif.atrium", category: "switcher")

/// Handles a sidebar click: launch/activate the app and keep the UI honest about what actually happened.
@MainActor
final class AppSwitcher {
    private let store: AppStore
    private let prefs: Preferences
    private let snapper: WindowSnapper
    private var promptedForAccessibility = false
    private var task: Task<Void, Never>?
    /// The app a sidebar-initiated switch is currently working on (WorkspaceMonitor uses it to avoid double handling).
    private(set) var inFlightBundleID: String?
    /// Web apps are opened by WebAppManager (their own browser window), not by launching a bundle.
    var openWebApp: (@MainActor (ManagedApp) -> Void)?
    /// After an app's window was brought forward: put Atrium back right under it.
    var onShown: (@MainActor () -> Void)?
    /// Just before the visible app changes (for the crossfade): the app that's leaving.
    var onWillSwitch: (@MainActor (_ from: String?) -> Void)?

    init(store: AppStore, prefs: Preferences, snapper: WindowSnapper) {
        self.store = store
        self.prefs = prefs
        self.snapper = snapper
    }

    func switchTo(_ app: ManagedApp) {
        if app.isWebApp { task?.cancel(); openWebApp?(app); return }
        guard let url = store.resolvedURL(for: app) else { return }
        let id = app.bundleIdentifier
        task?.cancel()
        if bringForwardIfLoaded(app) { return }
        inFlightBundleID = id
        store.activeBundleID = id                       // the lens starts moving on this frame
        prefs.lastActiveBundleID = id
        let wasRunning = Launcher.runningApp(bundleID: id) != nil
        if !wasRunning { store.launchingBundleIDs.insert(id) }
        if prefs.snapOnSwitch, app.snapWindow, !store.isAXTrusted, !promptedForAccessibility {
            promptedForAccessibility = true            // the system dialog offers to open System Settings; ask once per launch
            _ = AX.isTrusted(prompt: true)
        }
        let snap = prefs.snapOnSwitch && app.snapWindow
        task = Task { await run(id: id, url: url, wasRunning: wasRunning, snap: snap) }
    }

    /// The fast path. When the app is already running and its window already sits in Atrium, just lift that window and
    /// hand focus to the app. No relaunch request: asking macOS to "open" a running app sends it a reopen event (Electron
    /// apps re-show their window, which looks like a reload) and brings every one of its windows forward.
    private func bringForwardIfLoaded(_ app: ManagedApp) -> Bool {
        let id = app.bundleIdentifier
        guard let running = Launcher.runningApp(bundleID: id), let window = snapper.placedWindow(id), AX.frame(window) != nil
        else { return false }
        if store.activeBundleID != id { onWillSwitch?(store.activeBundleID) }
        store.activeBundleID = id
        prefs.lastActiveBundleID = id
        if AX.bool(window, kAXMinimizedAttribute) == true { AX.set(window, kAXMinimizedAttribute, false as CFBoolean) }
        AX.raise(window)                                  // its own front window, so activation brings exactly this one
        onShown?()                                        // Atrium straight under it, before the app takes focus
        AX.makeFrontmost(running.processIdentifier)
        if NSApp.isActive { NSApp.yieldActivation(to: running) }
        running.activate()
        onShown?()
        // If macOS ignored the activation, fall back to the full path once.
        task = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, store.activeBundleID == id,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier else { return }
            log.debug("fast switch didn't take for \(id, privacy: .public); using the full path")
            if let url = store.resolvedURL(for: app) {
                inFlightBundleID = id
                await run(id: id, url: url, wasRunning: true, snap: prefs.snapOnSwitch && app.snapWindow)
            }
        }
        return true
    }

    func bringLastActiveForward() {
        guard let id = prefs.lastActiveBundleID, let app = store.apps.first(where: { $0.bundleIdentifier == id }) else { return }
        switchTo(app)
    }

    private func run(id: String, url: URL, wasRunning: Bool, snap: Bool) async {
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

        if snap { snapper.snap(slot: id, pid: running.processIdentifier, launching: !wasRunning) }

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
