import AppKit
import SwiftUI
import OSLog
import AtriumCore

private let log = Logger(subsystem: "com.alif.atrium", category: "switcher")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prefs: Preferences!
    private var store: AppStore!
    private var sidebar: SidebarController!
    private var switcher: AppSwitcher!
    private var snapper: WindowSnapper?
    private var workspace: WorkspaceMonitor?
    private var permissions: PermissionMonitor?
    private var addAppsWindow: HostingWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(settingsTarget: self, settingsAction: #selector(openSettings))
        prefs = Preferences()
        store = LaunchOptions.demo ? AppStore.demo() : AppStore.persistent()
        let actions = SidebarActions(
            switchTo: { [weak self] app in self?.handleClick(app) },
            showAddApps: { [weak self] in self?.showAddApps() },
            showSettings: { [weak self] in self?.showSettings() },
            locate: { [weak self] app in self?.locate(app) },
            showInFinder: { [weak self] app in
                if let url = self?.store.resolvedURL(for: app) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            remove: { [weak self] app in self?.store.remove(bundleID: app.bundleIdentifier) },
            hide: { app in Launcher.runningApp(bundleID: app.bundleIdentifier)?.hide() },
            quit: { app in Launcher.runningApp(bundleID: app.bundleIdentifier)?.terminate() })
        sidebar = SidebarController(store: store, prefs: prefs, actions: actions)
        sidebar.show()
        if !LaunchOptions.demo {
            let snapper = WindowSnapper(store: store, workspaceRect: { [weak self] in self?.sidebar.workspaceRect ?? .zero })
            self.snapper = snapper
            switcher = AppSwitcher(store: store, prefs: prefs, snapper: snapper)
            permissions = PermissionMonitor(store: store)
            workspace = WorkspaceMonitor(
                store: store, prefs: prefs, switcher: switcher,
                onManagedActivated: { [weak self] id in self?.managedAppActivated(id) },
                onTerminated: { [weak self] pid in self?.snapper?.appTerminated(pid: pid) })
            sidebar.onFrameChange = { [weak self] in self?.snapper?.follow() }
            sidebar.onBecameKey = { [weak self] in self?.keepWorkspaceVisible() }
            snapper.onSnapped = { [weak self] in self?.keepWorkspaceVisible() }
            if let id = LaunchOptions.debugFollow { runFollowDiagnostic(bundleID: id) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Atrium's window and the snapped app's window overlap. Whenever Atrium is brought forward (a click, a drag, the Dock),
    /// put it back directly *under* the snapped app's window, so the app stays visible inside Atrium ("sticky").
    func applicationDidBecomeActive(_ notification: Notification) { keepWorkspaceVisible() }

    func keepWorkspaceVisible() {
        guard snapper != nil, let id = store.activeBundleID, let pid = Launcher.runningApp(bundleID: id)?.processIdentifier,
              snapper?.snappedPIDs.contains(pid) == true, let number = snapper?.windowNumber(pid: pid) else { return }
        sidebar.window.order(.below, relativeTo: number)
    }

    /// Dock-icon click brings the main window back (it can be closed with ⌘W without quitting).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sidebar.show()
        switcher?.bringLastActiveForward()
        return false
    }

    // MARK: Diagnostics

    /// Developer aid: opens an app, then nudges Atrium's window so the follow behaviour can be observed from outside.
    private func runFollowDiagnostic(bundleID: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let app = store.apps.first(where: { $0.bundleIdentifier == bundleID }) else { log.notice("diag: app not in sidebar"); return }
            log.notice("diag: switching to \(bundleID, privacy: .public)")
            switcher.switchTo(app)
            try? await Task.sleep(for: .seconds(6))
            if LaunchOptions.debugOrder {
                log.notice("diag: ordering Atrium to FRONT (simulated click)")
                sidebar.window.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(3))
                log.notice("diag: keepWorkspaceVisible()")
                keepWorkspaceVisible()
                return
            }
            for step in 1...10 {
                var f = sidebar.window.frame
                f.origin.x += 20
                sidebar.window.setFrame(f, display: true)
                log.notice("diag: moved Atrium to \(NSStringFromRect(f), privacy: .public) step \(step)")
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Actions

    /// A managed app came forward from somewhere else (⌘-Tab, Dock, its own window): snap it once, and keep Atrium's
    /// rail visible next to it.
    private func managedAppActivated(_ id: String) {
        guard let app = store.apps.first(where: { $0.bundleIdentifier == id }),
              let running = Launcher.runningApp(bundleID: id) else { return }
        let pid = running.processIdentifier
        sidebar.window.orderFrontRegardless()
        if prefs.snapOnSwitch, app.snapWindow, snapper?.snappedPIDs.contains(pid) == false {
            snapper?.snap(pid: pid, launching: false)
        } else {
            keepWorkspaceVisible()
        }
    }

    private func handleClick(_ app: ManagedApp) {
        if store.isMissing(app) { locate(app); return }
        if let switcher { switcher.switchTo(app) } else { store.activeBundleID = app.bundleIdentifier }   // demo: lens only
    }

    @objc private func openSettings() { showSettings() }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store, showAddApps: { [weak self] in self?.showAddApps() })
        }
        settingsWindow?.present()
    }

    private func showAddApps() {
        if addAppsWindow == nil {
            addAppsWindow = HostingWindowController(
                title: "Add Apps", size: NSSize(width: 600, height: 560), transparentTitlebar: true,
                rootView: AddAppsView(store: store, onDone: { [weak self] in self?.addAppsWindow?.dismiss() }))
        }
        addAppsWindow?.present()
    }

    /// Lets the user point at a moved app; updates `lastKnownPath`.
    private func locate(_ app: ManagedApp) {
        let panel = NSOpenPanel()
        panel.message = "Locate \(app.displayName)"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.update(bundleID: app.bundleIdentifier) { $0.lastKnownPath = url.path }
    }
}
