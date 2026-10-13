import AppKit
import ApplicationServices
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "webapps")

/// Web apps hosted by Microsoft Edge in "app mode" (`--app=URL`): each one is its own window with no tabs or toolbar,
/// separate from the user's normal browser windows. Links that open a new tab go to the user's regular browser window
/// (Chromium's own behaviour for app windows).
///
/// All those windows belong to one Edge process, so each web app's window is identified by its window-server number
/// (a new window always gets a higher number than every existing one), remembered across Atrium restarts, and mapped
/// back to its Accessibility element when needed.
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
    private var iconRefreshScheduled: Set<String> = []
    /// The web app being brought forward, briefly: Edge focusing a *different* window meanwhile is put right.
    private var bringing: (slot: String, window: AXUIElement, until: Date)?
    /// A web app's window is being closed: Edge focusing its next window meanwhile is automatic, not a choice.
    private var closingUntil = Date.distantPast

    /// slot → window number, persisted so Atrium can find the same windows again after a restart.
    private var savedNumbers: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: "webAppWindowNumbers") as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "webAppWindowNumbers") }
    }

    /// A web app's window came to the front (from any source); Atrium should come forward under it.
    var onWebAppFocused: (@MainActor (String) -> Void)?
    /// A web app's window was just lifted: put Atrium right under it.
    var onRaised: (@MainActor () -> Void)?
    /// Just before the visible app changes (for the crossfade): the app that's leaving.
    var onWillSwitch: (@MainActor (_ from: String?) -> Void)?
    var onOpening: (@MainActor (_ id: String, _ from: String?) -> Void)?

    init(store: AppStore, prefs: Preferences, snapper: WindowSnapper) {
        self.store = store
        self.prefs = prefs
        self.snapper = snapper
    }

    func hostsWebApps(_ bundleID: String) -> Bool { store.apps.contains { $0.isWebApp && $0.browserBundleID == bundleID } }

    // MARK: Opening

    func open(_ app: ManagedApp) {
        let id = app.bundleIdentifier
        let previous = store.activeBundleID
        if previous != id, snapper.placedWindow(id) != nil { onWillSwitch?(previous) }
        if snapper.placedWindow(id) == nil { onOpening?(id, previous) }
        store.activeBundleID = id
        prefs.lastActiveBundleID = id
        guard !opening.contains(id) else { return }
        opening.insert(id)
        Task {
            defer { opening.remove(id) }
            guard let (pid, window) = await ensureWindow(for: app, activate: true),
                  let browser = NSRunningApplication(processIdentifier: pid) else { return }
            // The user may have clicked something else while this was loading.
            guard store.activeBundleID == id else { return }
            await bringForward(window, browser: browser, slot: id)
        }
    }

    /// Startup: find (or create) every web app's window and place it quietly behind, so clicks are instant later.
    func preload(_ apps: [ManagedApp]) async {
        // A hibernating web app isn't opened at launch, but if its window is still open (Atrium restarted) it is
        // re-attached: otherwise it would sit outside Atrium, never counted as open and so never put to sleep.
        for app in apps where app.isWebApp {
            _ = await ensureWindow(for: app, activate: false, create: !app.hibernates)
        }
    }

    /// Returns the web app's window, placing it in Atrium if it had to be found or created.
    private func ensureWindow(for app: ManagedApp, activate: Bool, create: Bool = true) async -> (pid_t, AXUIElement)? {
        let id = app.bundleIdentifier
        guard let site = app.webURL.flatMap(URL.init(string:)), let browserID = app.browserBundleID,
              let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID) else { return nil }

        // 1. Already tracking a live window.
        if let window = snapper.placedWindow(id), AX.frame(window) != nil, let browser = Launcher.runningApp(bundleID: browserID) {
            return (browser.processIdentifier, window)
        }

        if !store.isAXTrusted {
            if !promptedForAccessibility { promptedForAccessibility = true; _ = AX.isTrusted(prompt: true) }
        }

        // 2. A window we created earlier (maybe before Atrium restarted) still exists: adopt it.
        if store.isAXTrusted, let browser = Launcher.runningApp(bundleID: browserID), let number = savedNumbers[id] {
            let pid = browser.processIdentifier
            if let window = await resolveWindow(number: number, pid: pid) {
                log.notice("re-adopted window \(number) for \(id, privacy: .public)")
                await adopt(window, number: number, pid: pid, slot: id, site: site)
                return (pid, window)
            }
        }

        // 2b. An app-mode window for this site that Atrium lost track of (e.g. a close the page refused, or an older
        //     session): adopt it rather than open a duplicate.
        if store.isAXTrusted, let browser = Launcher.runningApp(bundleID: browserID),
           let (window, number) = await findUntrackedWindow(for: app, site: site, pid: browser.processIdentifier) {
            log.notice("adopted an already-open window \(number) for \(id, privacy: .public)")
            await adopt(window, number: number, pid: browser.processIdentifier, slot: id, site: site)
            return (browser.processIdentifier, window)
        }

        // 3. Ask the browser for a new app-mode window and spot it by its (new, highest) window number.
        guard create else { return nil }
        store.launchingBundleIDs.insert(id)
        defer { store.launchingBundleIDs.remove(id) }
        let existing = Launcher.runningApp(bundleID: browserID)
        let before = Set(existing.map { windowBounds(pid: $0.processIdentifier).keys } ?? [:].keys)

        // Edge ignores a requested position for app windows, so catch the window the instant it is created and move it
        // into Atrium right away (instead of finding it up to 150 ms later, after it has already shown elsewhere).
        var catcher: AXWindowObserver?
        if store.isAXTrusted, let existing, prefs.snapOnSwitch, app.snapWindow {
            let pid = existing.processIdentifier
            let beforeWindows = axWindows(pid: pid)
            let started = Date()
            catcher = AXWindowObserver(pid: pid, element: AX.app(pid), notifications: [kAXWindowCreatedNotification]) {
                [weak self] _, window in
                guard let self, !beforeWindows.contains(where: { CFEqual($0, window) }), self.snapper.slot(for: window) == nil else { return }
                AX.setFrame(window, app: AX.app(pid), to: self.snapper.axTarget())
                log.notice("placed a new web-app window \(Int(Date().timeIntervalSince(started) * 1000)) ms after asking")
            }
        }
        defer { catcher?.invalidate() }

        let config = NSWorkspace.OpenConfiguration()
        // Ask Edge to open the window exactly where Atrium places it, so it never appears somewhere else first.
        let target = snapper.axTarget()
        config.arguments = [
            "--app=\(site.absoluteString)",
            "--window-position=\(Int(target.minX)),\(Int(target.minY))",
            "--window-size=\(Int(target.width)),\(Int(target.height))",
        ]
        // A running Chromium ignores arguments passed to an activation, so start a second instance: it hands the
        // request to the running browser (its process singleton) and exits.
        config.createsNewApplicationInstance = existing != nil
        // Never let Edge activate here: it would bring forward its last-used window (often another web app) before
        // this one exists. Atrium's "Opening…" card shows meanwhile, and the new window is brought forward by Atrium.
        config.activates = existing == nil && activate
        do {
            _ = try await NSWorkspace.shared.openApplication(at: browserURL, configuration: config)
            log.notice("asked \(browserID, privacy: .public) for an app window: \(site.absoluteString, privacy: .public)")
        } catch {
            log.error("couldn't open web app \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard store.isAXTrusted else { return nil }     // without Accessibility we can open it but not place it

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            guard let browser = Launcher.runningApp(bundleID: browserID) else { continue }
            let pid = browser.processIdentifier
            let bounds = windowBounds(pid: pid)
            guard let number = bounds.keys.filter({ !before.contains($0) }).max(), let frame = bounds[number] else { continue }
            guard let window = axWindows(pid: pid).first(where: { w in
                snapper.slot(for: w) == nil && AX.frame(w).map { close($0, frame) } == true
            }) else { continue }
            let t = snapper.axTarget()
            log.notice("web app \(id, privacy: .public) got window \(number), first seen at \(NSStringFromRect(frame), privacy: .public); target \(NSStringFromRect(t), privacy: .public)")
            await adopt(window, number: number, pid: pid, slot: id, site: site)
            return (pid, window)
        }
        log.notice("no new window appeared for \(id, privacy: .public)")
        return nil
    }

    private func adopt(_ window: AXUIElement, number: Int, pid: pid_t, slot: String, site: URL) async {
        var numbers = savedNumbers
        numbers[slot] = number
        savedNumbers = numbers
        store.runningBundleIDs.insert(slot)
        watchFocus(of: pid)
        let app = store.apps.first { $0.bundleIdentifier == slot }
        if prefs.snapOnSwitch, app?.snapWindow ?? true {
            await snapper.place(slot: slot, pid: pid, window: window, raise: false)
        }
        scheduleIconRefresh(slot: slot, site: site)
    }

    /// Raise exactly this window and activate the browser *without* bringing its other windows along.
    private func bringForward(_ window: AXUIElement, browser: NSRunningApplication, slot: String) async {
        store.activeBundleID = slot
        bringing = (slot, window, Date().addingTimeInterval(0.8))
        AX.raise(window)
        AX.set(window, kAXFocusedAttribute, true as CFBoolean)
        onRaised?()                                       // Atrium straight under it, before the browser takes focus
        AX.makeFrontmost(browser.processIdentifier)
        if NSApp.isActive { NSApp.yieldActivation(to: browser) }
        browser.activate()
        watchFocus(of: browser.processIdentifier)
        // Edge brings forward its *last focused* window when it activates, which can be another web app's. Make sure
        // it's this one, right after activation and once more a moment later.
        let pid = browser.processIdentifier
        Task { @MainActor in
            for delay in [60, 220] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard store.activeBundleID == slot else { return }
                let focused = AX.element(AX.app(pid), kAXFocusedWindowAttribute)
                if focused.map({ !CFEqual($0, window) }) ?? true {
                    AX.raise(window)
                    AX.set(window, kAXFocusedAttribute, true as CFBoolean)
                }
            }
        }
        let app = store.apps.first { $0.bundleIdentifier == slot }
        if prefs.snapOnSwitch, app?.snapWindow ?? true {
            await snapper.place(slot: slot, pid: browser.processIdentifier, window: window, raise: true)
        }
    }

    // MARK: Window identification

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The browser's normal-sized windows: number → bounds (CG and AX share top-left global coordinates).
    private func windowBounds(pid: pid_t) -> [Int: CGRect] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [Int: CGRect] = [:]
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  (b["Width"] ?? 0) >= 200, (b["Height"] ?? 0) >= 150 else { continue }
            result[number] = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
        return result
    }

    private func axWindows(pid: pid_t) -> [AXUIElement] {
        let app = AX.app(pid)
        var all = AX.elements(app, kAXWindowsAttribute)
        for w in [AX.element(app, kAXFocusedWindowAttribute), AX.element(app, kAXMainWindowAttribute)].compactMap({ $0 })
        where !all.contains(where: { CFEqual($0, w) }) { all.append(w) }
        return all.filter { AX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
    }

    /// Finds the Accessibility element for a window number. Several web-app windows can be stacked on exactly the same
    /// rectangle, so when bounds alone are ambiguous, nudge each candidate by one point and see which number moved.
    private func resolveWindow(number: Int, pid: pid_t, allowTracked: Bool = false) async -> AXUIElement? {
        guard let frame = windowBounds(pid: pid)[number] else { return nil }
        let candidates = axWindows(pid: pid).filter { w in
            (allowTracked || snapper.slot(for: w) == nil) && AX.frame(w).map { close($0, frame) } == true
        }
        if candidates.count <= 1 { return candidates.first }
        for w in candidates {
            guard let f = AX.frame(w) else { continue }
            var nudged = CGPoint(x: f.minX, y: f.minY + 1)
            var original = f.origin
            guard let moved = AXValueCreate(.cgPoint, &nudged), let back = AXValueCreate(.cgPoint, &original) else { continue }
            AX.set(w, kAXPositionAttribute, moved)
            // The window server reports the move a moment later; poll briefly.
            var hit = false
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(25))
                if let b = windowBounds(pid: pid)[number], abs(b.minY - nudged.y) < 0.5 { hit = true; break }
            }
            AX.set(w, kAXPositionAttribute, back)
            if hit { return w }
        }
        return nil
    }

    // MARK: Tidying up

    /// Closes leftover duplicates: untracked app-mode windows sitting in Atrium's area whose title names a web app that
    /// already has its own (tracked) window. Skipped while the browser plays sound, since a leftover could be the one
    /// playing music.
    func tidyUpDuplicates() async {
        for browserID in Set(store.apps.compactMap(\.browserBundleID)) {
            guard let browser = Launcher.runningApp(bundleID: browserID) else { continue }
            if AudioActivity.appsUsingAudio().contains(browserID) {
                log.notice("tidy-up skipped: \(browserID, privacy: .public) is playing sound")
                continue
            }
            let pid = browser.processIdentifier
            let target = snapper.axTarget()
            let tracked = store.apps.filter { $0.isWebApp && $0.browserBundleID == browserID && snapper.placedWindow($0.bundleIdentifier) != nil }
            var closed = 0
            for window in axWindows(pid: pid) where snapper.slot(for: window) == nil {
                guard let title = AX.string(window, kAXTitleAttribute), !title.contains("Microsoft"),
                      let frame = AX.frame(window), close(frame, target),
                      tracked.contains(where: { app in
                          let site = app.webURL.flatMap(URL.init(string:))
                          return [app.displayName, site.map(WebAddress.suggestedName(for:)) ?? ""]
                              .filter { $0.count >= 3 }.contains { title.localizedCaseInsensitiveContains($0) }
                      }),
                      let button = AX.element(window, kAXCloseButtonAttribute) else { continue }
                if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success { closed += 1 }
            }
            if closed > 0 { log.notice("tidied up \(closed) duplicate window(s) of \(browserID, privacy: .public)") }
        }
    }

    // MARK: Which web app is in front?

    /// Called when the hosting browser becomes the active app: returns the web app whose window is focused, if any.
    func resolveFocusedSlot(browserBundleID: String) -> String? {
        if let b = bringing, Date() < b.until { return b.slot }                  // mid-switch: the one being shown
        if let card = store.emptyState, card.appID == store.activeBundleID { return card.appID }   // a card is up
        if Date() < closingUntil { return store.activeBundleID }                 // mid-close: nothing changed by choice
        guard let browser = Launcher.runningApp(bundleID: browserBundleID) else { return nil }
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
        if Date() < closingUntil { return }
        // Mid-switch: Edge focusing some other window by itself is not a choice; put the intended one back on top.
        if let b = bringing, Date() < b.until, !CFEqual(focused, b.window) {
            AX.raise(b.window)
            AX.set(b.window, kAXFocusedAttribute, true as CFBoolean)
            return
        }
        // A card is up for the web app whose window just closed: the browser focusing its next window is automatic,
        // not a choice; keep showing the card.
        if let card = store.emptyState, card.appID == store.activeBundleID, snapper.slot(for: focused) != card.appID { return }
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
        guard pid == observedPID else { return }
        focusObserver?.invalidate()
        focusObserver = nil
        observedPID = 0
    }

    // MARK: Icons

    /// Edge records a site's favicon once it has loaded it (signed in, so it's the real one, e.g. Google Calendar's
    /// dated icon rather than the generic Google logo of the sign-in page). Check shortly after the window opens.
    /// Web apps whose icon already came from Edge (no need to refresh again).
    private var browserIcons: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "webAppBrowserIcons") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "webAppBrowserIcons") }
    }

    private func scheduleIconRefresh(slot: String, site: URL) {
        guard !iconRefreshScheduled.contains(slot), !browserIcons.contains(slot),
              store.apps.first(where: { $0.bundleIdentifier == slot })?.customIcon != true else { return }
        iconRefreshScheduled.insert(slot)
        Task {
            for delay in [6, 30] {
                try? await Task.sleep(for: .seconds(delay))
                guard let app = store.apps.first(where: { $0.bundleIdentifier == slot }), !app.customIcon else { return }
                if let path = await SiteIconFetcher.iconFromBrowser(for: site, name: app.displayName, id: slot) {
                    if let old = app.iconFile { try? FileManager.default.removeItem(atPath: old) }
                    store.update(bundleID: slot) { $0.iconFile = path }
                    browserIcons.insert(slot)
                    log.notice("updated icon for \(slot, privacy: .public) from Edge")
                    return
                }
            }
        }
    }

    // MARK: Menu actions

    func reload(_ app: ManagedApp) {
        guard let window = snapper.placedWindow(app.bundleIdentifier), let browserID = app.browserBundleID,
              let browser = Launcher.runningApp(bundleID: browserID) else { return }
        Task {
            await bringForward(window, browser: browser, slot: app.bundleIdentifier)
            try? await Task.sleep(for: .milliseconds(150))       // let the window become key in the browser
            if !AX.pressMenuItem(in: browser.processIdentifier, where: { $0.lowercased().hasPrefix("reload") }) {
                log.notice("reload menu item not found")
            }
        }
    }

    /// Closes the web app's window (its Edge window, so the page stops running) and checks that it really closed.
    /// A page can refuse ("Leave site?"); then the window stays tracked instead of being lost, and false is returned.
    @discardableResult
    func closeWindow(_ app: ManagedApp) async -> Bool {
        let id = app.bundleIdentifier
        guard let window = snapper.placedWindow(id), let browserID = app.browserBundleID,
              let browser = Launcher.runningApp(bundleID: browserID) else { return false }
        let pid = browser.processIdentifier
        // Make sure this element really is the window we recorded (several can be stacked on the same spot).
        var target = window
        if let number = savedNumbers[id], await !isElement(window, number: number, pid: pid) {
            log.error("\(id, privacy: .public): tracked element isn't window \(number); looking it up again")
            guard let found = await resolveWindow(number: number, pid: pid, allowTracked: true) else { return false }
            target = found
        }
        closingUntil = Date().addingTimeInterval(1.5)
        guard let button = AX.element(target, kAXCloseButtonAttribute),
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            closingUntil = .distantPast
            log.error("couldn't press close on \(id, privacy: .public)")
            return false
        }
        // Did it actually go away?
        let number = savedNumbers[id]
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(150))
            let stillThere = number.map { windowBounds(pid: pid)[$0] != nil } ?? (AX.frame(target) != nil)
            if !stillThere {
                snapper.forget(id)
                store.runningBundleIDs.remove(id)
                var numbers = savedNumbers
                numbers[id] = nil
                savedNumbers = numbers
                return true
            }
        }
        log.notice("\(id, privacy: .public) kept its window open (the page may be asking to stay); still tracking it")
        return false
    }

    /// An untracked app-mode window (no "Microsoft Edge" in its title, unlike normal browser windows) whose title names
    /// this web app, with its window number.
    private func findUntrackedWindow(for app: ManagedApp, site: URL, pid: pid_t) async -> (AXUIElement, Int)? {
        let keywords = [app.displayName, WebAddress.suggestedName(for: site)]
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
        guard !keywords.isEmpty else { return nil }
        let bounds = windowBounds(pid: pid)
        let claimed = Set(savedNumbers.values)
        for window in axWindows(pid: pid) where snapper.slot(for: window) == nil {
            guard let title = AX.string(window, kAXTitleAttribute), !title.contains("Microsoft"),
                  keywords.contains(where: { title.localizedCaseInsensitiveContains($0) }),
                  let frame = AX.frame(window) else { continue }
            let numbers = bounds.filter { close($0.value, frame) && !claimed.contains($0.key) }.map(\.key)
            for number in numbers.sorted() {
                if numbers.count == 1 { return (window, number) }
                if await isElement(window, number: number, pid: pid) { return (window, number) }
            }
        }
        return nil
    }

    /// Whether `element` is the window with this number: nudge it by a point and see which number moved.
    private func isElement(_ element: AXUIElement, number: Int, pid: pid_t) async -> Bool {
        guard let before = windowBounds(pid: pid)[number], let f = AX.frame(element) else { return false }
        if windowBounds(pid: pid).values.filter({ close($0, before) }).count == 1 { return close(f, before) }   // unambiguous
        var nudged = CGPoint(x: f.minX, y: f.minY + 1), original = f.origin
        guard let moved = AXValueCreate(.cgPoint, &nudged), let back = AXValueCreate(.cgPoint, &original) else { return false }
        AX.set(element, kAXPositionAttribute, moved)
        var hit = false
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(25))
            if let b = windowBounds(pid: pid)[number], abs(b.minY - nudged.y) < 0.5 { hit = true; break }
        }
        AX.set(element, kAXPositionAttribute, back)
        return hit
    }

    func minimize(_ app: ManagedApp) {
        guard let window = snapper.placedWindow(app.bundleIdentifier) else { return }
        AX.set(window, kAXMinimizedAttribute, true as CFBoolean)
    }
}
