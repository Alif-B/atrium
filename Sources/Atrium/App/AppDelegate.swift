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
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Atrium's window overlaps the snapped app's area, so activating Atrium (e.g. clicking the rail) would cover that app.
    /// Lift the snapped app back above it, unless one of Atrium's own secondary windows is what the user is using.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard snapper != nil, let id = store.activeBundleID, let running = Launcher.runningApp(bundleID: id),
              snapper?.snappedPIDs.contains(running.processIdentifier) == true else { return }
        let secondaryVisible = [addAppsWindow?.window, settingsWindow?.window].contains { $0?.isVisible == true }
        guard !secondaryVisible else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            self.snapper?.raiseSnapped(pid: running.processIdentifier)
        }
    }

    /// Dock-icon click brings the main window back (it can be closed with ⌘W without quitting).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sidebar.show()
        switcher?.bringLastActiveForward()
        return false
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
            snapper?.raiseSnapped(pid: pid)
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
