import AppKit
import ApplicationServices
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "snap")

/// Places real windows over Atrium's workspace rectangle and keeps them there as Atrium moves/resizes.
///
/// Windows are tracked per *slot* (a sidebar item's id), not per process: Edge web apps are several windows of one
/// Edge process, each belonging to a different sidebar item.
@MainActor
final class WindowSnapper {
    struct Placed {
        let pid: pid_t
        let window: AXUIElement
    }

    private let store: AppStore
    private let workspaceRect: @MainActor () -> CGRect          // Cocoa screen coordinates
    private var placed: [String: Placed] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var followTask: Task<Void, Never>?
    private let liveMover = LiveMover()
    /// Last size we asked the active window to take; while it stays the same, live moves send position only.
    private var liveSize: [String: CGSize] = [:]
    /// Watches each placed window: if the user moves or resizes it by hand, put it back (Atrium owns the geometry).
    private var guards: [String: AXWindowObserver] = [:]
    private var restoreTasks: [String: Task<Void, Never>] = [:]
    /// Windows that refused the target size (e.g. an app minimum larger than Atrium's area). We stop fighting them
    /// until the next snap or Atrium move, so we never loop forever.
    private var unfittable: Set<String> = []
    /// Windows the user is resizing by their own edge right now (Atrium follows them).
    private var userResizing: Set<String> = []

    /// Called after a window was fitted, so Atrium can slot itself under it.
    var onSnapped: (@MainActor () -> Void)?
    /// Called when a placed window is closed (so web apps can show as "not running").
    var onWindowGone: (@MainActor (String) -> Void)?
    /// The user is resizing a placed window by its own edge (AX frame): Atrium grows or shrinks around it instead.
    var onUserResize: (@MainActor (String, CGRect) -> Void)?

    init(store: AppStore, workspaceRect: @escaping @MainActor () -> CGRect) {
        self.store = store
        self.workspaceRect = workspaceRect
    }

    func isPlaced(_ slot: String) -> Bool { placed[slot] != nil }
    func pid(of slot: String) -> pid_t? { placed[slot]?.pid }

    /// When a window's position couldn't be read, first seen when. Right after wake or a display change macOS's
    /// Accessibility interface can fail for a moment: that is not a closed window. A real close arrives as a
    /// "destroyed" notification; a failed read only counts once it has kept failing for a while.
    private var unreadableSince: [String: Date] = [:]

    private func isGone(_ slot: String, _ p: Placed) -> Bool {
        if AX.frame(p.window) != nil { unreadableSince[slot] = nil; return false }
        let since = unreadableSince[slot] ?? Date()
        unreadableSince[slot] = since
        guard Date().timeIntervalSince(since) > 5, NSRunningApplication(processIdentifier: p.pid)?.isTerminated ?? true else {
            return true                       // skip it this time, but keep tracking it
        }
        unreadableSince[slot] = nil
        forget(slot)
        return true
    }
    var hasPlacedWindows: Bool { !placed.isEmpty }
    var placedPIDs: Set<pid_t> { Set(placed.values.map(\.pid)) }
    /// While Atrium moves with its apps hidden, nothing follows live; `placeAllNow` puts everything in place at the end.
    var isSuspended = false

    /// Puts back any placed window that isn't where it should be (and leaves the rest untouched).
    func fixPositions() {
        for (slot, p) in placed where !isGone(slot, p) {
            if AX.bool(p.window, kAXMinimizedAttribute) == true { continue }
            apply(p.window, app: AX.app(p.pid))
        }
    }

    /// Moves every placed window to the current target right away (used after a move, while the apps are hidden).
    func placeAllNow() {
        let target = axTarget()
        liveSize.removeAll()
        for (slot, p) in placed {
            if isGone(slot, p) { continue }
            AX.setFrame(p.window, app: AX.app(p.pid), to: target)
        }
    }
    func placedWindow(_ slot: String) -> AXUIElement? { placed[slot]?.window }
    /// Which slot (if any) owns this window.
    func slot(for window: AXUIElement) -> String? { placed.first { CFEqual($0.value.window, window) }?.key }

    func appTerminated(pid: pid_t) {
        for (slot, p) in placed where p.pid == pid { forget(slot) }
    }

    /// Developer aid: drop every window, as if macOS had briefly lost them all (what happened on wake).
    func forgetAllForTesting() { for slot in Array(placed.keys) { forget(slot) } }

