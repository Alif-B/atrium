import AppKit
import ApplicationServices
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "webapps")

/// Web apps hosted by a Chromium browser (Microsoft Edge) in "app mode" (`--app=URL`): each one is its own window with
/// no tabs or toolbar, separate from the user's normal browser windows. Links that open a new tab go to the user's
/// regular browser window (Chromium's own behaviour for app windows).
///
/// All those windows belong to one browser process, so Atrium identifies each web app's window by watching which
/// window *appears* when it launches it, and then tracks it per sidebar item (slot) in `WindowSnapper`.
@MainActor
final class WebAppManager {
    static let edgeBundleID = "com.microsoft.edgemac"
    static var isEdgeInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: edgeBundleID) != nil }

    private let store: AppStore
    private let prefs: Preferences
    private let snapper: WindowSnapper
    private var focusObserver: AXWindowObserver?
    private var observedPID: pid_t = 0
    private var opening: Set<String> = []
    private var promptedForAccessibility = false

    /// A web app's window came to the front (from any source); Atrium should come forward under it.
    var onWebAppFocused: (@MainActor (String) -> Void)?

    init(store: AppStore, prefs: Preferences, snapper: WindowSnapper) {
        self.store = store
        self.prefs = prefs
        self.snapper = snapper
    }

    private func webApps(hostedBy bundleID: String) -> [ManagedApp] {
        store.apps.filter { $0.isWebApp && $0.browserBundleID == bundleID }
    }

    func hostsWebApps(_ bundleID: String) -> Bool { !webApps(hostedBy: bundleID).isEmpty }

    /// The long-lived browser process (during a launch a short-lived second instance can briefly exist).
    private func browserApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .min { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
    }

    // MARK: Opening

    func open(_ app: ManagedApp) {
        let id = app.bundleIdentifier
        guard !opening.contains(id) else { return }
        store.activeBundleID = id
        prefs.lastActiveBundleID = id
        opening.insert(id)
        Task {
            await openAsync(app)
            opening.remove(id)
        }
    }

    private func openAsync(_ app: ManagedApp) async {
        let id = app.bundleIdentifier
        guard let site = app.webURL.flatMap(URL.init(string:)), let browserID = app.browserBundleID,
              let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID) else { return }

        // 1. Its window already exists: just bring that one window forward.
        if let window = snapper.placedWindow(id), AX.frame(window) != nil, let browser = browserApp(browserID) {
            await bringForward(window, browser: browser, slot: id)
            return
        }

        if !store.isAXTrusted, !promptedForAccessibility {
            promptedForAccessibility = true
            _ = AX.isTrusted(prompt: true)
        }

        // 2. Launch a dedicated app-mode window and work out which window is new.
        store.launchingBundleIDs.insert(id)
        defer { store.launchingBundleIDs.remove(id) }
        let existing = browserApp(browserID)
        let before = existing.map { allWindows(of: $0.processIdentifier) } ?? []

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--app=\(site.absoluteString)"]
        // A running Chromium ignores arguments passed to an activation, so start a second instance: it hands the
        // request to the running browser (its process singleton) and exits.
        config.createsNewApplicationInstance = existing != nil
        config.activates = true
        if NSApp.isActive, let existing { NSApp.yieldActivation(to: existing) }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: browserURL, configuration: config)
            log.notice("asked \(browserID, privacy: .public) for an app window: \(site.absoluteString, privacy: .public)")
        } catch {
            log.error("couldn't open web app \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard store.isAXTrusted else { return }        // without Accessibility we can open it but not place it

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            guard let browser = browserApp(browserID) else { continue }
            let pid = browser.processIdentifier
            let candidates = allWindows(of: pid).filter { w in
                !before.contains { CFEqual($0, w) } && snapper.slot(for: w) == nil
                    && AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole
            }
            guard !candidates.isEmpty else { continue }
            // Prefer the focused one (the window that just opened), else the newest candidate.
            let focused = AX.element(AX.app(pid), kAXFocusedWindowAttribute)
            let window = candidates.first { w in focused.map { CFEqual($0, w) } ?? false } ?? candidates.last!
            store.runningBundleIDs.insert(id)
            log.notice("web app \(id, privacy: .public) got its window")
            await bringForward(window, browser: browser, slot: id)
            return
        }
        log.notice("no new window appeared for \(id, privacy: .public)")
    }

    private func allWindows(of pid: pid_t) -> [AXUIElement] {
        let app = AX.app(pid)
        var all = AX.elements(app, kAXWindowsAttribute)
        for w in [AX.element(app, kAXFocusedWindowAttribute), AX.element(app, kAXMainWindowAttribute)].compactMap({ $0 })
        where !all.contains(where: { CFEqual($0, w) }) { all.append(w) }
        return all
    }

    /// Raise exactly this window and activate the browser *without* bringing its other windows along.
    private func bringForward(_ window: AXUIElement, browser: NSRunningApplication, slot: String) async {
        store.activeBundleID = slot
        AX.raise(window)
        if NSApp.isActive { NSApp.yieldActivation(to: browser) }
        browser.activate()
        watchFocus(of: browser.processIdentifier)
        let app = store.apps.first { $0.bundleIdentifier == slot }
        if prefs.snapOnSwitch, app?.snapWindow ?? true {
            await snapper.place(slot: slot, pid: browser.processIdentifier, window: window)
        }
    }

    // MARK: Which web app is in front?

    /// Called when the hosting browser becomes the active app: returns the web app whose window is focused, if any.
    func resolveFocusedSlot(browserBundleID: String) -> String? {
        guard let browser = browserApp(browserBundleID) else { return nil }
        watchFocus(of: browser.processIdentifier)
        guard let focused = AX.element(AX.app(browser.processIdentifier), kAXFocusedWindowAttribute) else { return nil }
        return snapper.slot(for: focused)
    }

    /// Switching between the browser's own windows doesn't change the active *app*, so watch its focused window.
    private func watchFocus(of pid: pid_t) {
        guard store.isAXTrusted, pid != observedPID else { return }
        focusObserver?.invalidate()
        observedPID = pid
        focusObserver = AXWindowObserver(
            pid: pid, element: AX.app(pid),
            notifications: [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
        ) { [weak self] _ in self?.focusChanged(pid: pid) }
    }

    private func focusChanged(pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = AX.element(AX.app(pid), kAXFocusedWindowAttribute) else { return }
        if let slot = snapper.slot(for: focused) {
            if store.activeBundleID != slot {
                store.activeBundleID = slot
                prefs.lastActiveBundleID = slot
            }
            onWebAppFocused?(slot)
        } else if store.apps.contains(where: { $0.isWebApp && $0.bundleIdentifier == store.activeBundleID }) {
            store.activeBundleID = nil          // the user moved to a normal browser window
        }
    }

    func browserTerminated(pid: pid_t) {
        if pid == observedPID {
            focusObserver?.invalidate()
            focusObserver = nil
            observedPID = 0
        }
    }

    // MARK: Menu actions

    func closeWindow(_ app: ManagedApp) {
        guard let window = snapper.placedWindow(app.bundleIdentifier) else { return }
        if let button = AX.element(window, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    func minimize(_ app: ManagedApp) {
        guard let window = snapper.placedWindow(app.bundleIdentifier) else { return }
        AX.set(window, kAXMinimizedAttribute, true as CFBoolean)
    }
}
