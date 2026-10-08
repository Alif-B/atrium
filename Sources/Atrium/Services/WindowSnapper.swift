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

    /// Called after a window was fitted, so Atrium can slot itself under it.
    var onSnapped: (@MainActor () -> Void)?
    /// Called when a placed window is closed (so web apps can show as "not running").
    var onWindowGone: (@MainActor (String) -> Void)?

    init(store: AppStore, workspaceRect: @escaping @MainActor () -> CGRect) {
        self.store = store
        self.workspaceRect = workspaceRect
    }

    func isPlaced(_ slot: String) -> Bool { placed[slot] != nil }
    func placedWindow(_ slot: String) -> AXUIElement? { placed[slot]?.window }
    /// Which slot (if any) owns this window.
    func slot(for window: AXUIElement) -> String? { placed.first { CFEqual($0.value.window, window) }?.key }

    func appTerminated(pid: pid_t) {
        for (slot, p) in placed where p.pid == pid { forget(slot) }
    }

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
        restoreTasks[slot]?.cancel()
        restoreTasks[slot] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
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
    func snap(slot: String, pid: pid_t, launching: Bool, raise: Bool = true) {
        guard store.isAXTrusted else { return }
        tasks[slot]?.cancel()
        tasks[slot] = Task { await run(slot: slot, pid: pid, launching: launching, raise: raise) }
    }

    /// Awaitable variant (startup preloading places apps one by one).
    func snapAndWait(slot: String, pid: pid_t, launching: Bool, raise: Bool) async {
        await run(slot: slot, pid: pid, launching: launching, raise: raise)
    }

    private func run(slot: String, pid: pid_t, launching: Bool, raise: Bool) async {
        let app = AX.app(pid)
        let deadline = Date().addingTimeInterval(launching ? 20 : 5)
        var window: AXUIElement?
        while !Task.isCancelled, Date() < deadline {
            if let w = AX.primaryWindow(of: app) { window = w; break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        guard let window else { log.notice("no window for \(slot, privacy: .public) before timeout"); return }
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
        guard store.isAXTrusted, !placed.isEmpty else { return }
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
                if AX.frame(p.window) == nil { self.forget(slot); continue }          // window was closed
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

    func raise(slot: String) {
        guard let p = placed[slot] else { return }
        AX.raise(p.window)
    }
}
