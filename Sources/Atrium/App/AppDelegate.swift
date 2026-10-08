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
    private var badgeMonitor: BadgeMonitor?
    private var hibernation: HibernationMonitor?
    private var orderCache: (slot: String, number: Int, at: Date)?
    private var webApps: WebAppManager?
    private var addAppsWindow: HostingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var editWebAppWindow: HostingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let spec = LaunchOptions.debugIcon {
            let parts = spec.split(separator: ":").map(String.init)      // input:output[:scale]
            let scale = parts.count > 2 ? Double(parts[2]) ?? SiteIconFetcher.defaultScale : SiteIconFetcher.defaultScale
            Task { @MainActor in
                if parts.count >= 2, let image = NSImage(contentsOfFile: parts[0]),
                   let saved = SiteIconFetcher.saveCustom(source: image, scale: scale, id: "debug-icon") {
                    try? FileManager.default.copyItem(atPath: saved.icon, toPath: parts[1])
                    try? FileManager.default.removeItem(atPath: saved.icon)
                    try? FileManager.default.removeItem(atPath: saved.source)
                }
                NSApp.terminate(nil)
            }
            return
        }
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
            hide: { [weak self] app in
                if app.isWebApp { self?.webApps?.minimize(app) } else { Launcher.runningApp(bundleID: app.bundleIdentifier)?.hide() }
            },
            quit: { [weak self] app in
                if app.isWebApp { self?.webApps?.closeWindow(app) } else { Launcher.runningApp(bundleID: app.bundleIdentifier)?.terminate() }
            },
            reload: { [weak self] app in self?.webApps?.reload(app) },
            edit: { [weak self] app in self?.showEditWebApp(app) })
        sidebar = SidebarController(store: store, prefs: prefs, actions: actions)
        sidebar.show()
        if !LaunchOptions.demo {
            let snapper = WindowSnapper(store: store, workspaceRect: { [weak self] in self?.sidebar.workspaceRect ?? .zero })
            self.snapper = snapper
            switcher = AppSwitcher(store: store, prefs: prefs, snapper: snapper)
            let webApps = WebAppManager(store: store, prefs: prefs, snapper: snapper)
            self.webApps = webApps
            switcher.openWebApp = { app in webApps.open(app) }
            webApps.onWebAppFocused = { [weak self] slot in self?.managedAppActivated(slot) }
            snapper.onWindowGone = { [weak self] slot in
                if slot.hasPrefix(ManagedApp.webAppIDPrefix) { self?.store.runningBundleIDs.remove(slot) }
            }
            permissions = PermissionMonitor(store: store)
            badgeMonitor = BadgeMonitor(store: store, prefs: prefs, snapper: snapper)
            hibernation = HibernationMonitor(store: store, closeWebApp: { app in webApps.closeWindow(app) })
            workspace = WorkspaceMonitor(
                store: store, prefs: prefs, switcher: switcher,
                onManagedActivated: { [weak self] id in self?.managedAppActivated(id) },
                onTerminated: { [weak self] pid in
                    self?.snapper?.appTerminated(pid: pid)
                    self?.webApps?.browserTerminated(pid: pid)
                })
            workspace?.slotResolver = { id in
                webApps.hostsWebApps(id) ? webApps.resolveFocusedSlot(browserBundleID: id) : nil
            }
            sidebar.onFrameChange = { [weak self] in
                self?.snapper?.follow()
                self?.keepWorkspaceVisible()          // a drag may have started with Atrium raised above the app
            }
            sidebar.onBecameKey = { [weak self] in self?.keepWorkspaceVisible(restoreLast: true, fresh: true) }
            sidebar.window.onMouseDown = { [weak self] in self?.keepWorkspaceVisible(restoreLast: true, fresh: true) }
            snapper.onSnapped = { [weak self] in self?.keepWorkspaceVisible() }
            if let id = LaunchOptions.debugFollow { runFollowDiagnostic(bundleID: id) } else { preloadAll() }
            if LaunchOptions.debugSettings { showSettings() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Atrium's window and the snapped app's window overlap. Whenever Atrium is brought forward (a click, a drag, the Dock),
    /// put it back directly *under* the snapped app's window, so the app stays visible inside Atrium ("sticky").
    func applicationDidBecomeActive(_ notification: Notification) { keepWorkspaceVisible(restoreLast: true, fresh: true) }

    /// - restoreLast: Atrium was just clicked. If no sidebar app is current (the last thing used was some other app),
    ///   fall back to the workspace's last app instead of leaving Atrium's empty area on top of everything.
    /// - fresh: look the window up again rather than reuse a number found in the last second.
    func keepWorkspaceVisible(restoreLast: Bool = false, fresh: Bool = false) {
        guard let snapper else { return }
        var id = store.activeBundleID
        if restoreLast, id.map({ !snapper.isPlaced($0) }) ?? true,
           let last = prefs.lastActiveBundleID, snapper.isPlaced(last) {
            id = last
            store.activeBundleID = last
        }
        guard let id, snapper.isPlaced(id) else { return }
        // CGWindowList is ~1 ms; during drags this runs at up to 60 Hz, so reuse the number for a second.
        var number: Int?
        if !fresh, let cached = orderCache, cached.slot == id, Date().timeIntervalSince(cached.at) < 1 { number = cached.number }
        if number == nil, let found = snapper.windowNumber(slot: id) {
            orderCache = (id, found, Date())
            number = found
        }
        if let number {
            sidebar.window.order(.below, relativeTo: number)
        } else {
            snapper.raise(slot: id)          // couldn't find its number: lift the window itself above Atrium
        }
    }

    /// Dock-icon click brings the main window back (it can be closed with ⌘W without quitting).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sidebar.show()
        switcher?.bringLastActiveForward()
        return false
    }

    // MARK: Startup

    /// Pull every sidebar app into Atrium at launch, so the first click on each one is instant:
    /// running apps are placed quietly behind, closed apps are launched in the background, web apps get (or re-find)
    /// their windows. Finally the last-used app comes to the front.
    private func preloadAll() {
        guard store.isAXTrusted, let snapper, let webApps else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))      // let the window and monitors settle
            // Native apps in parallel (each may wait for its window), then web apps one by one.
            var jobs: [Task<Void, Never>] = []
            // Apps set to hibernate aren't started at launch: they start when first clicked.
            for app in store.apps where !app.isWebApp && app.snapWindow && !app.hibernates {
                guard let url = store.resolvedURL(for: app) else { continue }
                let id = app.bundleIdentifier
                jobs.append(Task { @MainActor in
                    var running = Launcher.runningApp(bundleID: id)
                    let launching = running == nil
                    if launching { running = try? await Launcher.open(url, activate: false) }
                    guard let pid = running?.processIdentifier else { return }
                    await snapper.snapAndWait(slot: id, pid: pid, launching: launching, raise: false)
                })
            }
            for job in jobs { await job.value }
            await webApps.preload(store.apps)
            log.notice("startup preload finished")
            switcher.bringLastActiveForward()
        }
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
            if LaunchOptions.debugEmptyClick {
                store.activeBundleID = nil                     // the last thing used was some other app
                log.notice("diag: no active app; Atrium forced to FRONT")
                sidebar.window.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(3))
                log.notice("diag: simulated click on the empty area")
                keepWorkspaceVisible(restoreLast: true, fresh: true)
                return
            }
            if LaunchOptions.debugOrder {
                // Two rounds of "Atrium raised above the app, then moved" (what a repeated drag does).
                for round in 1...2 {
                    store.activeBundleID = bundleID      // ignore unrelated activations during the diagnostic
                    log.notice("diag: round \(round): Atrium to FRONT")
                    sidebar.window.orderFrontRegardless()
                    try? await Task.sleep(for: .seconds(2))
                    var f = sidebar.window.frame
                    f.origin.x += 40
                    store.activeBundleID = bundleID
                    sidebar.window.setFrame(f, display: true)
                    log.notice("diag: round \(round): moved")
                    try? await Task.sleep(for: .seconds(2))
                }
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
        guard let app = store.apps.first(where: { $0.bundleIdentifier == id }) else { return }
        sidebar.window.orderFrontRegardless()
        if snapper?.isPlaced(id) == true || app.isWebApp || !prefs.snapOnSwitch || !app.snapWindow {
            keepWorkspaceVisible()
            return
        }
        guard let running = Launcher.runningApp(bundleID: id) else { return }
        snapper?.snap(slot: id, pid: running.processIdentifier, launching: false)
    }

    private func handleClick(_ app: ManagedApp) {
        if store.isMissing(app) { locate(app); return }
        if let switcher { switcher.switchTo(app) } else { store.activeBundleID = app.bundleIdentifier }   // demo: lens only
    }

    @objc private func openSettings() { showSettings() }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store, prefs: prefs, previewSound: { [weak self] name in self?.badgeMonitor?.preview(soundNamed: name) }, showAddApps: { [weak self] in self?.showAddApps() },
                                                      editWebApp: { [weak self] app in self?.showEditWebApp(app) })
        }
        settingsWindow?.present()
    }

    private func showEditWebApp(_ app: ManagedApp) {
        editWebAppWindow?.dismiss()
        let done: @MainActor () -> Void = { [weak self] in self?.editWebAppWindow?.dismiss() }
        let controller = app.isWebApp
            ? HostingWindowController(title: "Edit \(app.displayName)", size: NSSize(width: 460, height: 420), transparentTitlebar: false,
                                      rootView: EditWebAppView(store: store, app: app, onDone: done))
            : HostingWindowController(title: "Edit \(app.displayName)", size: NSSize(width: 440, height: 240), transparentTitlebar: false,
                                      rootView: EditAppView(store: store, app: app, onDone: done))
        editWebAppWindow = controller
        controller.present()
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
