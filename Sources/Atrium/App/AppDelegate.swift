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
    private var resizeSettleTask: Task<Void, Never>?
    private var permissions: PermissionMonitor?
    private var badgeMonitor: BadgeMonitor?
    private var hibernation: HibernationMonitor?
    private let snapshotter = WindowSnapshotter()
    private var mover: MoveCoordinator?
    private let missionControl = MissionControlMonitor()
    private var workDone = false
    private var appObservers: [NSObjectProtocol] = []
    private var healTimer: Task<Void, Never>?

    private func healSoon(_ reason: String) {
        Task { @MainActor in
            for delay in [2, 6] {
                try? await Task.sleep(for: .seconds(delay))
                heal(reason)
            }
        }
    }
    private let crossfade = CrossfadePanel()
    private var orderCache: (slot: String, number: Int, at: Date)?
    private var webHost: WebAppHost?
    private var notifier: WebNotifier?
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
        NSApp.mainMenu = MainMenu.build(settingsTarget: self, settingsAction: #selector(openSettings), web: self)
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
            hide: { app in if !app.isWebApp { Launcher.runningApp(bundleID: app.bundleIdentifier)?.hide() } },
            quit: { [weak self] app in
                if app.isWebApp { self?.closeWebApp(app) } else { Launcher.runningApp(bundleID: app.bundleIdentifier)?.terminate() }
            },
            reload: { [weak self] app in self?.reload(app) },
            edit: { [weak self] app in self?.showEditWebApp(app) })
        sidebar = SidebarController(store: store, prefs: prefs, actions: actions)
        sidebar.show()
        if !LaunchOptions.demo {
            let snapper = WindowSnapper(store: store, workspaceRect: { [weak self] in self?.sidebar.workspaceRect ?? .zero })
            self.snapper = snapper
            switcher = AppSwitcher(store: store, prefs: prefs, snapper: snapper)
            let webHost = WebAppHost(store: store)
            self.webHost = webHost
            sidebar.installWebContainer(webHost.container)
            sidebar.window.isOverWebContent = { [weak webHost] point in webHost?.hasContent(at: point) ?? false }
            sidebar.window.onWebContentMouseDown = { [weak self] in self?.webContentClicked() }
            switcher.openWebApp = { [weak self] app in self?.showWebApp(app) }
            store.onActiveChange = { [weak webHost] id in webHost?.activeChanged(id) }
            store.onAppsChanged = { [weak webHost] in webHost?.syncApps() }
            webHost.onReady = { [weak self] id in
                guard let self else { return }
                if self.store.emptyState == .opening(id) { self.store.emptyState = nil }
                if self.store.activeBundleID == id { self.bringWebForward() }
            }
            webHost.onFailed = { [weak self] id in
                if self?.store.activeBundleID == id { self?.store.emptyState = .failed(id) }
            }
            let notifier = WebNotifier()
            self.notifier = notifier
            webHost.onNotification = { [weak self] app, title, body, noteID in self?.webNotification(app, title: title, body: body, noteID: noteID) }
            notifier.onClick = { [weak self] id, noteID in self?.webNotificationClicked(id, noteID: noteID) }
            snapper.onWindowGone = { [weak self] slot in
                log.notice("window gone: \(slot, privacy: .public); active \(self?.store.activeBundleID ?? "none", privacy: .public)")
            }
            snapper.onUserResize = { [weak self] _, axFrame in self?.appResizedByUser(axFrame) }
            permissions = PermissionMonitor(store: store)
            badgeMonitor = BadgeMonitor(store: store, prefs: prefs, webTitle: { [weak webHost] id in webHost?.title(of: id) })
            hibernation = HibernationMonitor(store: store, closeWebApp: { [weak self] app in self?.closeWebApp(app) ?? false },
                                             webAppBusy: { [weak webHost] id in webHost?.isBusy(id) ?? false },
                                             idleLimit: LaunchOptions.debugHibernateSeconds.map(TimeInterval.init) ?? Hibernation.idleLimit)
            workspace = WorkspaceMonitor(
                store: store, prefs: prefs, switcher: switcher,
                onManagedActivated: { [weak self] id in self?.managedAppActivated(id) },
                onTerminated: { [weak self] pid in
                    self?.snapper?.appTerminated(pid: pid)
                })
            let mover = MoveCoordinator(store: store, snapper: snapper, sidebar: sidebar, snapshotter: snapshotter)
            self.mover = mover
            mover.onSettled = { [weak self] in self?.keepWorkspaceVisible(fresh: true) }
            mover.shownSlot = { [weak self] in self?.shownSlot }
            sidebar.onMoveBegan = { mover.began() }
            sidebar.onMoveEnded = { mover.ended() }
            sidebar.onWillMinimize = { mover.conceal(.minimized) }
            sidebar.onDidDeminiaturize = { mover.reveal(.minimized) }
            sidebar.onWillClose = { mover.conceal(.closed) }
            sidebar.onShown = { mover.reveal(.closed) }
            let center = NotificationCenter.default
            appObservers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { mover.conceal(.appHidden) }
            })
            appObservers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { mover.reveal(.appHidden) }
            })
            sidebar.onPointerEnteredRail = { [weak self] in self?.refreshSnapshot() }
            sidebar.onFrameChange = { [weak self] in
                guard self?.mover?.isMoving != true else { return }   // apps are hidden while moving
                self?.snapper?.follow()
                self?.keepWorkspaceVisible()
            }
            workspace?.isSuspended = { mover.isMoving }
            missionControl.isWanted = { [weak self] in
                guard let self, let snapper = self.snapper else { return false }
                return self.sidebar.window.isVisible && !self.sidebar.window.isMiniaturized && snapper.hasPlacedWindows
            }
            missionControl.onChange = { [weak self] open in
                self?.sidebar.railHidden = open                           // one tile: the window, without a separate rail
                if open { mover.missionControlOpened() } else { mover.missionControlClosed() }
            }
            missionControl.start()
            switcher.onWillSwitch = { [weak self] from in self?.crossfadeAway(from: from) }
            sidebar.onBecameKey = { [weak self] in self?.keepWorkspaceVisible(restoreLast: true, fresh: true) }
            sidebar.onCheckOrder = { [weak self] in self?.keepWorkspaceVisible(fresh: true) }
            switcher.onShown = { [weak self] in
                self?.keepWorkspaceVisible(fresh: true)
                self?.refreshSnapshotSoon()
            }
            sidebar.onMainMouseDown = { [weak self] in self?.keepWorkspaceVisible(restoreLast: true, fresh: true) }
            snapper.onSnapped = { [weak self] in
                // The app's window arrived: the opening card goes away underneath it.
                if let self, case .opening(let id)? = self.store.emptyState, self.snapper?.isPlaced(id) == true { self.store.emptyState = nil }
                self?.keepWorkspaceVisible()
            }
            switcher.onOpening = { [weak self] id, from in self?.showOpening(id, from: from) }
            // Self-repair after wake and display changes (twice: things settle in stages), and every 30 s.
            let wsCenter = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                appObservers.append(wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.healSoon("wake") }
                })
            }
            appObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                        object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.healSoon("displays changed") }
            })
            healTimer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30), tolerance: .seconds(5))
                    self?.heal("routine check")
                    if self?.mover?.isMoving != true { self?.refreshSnapshot() }     // Mission Control shows it
                }
            }
            workspace?.onShownAppGone = { [weak self] id in self?.shownAppGone(id) }
            if let dir = LaunchOptions.debugJSDir { preloadAll(); runJSConsole(dir) } else if LaunchOptions.debugDnD { runDnDDiagnostic() } else if LaunchOptions.debugWeb { runWebDiagnostic() } else if LaunchOptions.debugResize {
                _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { e in
                    if e.type == .leftMouseDown {
                        log.notice("app got \(e.type.rawValue) in \(e.window.map { String(describing: type(of: $0)) } ?? "no window", privacy: .public) at \(NSStringFromPoint(e.locationInWindow), privacy: .public)")
                    }
                    return e
                }
                Task { @MainActor in
                    preloadAll()
                    try? await Task.sleep(for: .seconds(16))
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    if let vis = self.sidebar.window.screen?.visibleFrame {
                        self.sidebar.window.setFrame(CGRect(x: vis.midX - 450, y: vis.midY - 350, width: 900, height: 700), display: true)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    // Inside the 8 pt margin, where the app's own outer resize zone takes the drag.
                    for (label, dx, dy) in [("bottom@6", 0.0, 40.0), ("right@6", -80.0, 0.0), ("top@6", 0.0, -30.0),
                                            ("corner-br@5", 40.0, 40.0), ("left@2", -60.0, 0.0), ("top@7", 0.0, -20.0)] {
                        let f = self.sidebar.window.frame
                        let x: CGFloat, y: CGFloat
                        switch label {
                        case "bottom@6": (x, y) = (f.midX, top - f.minY - 6)
                        case "right@6": (x, y) = (f.maxX - 6, top - f.midY)
                        case "top@6": (x, y) = (f.midX, top - f.maxY + 6)
                        case "corner-br@5": (x, y) = (f.maxX - 6, top - f.minY - 6)     // outside the curve, Atrium in front
                        case "top@7": (x, y) = (f.midX, top - f.maxY + 7)
                        default: (x, y) = (f.minX + 2, top - f.midY)
                        }
                        log.notice("diag resize \(label, privacy: .public): before \(NSStringFromRect(f), privacy: .public)")
                        // "@6": the app in front, as in normal use (its outer resize zone takes the drag); otherwise Atrium.
                        if label.hasSuffix("@6") { self.keepWorkspaceVisible(fresh: true) } else { self.sidebar.stayInFront() }
                        try? await Task.sleep(for: .milliseconds(300))
                        let probe = CGPoint(x: x, y: y)
                        let owner = ClickDiagnostic.frontOwner(at: probe, atrium: self.sidebar.window.windowNumber)
                        let all = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { w -> String? in
                            guard let b = w[kCGWindowBounds as String] as? [String: Double],
                                  CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!).contains(probe) else { return nil }
                            return "\(w[kCGWindowOwnerName as String] ?? "?")[L\(w[kCGWindowLayer as String] ?? "")] \(Int(b["Y"]!))+\(Int(b["Height"]!))"
                        }.prefix(4).joined(separator: ", ")
                        log.notice("diag resize \(label, privacy: .public): at \(NSStringFromPoint(probe), privacy: .public) front \(owner, privacy: .public); stack: \(all, privacy: .public)")
                        ClickDiagnostic.drag(from: probe, by: dx, dy: dy) {}
                        try? await Task.sleep(for: .seconds(2))
                        let fitted = self.store.activeBundleID.flatMap { self.snapper?.placedWindow($0) }.flatMap { AX.frame($0) }
                        log.notice("diag resize \(label, privacy: .public): frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-", privacy: .public)")
                        log.notice("diag resize \(label, privacy: .public): after \(NSStringFromRect(self.sidebar.window.frame), privacy: .public); app \(fitted.map { NSStringFromRect($0) } ?? "none", privacy: .public) target \(NSStringFromRect(self.snapper?.axTarget() ?? .zero), privacy: .public)")
                    }
                }
            } else if LaunchOptions.debugHeal {
                Task { @MainActor in
                    preloadAll()
                    try? await Task.sleep(for: .seconds(16))
                    guard let snapper = self.snapper else { return }
                    @MainActor func count() -> (Int, Int) {
                        let t = snapper.axTarget(); var placedN = 0, inPlace = 0
                        for app in self.store.apps {
                            guard let w = snapper.placedWindow(app.bundleIdentifier) else { continue }
                            placedN += 1
                            if let f = AX.frame(w), abs(f.minX - t.minX) < 2, abs(f.minY - t.minY) < 2 { inPlace += 1 }
                        }
                        return (placedN, inPlace)
                    }
                    let before = count()
                    // Nudge two windows out of place, then lose track of everything.
                    var nudged = 0
                    for app in self.store.apps where nudged < 2 {
                        guard let w = snapper.placedWindow(app.bundleIdentifier), let pid = snapper.pid(of: app.bundleIdentifier),
                              var f = AX.frame(w) else { continue }
                        f.origin.x -= 300; f.origin.y += 120
                        AX.setFrame(w, app: AX.app(pid), to: f); nudged += 1
                    }
                    snapper.forgetAllForTesting()
                    log.notice("diag heal: before \(before.0) tracked/\(before.1) in place; nudged \(nudged), now tracking \(count().0)")
                    self.heal("test")
                    try? await Task.sleep(for: .seconds(8))
                    let after = count()
                    log.notice("diag heal: after repair \(after.0) tracked, \(after.1) in place")
                }
            } else if let id = LaunchOptions.debugEmpty {
                Task { @MainActor in
                    preloadAll()
                    try? await Task.sleep(for: .seconds(16))
                    guard let app = store.apps.first(where: { $0.bundleIdentifier == id }) else { return }
                    @MainActor func report(_ label: String) {
                        let ws = self.sidebar.workspaceRect
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        let center = CGPoint(x: ws.midX, y: top - ws.midY)
                        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                        let owner = list.first { w in
                            guard (w[kCGWindowLayer as String] as? Int) == 0, let b = w[kCGWindowBounds as String] as? [String: Double] else { return false }
                            return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!).contains(center) && (b["Width"] ?? 0) > 300
                        }.flatMap { $0[kCGWindowOwnerName as String] as? String } ?? "none"
                        log.notice("diag empty \(label, privacy: .public): card \(String(describing: self.store.emptyState), privacy: .public); in front: \(owner, privacy: .public)")
                    }
                    switcher.switchTo(app); try? await Task.sleep(for: .seconds(2)); report("shown")
                    self.closeWebApp(app); try? await Task.sleep(for: .seconds(1.5)); report("window closed")
                    switcher.switchTo(app); try? await Task.sleep(for: .milliseconds(60)); report("reopen clicked")
                    try? await Task.sleep(for: .seconds(4)); report("a few seconds later")
                }
            } else if LaunchOptions.debugPresence {
                Task { @MainActor in
                    preloadAll()
                    try? await Task.sleep(for: .seconds(16))
                    @MainActor func report(_ label: String) {
                        guard let snapper = self.snapper else { return }
                        let target = snapper.axTarget()
                        var shown = 0, hidden = 0, inPlace = 0
                        for pid in snapper.placedPIDs {
                            if NSRunningApplication(processIdentifier: pid)?.isHidden == true { hidden += 1 } else { shown += 1 }
                        }
                        for app in self.store.apps {
                            if let w = snapper.placedWindow(app.bundleIdentifier), let f = AX.frame(w),
                               abs(f.minX - target.minX) < 2, abs(f.minY - target.minY) < 2 { inPlace += 1 }
                        }
                        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                        log.notice("diag presence \(label, privacy: .public): Atrium visible \(self.sidebar.window.isVisible); apps shown \(shown), hidden \(hidden); windows in place \(inPlace); front \(front, privacy: .public)")
                    }
                    report("start")
                    self.sidebar.window.performMiniaturize(nil); try? await Task.sleep(for: .seconds(2)); report("minimized (⌘M)")
                    self.sidebar.window.deminiaturize(nil); try? await Task.sleep(for: .seconds(2)); report("restored")
                    self.sidebar.window.performClose(nil); try? await Task.sleep(for: .seconds(1.5)); report("closed (⌘W)")
                    self.sidebar.show(); try? await Task.sleep(for: .seconds(1.5)); report("reopened")
                    NSApp.hide(nil); try? await Task.sleep(for: .seconds(1.5)); report("Atrium hidden")
                    NSApp.unhideWithoutActivation(); try? await Task.sleep(for: .seconds(1.5)); report("Atrium unhidden")
                }
            } else if LaunchOptions.debugPark {
                Task { @MainActor in
                    preloadAll()
                    try? await Task.sleep(for: .seconds(16))
                    guard let snapper = self.snapper else { return }
                    // Hide → move while hidden → unhide: where does the window first appear?
                    if let window = snapper.placedWindow("com.tinyspeck.slackmacgap"), let slack = Launcher.runningApp(bundleID: "com.tinyspeck.slackmacgap") {
                        let start = AX.frame(window) ?? .zero
                        slack.hide()
                        try? await Task.sleep(for: .milliseconds(250))
                        let moved = CGPoint(x: start.minX + 120, y: start.minY)
                        let ok = true
                        AX.setFrame(window, app: AX.app(slack.processIdentifier), to: CGRect(origin: moved, size: start.size))
                        let whileHidden = AX.frame(window).map(NSStringFromRect) ?? "unreadable"
                        log.notice("diag hide: hidden=\(slack.isHidden) set ok=\(ok) frame while hidden \(whileHidden, privacy: .public)")
                        let t0 = Date()
                        slack.unhide()
                        var seen: [String] = []
                        for _ in 0..<12 {
                            let b = ClickDiagnostic.bounds(ofPID: slack.processIdentifier)
                            seen.append("\(Int(Date().timeIntervalSince(t0) * 1000))ms:\(b.map { "\(Int($0.minX))" } ?? "none")")
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                        log.notice("diag unhide (x over time; expected \(Int(moved.x))): \(seen.joined(separator: " "), privacy: .public)")
                        AX.setFrame(window, app: AX.app(slack.processIdentifier), to: snapper.axTarget())
                    }
                    for app in store.apps where false {
                        let id = app.bundleIdentifier
                        guard let window = snapper.placedWindow(id), let pid = snapper.pid(of: id) else { continue }
                        var far = CGPoint(x: 40000, y: 40000)
                        if let v = AXValueCreate(.cgPoint, &far) { AX.set(window, kAXPositionAttribute, v) }
                        try? await Task.sleep(for: .milliseconds(300))
                        let landed = AX.frame(window).map(NSStringFromRect) ?? "?"
                        log.notice("diag park \(app.displayName, privacy: .public) (pid \(pid)): asked (40000,40000), landed \(landed, privacy: .public)")
                        AX.setFrame(window, app: AX.app(pid), to: snapper.axTarget())
                    }
                }
            } else if LaunchOptions.debugDoubleClick {
                Task { @MainActor in
                    for round in 1...2 {
                        try? await Task.sleep(for: .seconds(3))
                        let glass = sidebar.layout.glass
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        let p = CGPoint(x: glass.midX, y: top - (glass.minY + SidebarMetrics.bottomBlockHeight + DesignTokens.sidebarPadding + 12))
                        log.notice("diag dblclick \(round): before \(NSStringFromRect(self.sidebar.window.frame), privacy: .public)")
                        ClickDiagnostic.doubleClick(at: p)
                        try? await Task.sleep(for: .seconds(1.5))
                        log.notice("diag dblclick \(round): after \(NSStringFromRect(self.sidebar.window.frame), privacy: .public)")
                    }
                }
            } else if LaunchOptions.debugDrag { runDragDiagnostic() }
            else if let spec = LaunchOptions.debugClick { runClickDiagnostic(spec) }
            else if let id = LaunchOptions.debugFollow { runFollowDiagnostic(bundleID: id) } else { preloadAll() }
            if LaunchOptions.debugSettings { showSettings() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { mover?.releaseAll() }

    /// Atrium's window and the snapped app's window overlap. Whenever Atrium is brought forward (a click, a drag, the Dock),
    /// put it back directly *under* the snapped app's window, so the app stays visible inside Atrium ("sticky").
    func applicationDidBecomeActive(_ notification: Notification) { keepWorkspaceVisible(restoreLast: true, fresh: true) }

    /// - restoreLast: Atrium was just clicked. If no sidebar app is current (the last thing used was some other app),
    ///   fall back to the workspace's last app instead of leaving Atrium's empty area on top of everything.
    /// - fresh: look the window up again rather than reuse a number found in the last second.
    func keepWorkspaceVisible(restoreLast: Bool = false, fresh: Bool = false) {
        guard let snapper, mover?.isMoving != true else { return }
        var id = store.activeBundleID
        // (Not while a card is up: the selected app is opening, or just quit; that's what Atrium should be showing.)
        if restoreLast, store.emptyState == nil, id.map({ !isShowable($0) }) ?? true,
           let last = prefs.lastActiveBundleID, isShowable(last) {
            id = last
            store.activeBundleID = last
        }
        // A web app shows inside Atrium itself: Atrium belongs in front (when you're using Atrium, or just clicked it).
        if let id, isWebApp(id) {
            guard sidebar.window.isVisible, !sidebar.window.isMiniaturized else { return }
            if let app = store.apps.first(where: { $0.bundleIdentifier == id }), webHost?.isLoaded(id) == false, store.emptyState == nil {
                webHost?.show(app)                                     // e.g. coming back to it after it was closed elsewhere
            }
            let usingAtrium = NSApp.isActive && (NSApp.keyWindow == nil || NSApp.keyWindow === sidebar.window)
            if restoreLast || usingAtrium { bringWebForward() }
            return
        }
        guard let id, snapper.isPlaced(id), sidebar.window.isVisible else { return }
        // During drags this runs at up to 60 Hz: reuse the number found in the last second and skip the order read.
        if !fresh, let cached = orderCache, cached.slot == id, Date().timeIntervalSince(cached.at) < 1 {
            sidebar.placeMain(below: cached.number)
            return
        }
        guard let found = snapper.order(of: id, against: sidebar.window.windowNumber) else {
            if restoreLast { snapper.raise(slot: id) }       // not on screen (e.g. minimized): lift it on a click
            return
        }
        orderCache = (id, found.number, Date())
        // Reorder only when needed: Atrium covering the app, or Atrium left behind other windows while the app is in
        // front (you came back from another app). One read of the window order, nothing more, when all is well.
        if found.atriumInFront || !found.atriumDirectlyBelow { sidebar.placeMain(below: found.number) }
    }

    /// Dock-icon click brings the main window back (it can be closed with ⌘W without quitting).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sidebar.show()
        switcher?.bringLastActiveForward()
        return false
    }

    // MARK: Self-repair

    /// Puts things right quietly: re-attaches sidebar apps that are open but not attached (e.g. after wake, when macOS
    /// briefly couldn't report their windows), and moves everything back in place.
    private func heal(_ reason: String) {
        guard store.isAXTrusted, let snapper, mover?.isMoving != true, !sidebar.isMoving else { return }
        var reattached = 0
        for app in store.apps where !app.isWebApp && app.snapWindow && !snapper.isPlaced(app.bundleIdentifier) {
            guard let running = Launcher.runningApp(bundleID: app.bundleIdentifier), !running.isHidden else { continue }
            snapper.snap(slot: app.bundleIdentifier, pid: running.processIdentifier, launching: false, raise: false, restoreMinimized: false)
            reattached += 1
        }
        snapper.fixPositions()
        keepWorkspaceVisible(fresh: true)
        if reattached > 0 { log.notice("self-repair (\(reason, privacy: .public)): re-attaching \(reattached) app(s)") }
    }

    // MARK: Smoothness

    /// The app on show quit, crashed, hibernated or had its window closed: show its card in front, kindly.
    private func shownAppGone(_ id: String) {
        log.notice("shown app gone: \(id, privacy: .public)")
        store.emptyState = store.recentlyHibernated.remove(id) != nil ? .asleep(id) : .quit(id)
        sidebar.stayInFront()
    }

    /// The app has no window yet: fade from the previous app to Atrium's calm "Opening…" card, in front of it.
    private func showOpening(_ id: String, from previous: String?) {
        if previous != id { crossfadeAway(from: previous) }
        store.emptyState = .opening(id)
        sidebar.stayInFront()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            if store.emptyState == .opening(id) { store.emptyState = .failed(id) }
        }
    }

    /// The app Atrium's workspace shows: the current one, or (while you're in another app) the last one used there.
    private var shownSlot: String? { store.activeBundleID ?? prefs.lastActiveBundleID }

    /// Keep a recent still image of the app on show (used while moving and for the switch crossfade).
    private func refreshSnapshot() {
        guard let snapper, let id = shownSlot, let number = snapper.windowNumber(slot: id) else { return }
        snapshotter.refresh(windowNumber: number, slot: id)
    }

    /// A fresh picture once the app on show has settled (Mission Control and moving show it).
    private func refreshSnapshotSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if self.mover?.isMoving != true { self.refreshSnapshot() }
        }
    }

    /// Fade from the app that's leaving to the one coming in.
    private func crossfadeAway(from slot: String?) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let slot, let snapper, let number = snapper.windowNumber(slot: slot),
              let image = snapshotter.image(forWindow: number, maxAge: 20) else { return }
        crossfade.play(image, frame: sidebar.workspaceRect)
        Task { @MainActor in                                   // and take a fresh one of the new app
            try? await Task.sleep(for: .milliseconds(600))
            self.refreshSnapshot()
        }
    }

    // MARK: Startup

    /// The user is dragging the app's own edge: Atrium follows it live, and once the button is released every other
    /// app is fitted to Atrium's new size.
    private func appResizedByUser(_ axFrame: CGRect) {
        guard mover?.isMoving != true, let primary = NSScreen.screens.first?.frame else { return }
        sidebar.wrap(around: ScreenLayout.axRect(fromCocoa: axFrame, primaryScreenFrame: primary))   // the flip is its own inverse
        resizeSettleTask?.cancel()
        resizeSettleTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons != 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.snapper?.fixPositions()
            self.keepWorkspaceVisible()
        }
    }

    /// Pull every sidebar app into Atrium at launch, so the first click on each one is instant:
    /// running apps are placed quietly behind, closed apps are launched in the background, web apps start loading
    /// inside Atrium. Finally the last-used app comes to the front.
    ///
    /// Calm startup: Atrium covers its workspace ("Opening your apps") and stays in front while every sidebar app is
    /// placed out of sight (running apps behind Atrium, closed ones launched hidden, web apps found or opened), then
    /// the last-used app is revealed in one go. Capped so a slow app never holds the reveal back.
    private func preloadAll() {
        guard store.isAXTrusted, let snapper, let webHost else { return }
        sidebar.showLoading()
        let keepInFront = Task { @MainActor in
            while !Task.isCancelled {
                self.sidebar.stayInFront()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        var launchedHidden: [NSRunningApplication] = []
        let work = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))      // let the window and monitors settle
            // Native apps in parallel (each may wait for its window), then web apps' pages one by one.
            var jobs: [Task<Void, Never>] = []
            // Apps set to hibernate aren't started at launch (they start when first clicked), but if one is already
            // running it is placed like any other, so it stays under Atrium's control and can go to sleep later.
            for app in store.apps where !app.isWebApp && app.snapWindow {
                guard let url = store.resolvedURL(for: app) else { continue }
                let id = app.bundleIdentifier
                let hibernates = app.hibernates
                jobs.append(Task { @MainActor in
                    var running = Launcher.runningApp(bundleID: id)
                    if running == nil && hibernates { return }
                    let launching = running == nil
                    if launching {
                        running = try? await Launcher.open(url, activate: false, hide: true)   // starts out of sight
                        if let running { launchedHidden.append(running) }
                    }
                    guard let pid = running?.processIdentifier else { return }
                    await snapper.snapAndWait(slot: id, pid: pid, launching: launching, raise: false)
                })
            }
            for job in jobs { await job.value }
            await webHost.preload(store.apps)
        }
        Task { @MainActor in
            let started = Date()
            while !workDone, Date().timeIntervalSince(started) < 14 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            keepInFront.cancel()
            for app in launchedHidden where app.isHidden { app.unhide() }
            for pid in snapper.placedPIDs { if let app = NSRunningApplication(processIdentifier: pid), app.isHidden { app.unhide() } }
            if prefs.restoreLastApp { switcher.bringLastActiveForward() }
            try? await Task.sleep(for: .milliseconds(120))      // the app is up: lift the cover
            sidebar.hideLoading()
            keepWorkspaceVisible(fresh: true)
            log.notice("startup preload finished")
            refreshSnapshotSoon()
            // Screen Recording powers the smooth moving and switching. Ask once, now, never in the middle of an action.
            if !WindowSnapshotter.hasPermission, !UserDefaults.standard.bool(forKey: "askedForScreenRecording") {
                UserDefaults.standard.set(true, forKey: "askedForScreenRecording")
                try? await Task.sleep(for: .seconds(1))
                WindowSnapshotter.requestPermission()
            }
        }
        Task { @MainActor in
            await work.value
            self.workDone = true
        }
    }

    // MARK: Diagnostics

    /// `--debug-web`: show a web app, switch away and back, click/drag/double-click on the page while another app is
    /// in front, reload, close, and reopen with Reload. Logs what is in front, focused and loaded at each step.
    private func runWebDiagnostic() {
        Task { @MainActor in
            preloadAll()
            try? await Task.sleep(for: .seconds(18))
            guard let webHost, let snapper else { return }
            let webApps = store.apps.filter(\.isWebApp)
            for app in webApps {
                let id = app.bundleIdentifier
                log.notice("diag web \(app.displayName, privacy: .public): loaded \(webHost.isLoaded(id)) ready \(webHost.isReady(id)) title \(webHost.title(of: id) ?? "-", privacy: .public)")
            }
            guard let web = webApps.first(where: { webHost.isReady($0.bundleIdentifier) }),
                  let native = store.apps.first(where: { !$0.isWebApp && snapper.isPlaced($0.bundleIdentifier) }) else {
                log.notice("diag web: need a loaded web app and a placed native app"); return
            }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            @MainActor func report(_ label: String) {
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
                let order = snapper.order(of: native.bundleIdentifier, against: self.sidebar.window.windowNumber)
                let page = webHost.shownPage
                let focused = (self.sidebar.window.firstResponder as? NSView).map { r in page.map { r.isDescendant(of: $0.webView) } ?? false } ?? false
                log.notice("diag web \(label, privacy: .public): active \(self.store.activeBundleID ?? "none", privacy: .public); front app \(front, privacy: .public); Atrium key \(self.sidebar.window.isKeyWindow); page \(webHost.shownID ?? "none", privacy: .public) visible \(page.map { !$0.webView.isHidden } ?? false); focused \(focused); Atrium in front of \(native.displayName, privacy: .public) \(order?.atriumInFront.description ?? "?", privacy: .public); card \(String(describing: self.store.emptyState), privacy: .public)")
            }
            switcher.switchTo(web); try? await Task.sleep(for: .seconds(3)); report("show \(web.displayName)")
            switcher.switchTo(native); try? await Task.sleep(for: .seconds(2)); report("show \(native.displayName)")
            switcher.switchTo(web); try? await Task.sleep(for: .seconds(2)); report("back to \(web.displayName)")
            if let finder = Launcher.runningApp(bundleID: "com.apple.finder") {
                finder.activate(); try? await Task.sleep(for: .seconds(1.5)); report("Finder activated")
            }
            let ws = sidebar.workspaceRect
            let center = CGPoint(x: ws.midX, y: top - ws.midY)
            log.notice("diag web: under the pointer: \(ClickDiagnostic.frontOwner(at: center, atrium: self.sidebar.window.windowNumber), privacy: .public)")
            let frame0 = sidebar.window.frame
            ClickDiagnostic.drag(from: center, by: 0) {}
            try? await Task.sleep(for: .seconds(1.5)); report("clicked the page")
            ClickDiagnostic.drag(from: center, by: 160, dy: 40) {}
            try? await Task.sleep(for: .seconds(2))
            log.notice("diag web: drag on the page moved Atrium: \(self.sidebar.window.frame != frame0)")
            ClickDiagnostic.doubleClick(at: center)
            try? await Task.sleep(for: .seconds(1.5))
            log.notice("diag web: double-click on the page zoomed Atrium: \(self.sidebar.window.frame != frame0)")
            let loads = webHost.loadCount(web.bundleIdentifier)
            reload(web); try? await Task.sleep(for: .seconds(6))
            log.notice("diag web: Reload: loads \(loads) → \(webHost.loadCount(web.bundleIdentifier))")
            closeWebApp(web); try? await Task.sleep(for: .seconds(1)); report("closed")
            reload(web); try? await Task.sleep(for: .seconds(6)); report("Reload on the closed app")
        }
    }

    /// `--debug-js=<folder>`: runs commands from <folder>/cmd.json against a web app's page (see LaunchOptions).
    private func runJSConsole(_ dir: String) {
        let cmdURL = URL(fileURLWithPath: dir).appendingPathComponent("cmd.json")
        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("out.txt")
        @MainActor func out(_ text: String) {
            log.notice("diag js: \(text, privacy: .public)")
            let line = Data((text + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: outURL) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: outURL) }
        }
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let data = try? Data(contentsOf: cmdURL) else { continue }
                try? FileManager.default.removeItem(at: cmdURL)
                guard let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let webHost,
                      let name = cmd["app"] as? String,
                      let app = store.apps.first(where: { $0.isWebApp && $0.displayName.localizedCaseInsensitiveContains(name) }) else {
                    out("bad command"); continue
                }
                if cmd["show"] as? Bool == true { switcher.switchTo(app); try? await Task.sleep(for: .seconds(1.5)) }
                guard let page = webHost.page(app.bundleIdentifier) else { out("\(app.displayName) isn't loaded"); continue }
                if let js = cmd["js"] as? String {
                    do {
                        let result = try await page.webView.callAsyncJavaScript("return JSON.stringify(await (async () => { \(js) })())",
                                                                                 arguments: [:], contentWorld: .page)
                        out("js → \(result as? String ?? String(describing: result))")
                    } catch { out("js error: \(error)") }
                }
                if let d = cmd["drag"] as? [Double], d.count == 4, let window = page.webView.window {
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    @MainActor func screen(_ x: Double, _ y: Double) -> CGPoint {
                        let local = CGPoint(x: x, y: page.webView.isFlipped ? y : page.webView.bounds.height - y)
                        let s = window.convertPoint(toScreen: page.webView.convert(local, to: nil))
                        return CGPoint(x: s.x, y: top - s.y)
                    }
                    let from = screen(d[0], d[1]), to = screen(d[2], d[3])
                    out("drag \(from) → \(to); under the pointer: \(ClickDiagnostic.frontOwner(at: from, atrium: self.sidebar.window.windowNumber))")
                    ClickDiagnostic.drag(from: from, by: to.x - from.x, dy: to.y - from.y, steps: cmd["steps"] as? Int ?? 40) {}
                    try? await Task.sleep(for: .seconds(3))
                    out("drag done")
                }
            }
        }
    }

    private func runDnDDiagnostic() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let webHost else { return }
            let html = """
            <html><body style="font:16px -apple-system;margin:20px"><ul id=l style="list-style:none;padding:0">
            <li draggable=true id=A style="height:60px;background:#eee;margin:6px">A</li>
            <li draggable=true id=B style="height:60px;background:#ddd;margin:6px">B</li>
            <li draggable=true id=C style="height:60px;background:#ccc;margin:6px">C</li>
            <li draggable=true id=D style="height:60px;background:#bbb;margin:6px">D</li></ul>
            <script>
            var log=[]; let overs=0;
            document.addEventListener('pointerdown',e=>log.push('pdown:'+e.target.id));
            document.addEventListener('dragstart',e=>{log.push('start:'+e.target.id);if(e.target.id==='B'){e.dataTransfer.setData('application/vnd.pdnd','')}else{e.dataTransfer.setData('application/x-only','1')}});
            document.addEventListener('dragenter',e=>log.push('enter:'+[...e.dataTransfer.types].join('|')));document.addEventListener('dragover',e=>{e.preventDefault();if(overs++===5)log.push('over:'+[...e.dataTransfer.types].join('|'))});
            document.addEventListener('drop',e=>{e.preventDefault();log.push('drop:'+e.target.id)});
            document.addEventListener('dragend',e=>log.push('end:'+e.dataTransfer.dropEffect));
            setInterval(()=>{document.title=log.join(',')+' overs='+overs},100);
            </script></body></html>
            """
            let url = URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!
            let app = ManagedApp(bundleIdentifier: ManagedApp.webAppIDPrefix + "00000000-0000-0000-0000-00000000D0D0",
                                 displayName: "DnD Test", lastKnownPath: "", webURL: url.absoluteString)
            webHost.show(app)
            NSApp.activate()
            sidebar.bringForward()
            try? await Task.sleep(for: .seconds(3))
            guard let page = webHost.shownPage, let window = page.webView.window else { log.notice("diag dnd: no page"); return }
            let rects = (try? await page.webView.evaluateJavaScript("['B','D'].map(id=>{const r=document.getElementById(id).getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})")) as? [[Double]] ?? []
            guard rects.count == 2 else { log.notice("diag dnd: no rects"); return }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            @MainActor func screen(_ p: [Double]) -> CGPoint {
                let local = CGPoint(x: p[0], y: page.webView.isFlipped ? p[1] : page.webView.bounds.height - p[1])
                let s = window.convertPoint(toScreen: page.webView.convert(local, to: nil))
                return CGPoint(x: s.x, y: top - s.y)
            }
            let from = screen(rects[0]), to = screen(rects[1])
            log.notice("diag dnd: under the pointer \(ClickDiagnostic.frontOwner(at: from, atrium: self.sidebar.window.windowNumber), privacy: .public); dragging B → D")
            ClickDiagnostic.drag(from: from, by: to.x - from.x, dy: to.y - from.y) {}
            try? await Task.sleep(for: .seconds(2.5))
            log.notice("diag dnd result (B: empty vnd.pdnd only): \(page.webView.title ?? "-", privacy: .public)")
            _ = try? await page.webView.evaluateJavaScript("log.length=0; 0")
            let c = (try? await page.webView.evaluateJavaScript("(()=>{const r=document.getElementById('C').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")) as? [Double] ?? [0, 0]
            let fromC = screen(c)
            ClickDiagnostic.drag(from: fromC, by: to.x - fromC.x, dy: to.y - fromC.y) {}
            try? await Task.sleep(for: .seconds(2.5))
            log.notice("diag dnd result (C: custom type with a value only): \(page.webView.title ?? "-", privacy: .public)")
        }
    }

    private func runDragDiagnostic() {
        Task { @MainActor in
            preloadAll()
            try? await Task.sleep(for: .seconds(18))
            let glass = sidebar.layout.glass
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            // Empty rail space: just above the hairline that separates the list from the gear.
            let cocoaY = glass.minY + SidebarMetrics.bottomBlockHeight + DesignTokens.sidebarPadding + 12
            let start = CGPoint(x: glass.midX, y: primaryTop - cocoaY)
            let before = sidebar.window.frame
            log.notice("diag: dragging empty rail space at \(NSStringFromPoint(start), privacy: .public)")
            ClickDiagnostic.drag(from: start, by: 160) {
                Task { @MainActor in
                    let after = self.sidebar.window.frame
                    let railX = self.sidebar.railFrame.minX - after.minX
                    log.notice("diag drag: window moved by \(Int(after.minX - before.minX)) pt; rail sits \(Int(railX)) pt from the window's left edge (expected \(Int(DesignTokens.gap)))")
                    try? await Task.sleep(for: .seconds(1))
                    guard let snapper = self.snapper else { return }
                    let target = snapper.axTarget()
                    var inPlace = 0, total = 0, hidden = 0
                    for app in self.store.apps {
                        guard let w = snapper.placedWindow(app.bundleIdentifier), let pid = snapper.pid(of: app.bundleIdentifier) else { continue }
                        total += 1
                        if let f = AX.frame(w), abs(f.minX - target.minX) < 2, abs(f.minY - target.minY) < 2 { inPlace += 1 }
                        if NSRunningApplication(processIdentifier: pid)?.isHidden == true { hidden += 1 }
                    }
                    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                    log.notice("diag drag result: \(inPlace)/\(total) windows in the new place, \(hidden) still hidden, front app \(front, privacy: .public), active \(self.store.activeBundleID ?? "none", privacy: .public)")
                }
            }
        }
    }

    private func runClickDiagnostic(_ spec: String) {
        let ids = spec.split(separator: ":").map(String.init)
        guard ids.count == 2 else { return }
        Task { @MainActor in
            preloadAll()
            try? await Task.sleep(for: .seconds(14))                      // let everything get placed
            guard let from = store.apps.first(where: { $0.bundleIdentifier == ids[0] }),
                  let toIndex = store.apps.firstIndex(where: { $0.bundleIdentifier == ids[1] }) else { log.notice("diag: apps not found"); return }
            switcher.switchTo(from)
            try? await Task.sleep(for: .seconds(2))
            if LaunchOptions.debugAway, let finder = Launcher.runningApp(bundleID: "com.apple.finder") {
                AX.makeFrontmost(finder.processIdentifier)
                log.notice("diag: switched away to Finder")
                try? await Task.sleep(for: .seconds(2))
            }
            let glass = sidebar.layout.glass
            let metrics = SidebarMetrics.fit(count: store.apps.count, glassHeight: glass.height)
            let top = metrics.itemsTop(count: store.apps.count, glassHeight: glass.height)
            let cocoaY = glass.maxY - top - CGFloat(toIndex) * metrics.pitch - metrics.itemSize / 2
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let icon = CGPoint(x: glass.midX, y: primaryTop - cocoaY)
            let ws = sidebar.workspaceRect
            let wsCenter = CGPoint(x: ws.midX, y: primaryTop - ws.midY)
            log.notice("diag: clicking \(ids[1], privacy: .public) while \(ids[0], privacy: .public) is shown")
            ClickDiagnostic.run(iconCenter: icon, atrium: sidebar.window.windowNumber, workspaceCenter: wsCenter)
            try? await Task.sleep(for: .seconds(2))
            log.notice("diag click result: active \(self.store.activeBundleID ?? "none", privacy: .public); front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-", privacy: .public); Atrium key \(self.sidebar.window.isKeyWindow)")
        }
    }

    /// Developer aid: opens an app, then nudges Atrium's window so the follow behaviour can be observed from outside.
    private func runFollowDiagnostic(bundleID: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let app = store.apps.first(where: { $0.bundleIdentifier == bundleID }) else { log.notice("diag: app not in sidebar"); return }
            log.notice("diag: switching to \(bundleID, privacy: .public)")
            switcher.switchTo(app)
            try? await Task.sleep(for: .seconds(6))
            if LaunchOptions.debugSettingsClose {
                log.notice("diag: opening Settings")
                showSettings()
                try? await Task.sleep(for: .seconds(3))
                log.notice("diag: closing Settings")
                settingsWindow?.window?.performClose(nil)
                return
            }
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
        // Bring Atrium back *directly under* the app (above whatever you were using), never on top of it: putting
        // Atrium's window in front first and tucking it back afterwards is the flash that looks like a reload.
        if snapper?.isPlaced(id) == true || app.isWebApp || !prefs.snapOnSwitch || !app.snapWindow {
            keepWorkspaceVisible(fresh: true)
            return
        }
        guard let running = Launcher.runningApp(bundleID: id) else { return }
        snapper?.snap(slot: id, pid: running.processIdentifier, launching: false)
    }

    private func handleClick(_ app: ManagedApp) {
        if store.isMissing(app) { locate(app); return }
        if let switcher { switcher.switchTo(app) } else { store.activeBundleID = app.bundleIdentifier }   // demo: lens only
    }

    // MARK: Web apps

    private func isWebApp(_ id: String) -> Bool { id.hasPrefix(ManagedApp.webAppIDPrefix) }

    /// Can Atrium show this app right now: a window it has placed, or a web app (which it can always load)?
    private func isShowable(_ id: String) -> Bool {
        isWebApp(id) ? store.contains(bundleID: id) : snapper?.isPlaced(id) == true
    }

    /// A web app was chosen: its page comes on show inside Atrium, and Atrium comes in front with keyboard focus.
    private func showWebApp(_ app: ManagedApp) {
        guard let webHost else { return }
        let id = app.bundleIdentifier
        if store.activeBundleID != id { crossfadeAway(from: store.activeBundleID) }
        store.activeBundleID = id
        prefs.lastActiveBundleID = id
        webHost.show(app)
        store.emptyState = webHost.isReady(id) ? nil : .opening(id)           // "Opening…" until the page has drawn
        bringWebForward()
    }

    /// Atrium in front and active, with the page focused (a web app is on show).
    private func bringWebForward() {
        guard let id = store.activeBundleID, isWebApp(id) else { return }
        if !NSApp.isActive { NSApp.activate() }
        sidebar.bringForward()
        webHost?.focus()
    }

    /// A click on the page on show: it's the app you're using again (even if something else was in front a moment ago).
    private func webContentClicked() {
        if let shown = webHost?.shownID, store.activeBundleID != shown {
            store.activeBundleID = shown
            prefs.lastActiveBundleID = shown
        }
        bringWebForward()
    }

    /// Close (or hibernate) a web app: its page is unloaded; if it was on show, its card says so.
    @discardableResult
    private func closeWebApp(_ app: ManagedApp) -> Bool {
        guard webHost?.close(app) == true else { return false }
        if store.activeBundleID == app.bundleIdentifier { shownAppGone(app.bundleIdentifier) }
        return true
    }

    /// Reload: a web app's page reloads (or opens, if it was closed); a native app quits and opens again.
    private func reload(_ app: ManagedApp) {
        let id = app.bundleIdentifier
        if app.isWebApp {
            if webHost?.isLoaded(id) == true { webHost?.reload(app) } else { switcher?.switchTo(app) }
            return
        }
        guard let running = Launcher.runningApp(bundleID: id) else { switcher?.switchTo(app); return }
        let wasShown = store.activeBundleID == id
        running.terminate()
        Task { @MainActor in
            var waited = 0
            while !running.isTerminated, waited < 100 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
            guard running.isTerminated else {                       // it asked to save first, or refused: leave it be
                log.notice("relaunch: \(id, privacy: .public) didn't quit")
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            if wasShown { switcher?.switchTo(app); return }
            guard let url = store.resolvedURL(for: app), let snapper,
                  let reopened = try? await Launcher.open(url, activate: false, hide: true) else { return }
            await snapper.snapAndWait(slot: id, pid: reopened.processIdentifier, launching: true, raise: false)
            reopened.unhide()
        }
    }

    /// A page posted a notification: show it, unless you're looking at that app right now.
    private func webNotification(_ app: ManagedApp, title: String, body: String, noteID: String) {
        if store.activeBundleID == app.bundleIdentifier, NSApp.isActive, sidebar.window.isVisible { return }
        notifier?.post(appID: app.bundleIdentifier, appName: app.displayName, title: title, body: body, noteID: noteID)
    }

    /// Clicking a notification opens its app in Atrium and lets the page go to the right place.
    private func webNotificationClicked(_ id: String, noteID: String) {
        guard let app = store.apps.first(where: { $0.bundleIdentifier == id }) else { return }
        if !sidebar.window.isVisible { sidebar.show() }
        if sidebar.window.isMiniaturized { sidebar.window.deminiaturize(nil) }
        switcher?.switchTo(app)
        webHost?.notificationClicked(id, noteID: noteID)
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

// MARK: - View menu (the web app on show)

extension AppDelegate: WebCommands {
    private var shownWebApp: ManagedApp? {
        guard let id = webHost?.shownID, store.activeBundleID == id else { return nil }
        return store.apps.first { $0.bundleIdentifier == id }
    }

    @objc func reloadWebPage(_ sender: Any?) { if let app = shownWebApp { webHost?.reload(app) } }
    @objc func webGoBack(_ sender: Any?) { webHost?.goBack() }
    @objc func webGoForward(_ sender: Any?) { webHost?.goForward() }
    @objc func webActualSize(_ sender: Any?) { webHost?.zoom(by: nil) }
    @objc func webZoomIn(_ sender: Any?) { webHost?.zoom(by: DesignTokens.webZoomStep) }
    @objc func webZoomOut(_ sender: Any?) { webHost?.zoom(by: -DesignTokens.webZoomStep) }
    @objc func openWebPageInBrowser(_ sender: Any?) { if let url = webHost?.shownURL { NSWorkspace.shared.open(url) } }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let webActions: [Selector] = [#selector(reloadWebPage(_:)), #selector(webGoBack(_:)), #selector(webGoForward(_:)),
                                      #selector(webActualSize(_:)), #selector(webZoomIn(_:)), #selector(webZoomOut(_:)),
                                      #selector(openWebPageInBrowser(_:))]
        guard let action = menuItem.action, webActions.contains(action) else { return true }
        guard shownWebApp != nil, let page = webHost?.shownPage else { return false }
        if action == #selector(webGoBack(_:)) { return page.webView.canGoBack }
        if action == #selector(webGoForward(_:)) { return page.webView.canGoForward }
        return true
    }
}
