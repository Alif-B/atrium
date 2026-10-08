import AppKit
import ApplicationServices
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "snap")

/// Places an app's real window over Atrium's workspace rectangle, and keeps it there as Atrium moves/resizes.
@MainActor
final class WindowSnapper {
    private let store: AppStore
    private let workspaceRect: @MainActor () -> CGRect          // Cocoa screen coordinates
    private var snapped: [pid_t: AXUIElement] = [:]
    private var task: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var lastFollow = Date.distantPast
    /// Called after a window was fitted, so Atrium can slot itself under it.
    var onSnapped: (@MainActor () -> Void)?

    init(store: AppStore, workspaceRect: @escaping @MainActor () -> CGRect) {
        self.store = store
        self.workspaceRect = workspaceRect
    }

    /// Watches each placed window: if the user moves or resizes it by hand, put it back (Atrium owns the geometry).
    private var guards: [pid_t: AXWindowObserver] = [:]
    private var restoreTasks: [pid_t: Task<Void, Never>] = [:]
    /// Windows that refused the target size (e.g. an app minimum larger than Atrium's area). We stop fighting them
    /// until the next snap or Atrium move, so we never loop forever.
    private var unfittable: Set<pid_t> = []

    var snappedPIDs: Set<pid_t> { Set(snapped.keys) }

    func appTerminated(pid: pid_t) { forget(pid) }

    private func forget(_ pid: pid_t) {
        snapped[pid] = nil
        restoreTasks.removeValue(forKey: pid)?.cancel()
        if let g = guards.removeValue(forKey: pid) {
            Task { @MainActor in g.invalidate() }      // never tear down from inside its own callback
        }
    }

    private func guardWindow(_ window: AXUIElement, pid: pid_t) {
        if let old = guards.removeValue(forKey: pid) { old.invalidate() }
        guards[pid] = AXWindowObserver(
            pid: pid, element: window,
            notifications: [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification]
        ) { [weak self] name in self?.windowChangedExternally(pid: pid, notification: name) }
    }

    /// Debounced: wait until the user stops dragging/resizing, then fit it back. Our own moves land here too, but
    /// `apply` is a no-op when the window is already in place, so there is no feedback loop.
    private func windowChangedExternally(pid: pid_t, notification: String) {
        if notification == kAXUIElementDestroyedNotification { forget(pid); return }
        restoreTasks[pid]?.cancel()
        restoreTasks[pid] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let window = self.snapped[pid], !self.unfittable.contains(pid) else { return }
            self.apply(window, app: AX.app(pid))
            if let f = AX.frame(window), !self.matches(f, self.axTarget()) {
                self.unfittable.insert(pid)
                log.notice("pid \(pid) won't take the target frame; leaving it until the next fit")
            }
        }
    }

    /// Target frame in AX coordinates, computed fresh every time.
    private func axTarget() -> CGRect {
        let primary = NSScreen.screens.first?.frame ?? .zero
        return ScreenLayout.axRect(fromCocoa: workspaceRect(), primaryScreenFrame: primary)
    }

    /// Finds the app's main window (waiting for it if the app is launching or reopening) and fits it to the workspace.
    func snap(pid: pid_t, launching: Bool) {
        guard store.isAXTrusted else { return }
        task?.cancel()
        task = Task { await run(pid: pid, launching: launching) }
    }

    private func run(pid: pid_t, launching: Bool) async {
        let app = AX.app(pid)
        let deadline = Date().addingTimeInterval(launching ? 20 : 5)
        var window: AXUIElement?
        while !Task.isCancelled, Date() < deadline {
            if let w = AX.primaryWindow(of: app) { window = w; break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        guard let window else { log.notice("no window for pid \(pid) before timeout"); return }
        guard !AX.isFullScreen(window) else { log.debug("pid \(pid) is full screen; not snapping"); return }

        if AX.bool(window, kAXMinimizedAttribute) == true { AX.set(window, kAXMinimizedAttribute, false as CFBoolean) }
        unfittable.remove(pid)
        apply(window, app: app)
        snapped[pid] = window
        guardWindow(window, pid: pid)
        log.notice("snap complete for pid \(pid)")
        AX.raise(window)
        onSnapped?()

        // Electron apps restore their saved bounds shortly after showing a window: re-check twice.
        for delay in [300, 700] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
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
        log.notice("snapped to \(NSStringFromRect(target), privacy: .public)")
    }

    /// Atrium moved or resized: carry every placed window along. The visible (active) one moves live, throttled;
    /// the hidden ones (stacked behind Atrium) catch up once the drag pauses, which keeps dragging smooth.
    func follow() {
        guard store.isAXTrusted, !snapped.isEmpty else { return }
        unfittable.removeAll()
        let activePID = store.activeBundleID.flatMap { Launcher.runningApp(bundleID: $0)?.processIdentifier }
        if let activePID, let window = snapped[activePID], Date().timeIntervalSince(lastFollow) > 0.04 {
            lastFollow = Date()
            apply(window, app: AX.app(activePID))
        }
        followTask?.cancel()
        followTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            for (pid, window) in snapped {
                if AX.frame(window) == nil { forget(pid); continue }          // window was closed
                apply(window, app: AX.app(pid))
            }
        }
    }

    /// The window-server number of the app's largest normal on-screen window (public CGWindowList API; no permission needed).
    func windowNumber(pid: pid_t) -> Int? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (number: Int, area: Double)?
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
            let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
            if area > (best?.area ?? 0) { best = (number, area) }
        }
        return best?.number
    }

    /// Brings Atrium's window forward and then lifts the snapped app's window above it (they overlap in the workspace).
    func raiseSnapped(pid: pid_t) {
        guard let window = snapped[pid] else { return }
        AX.raise(window)
    }
}