    func forget(_ slot: String) {
        guard placed.removeValue(forKey: slot) != nil else { return }
        liveSize[slot] = nil
        restoreTasks.removeValue(forKey: slot)?.cancel()
        if let g = guards.removeValue(forKey: slot) {
            Task { @MainActor in g.invalidate() }      // never tear down from inside its own callback
        }
        onWindowGone?(slot)
    }

    private func guardWindow(_ window: AXUIElement, pid: pid_t, slot: String) {
        if let old = guards.removeValue(forKey: slot) { old.invalidate() }
        guards[slot] = AXWindowObserver(
            pid: pid, element: window,
            notifications: [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification]
        ) { [weak self] name in self?.windowChangedExternally(slot: slot, notification: name) }
    }

    /// Debounced: wait until the user stops dragging/resizing, then fit it back. Our own moves land here too, but
    /// `apply` is a no-op when the window is already in place, so there is no feedback loop.
    private func windowChangedExternally(slot: String, notification: String) {
        if notification == kAXUIElementDestroyedNotification { forget(slot); return }
        // macOS 26 windows have a resize zone reaching outside their frame, over Atrium's edge: a drag there resizes
        // the app, not Atrium. Treat it as resizing Atrium (only while a button is held, so an app adjusting its own
        // size never moves Atrium).
        if notification == kAXResizedNotification, !isSuspended,
           NSEvent.pressedMouseButtons != 0 || userResizing.contains(slot),
           let p = placed[slot], let f = AX.frame(p.window), !matches(f, axTarget()) {
            userResizing.insert(slot)
            onUserResize?(slot, f)
        }
        restoreTasks[slot]?.cancel()
        restoreTasks[slot] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            while NSEvent.pressedMouseButtons != 0, !Task.isCancelled {      // never fight a drag still in progress
                try? await Task.sleep(for: .milliseconds(50))
            }
            // The app's last size often arrives just after the button is released: Atrium takes that one too.
            if !Task.isCancelled, let self, self.userResizing.remove(slot) != nil,
               let p = self.placed[slot], let f = AX.frame(p.window), !self.matches(f, self.axTarget()) {
                self.onUserResize?(slot, f)
            }
            guard !Task.isCancelled, let self, let p = self.placed[slot], !self.unfittable.contains(slot) else { return }
            self.apply(p.window, app: AX.app(p.pid))
            if let f = AX.frame(p.window), !self.matches(f, self.axTarget()) {
                self.unfittable.insert(slot)
                log.notice("\(slot, privacy: .public) won't take the target frame; leaving it until the next fit")
            }
        }
    }

    /// Target frame in AX coordinates, computed fresh every time.
    func axTarget() -> CGRect {
        let primary = NSScreen.screens.first?.frame ?? .zero
        return ScreenLayout.axRect(fromCocoa: workspaceRect(), primaryScreenFrame: primary)
    }

    /// Native apps: find the app's main window (waiting if it is launching or reopening) and fit it.
    /// `raise: false` places it quietly behind (used when preloading everything at startup).
    func snap(slot: String, pid: pid_t, launching: Bool, raise: Bool = true, restoreMinimized: Bool = true) {
        guard store.isAXTrusted else { return }
        tasks[slot]?.cancel()
        tasks[slot] = Task { await run(slot: slot, pid: pid, launching: launching, raise: raise, restoreMinimized: restoreMinimized) }
    }

    /// Awaitable variant (startup preloading places apps one by one).
    func snapAndWait(slot: String, pid: pid_t, launching: Bool, raise: Bool) async {
        await run(slot: slot, pid: pid, launching: launching, raise: raise)
    }

    private func run(slot: String, pid: pid_t, launching: Bool, raise: Bool, restoreMinimized: Bool = true) async {
        let app = AX.app(pid)
        let deadline = Date().addingTimeInterval(launching ? 20 : 5)
        var window: AXUIElement?
        while !Task.isCancelled, Date() < deadline {
            if let w = AX.primaryWindow(of: app) { window = w; break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        guard let window else { log.notice("no window for \(slot, privacy: .public) before timeout"); return }
        if !restoreMinimized, AX.bool(window, kAXMinimizedAttribute) == true { return }   // you minimized it: leave it
        await place(slot: slot, pid: pid, window: window, raise: raise)
    }

    /// A known window (web apps): fit it, guard it, and track it under `slot`.
    func place(slot: String, pid: pid_t, window: AXUIElement, raise: Bool = true) async {
        guard store.isAXTrusted else { return }
        guard !AX.isFullScreen(window) else { log.debug("\(slot, privacy: .public) is full screen; not snapping"); return }
        if AX.bool(window, kAXMinimizedAttribute) == true { AX.set(window, kAXMinimizedAttribute, false as CFBoolean) }
        let app = AX.app(pid)
        unfittable.remove(slot)
        apply(window, app: app)
        if placed[slot].map({ !CFEqual($0.window, window) }) ?? true {
            placed[slot] = Placed(pid: pid, window: window)
            guardWindow(window, pid: pid, slot: slot)
        }
        log.notice("placed \(slot, privacy: .public)")
        if raise {
            AX.raise(window)
            onSnapped?()
        }

        // Electron/Chromium apps restore their saved bounds shortly after showing a window: re-check twice.
        for delay in [300, 700] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard placed[slot] != nil else { return }
            apply(window, app: app)
        }
    }

    private func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    private func apply(_ window: AXUIElement, app: AXUIElement) {
        let target = axTarget()
        if let current = AX.frame(window), matches(current, target) { return }
        AX.setFrame(window, app: app, to: target)
    }

    /// Atrium moved or resized: carry every placed window along. The visible (active) one moves live (off the main
    /// thread, coalesced); the hidden ones (stacked behind Atrium) catch up once the drag pauses.
    func follow() {
        guard store.isAXTrusted, !placed.isEmpty, !isSuspended else { return }
        unfittable.removeAll()
        if let active = store.activeBundleID, let p = placed[active] {
            let target = axTarget()
            let resize = liveSize[active] != target.size
            liveSize[active] = target.size
            liveMover.move(p.window, to: target, resize: resize)
        }
        followTask?.cancel()
        followTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self.liveSize.removeAll()            // next drag re-sends size once, in case an app nudged it
            for (slot, p) in self.placed {
                if self.isGone(slot, p) { continue }
                self.apply(p.window, app: AX.app(p.pid))
            }
        }
    }

    /// The window-server number of the slot's window (public CGWindowList API; no permission needed).
    /// Placed windows sit exactly on the workspace rect, so match the owner pid + bounds; when several are stacked
    /// there (e.g. two Edge web apps), CGWindowList is front-to-back, so the first match is the visible one.
    func windowNumber(slot: String) -> Int? {
        guard let p = placed[slot] else { return nil }
        let target = AX.frame(p.window) ?? axTarget()      // AX and CG share top-left global coordinates
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == p.pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if abs(r.minX - target.minX) < 2, abs(r.minY - target.minY) < 2,
               abs(r.width - target.width) < 2, abs(r.height - target.height) < 2 { return number }
        }
        return nil
    }

    /// One read of the window order: the slot's window number, and whether `atrium` (Atrium's main window) is currently in
    /// FRONT of it, i.e. covering the app. Nil when the slot's window isn't on screen (minimized, hidden, another Space).
    func order(of slot: String, against atrium: Int) -> (number: Int, atriumInFront: Bool, atriumDirectlyBelow: Bool)? {
        guard let p = placed[slot] else { return nil }
        let target = AX.frame(p.window) ?? axTarget()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var atriumIndex: Int?
        var appMatch: (index: Int, number: Int)?
        for (index, w) in list.enumerated() {          // front to back
            guard let number = w[kCGWindowNumber as String] as? Int else { continue }
            if number == atrium {
                atriumIndex = index
                if appMatch != nil { break }
                continue
            }
            if appMatch != nil { continue }
            guard (w[kCGWindowOwnerPID as String] as? Int32) == p.pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if abs(r.minX - target.minX) < 2, abs(r.minY - target.minY) < 2,
               abs(r.width - target.width) < 2, abs(r.height - target.height) < 2 {
                if atriumIndex != nil { return (number, true, false) }      // Atrium is in front of (covering) the app
                appMatch = (index, number)
            }
        }
        guard let appMatch else { return nil }
        // Atrium right behind the app, with only Atrium's own windows (the rail) or none in between?
        var directlyBelow = false
        if let atriumIndex {
            directlyBelow = list[(appMatch.index + 1)..<atriumIndex].allSatisfy {
                ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() || ($0[kCGWindowLayer as String] as? Int) != 0
            }
        }
        return (appMatch.number, false, directlyBelow)
    }

    func raise(slot: String) {
        guard let p = placed[slot] else { return }
        AX.raise(p.window)
    }
}
