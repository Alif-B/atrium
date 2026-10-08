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

    init(store: AppStore, workspaceRect: @escaping @MainActor () -> CGRect) {
        self.store = store
        self.workspaceRect = workspaceRect
    }

    var snappedPIDs: Set<pid_t> { Set(snapped.keys) }
    func appTerminated(pid: pid_t) { snapped[pid] = nil }

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
        apply(window, app: app)
        snapped[pid] = window
        log.notice("snap complete for pid \(pid)")
        AX.raise(window)

        // Electron apps restore their saved bounds shortly after showing a window: re-check twice.
        for delay in [300, 700] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            apply(window, app: app)
        }
    }

    private func apply(_ window: AXUIElement, app: AXUIElement) {
        let target = axTarget()
        if let current = AX.frame(window),
           abs(current.minX - target.minX) < 1, abs(current.minY - target.minY) < 1,
           abs(current.width - target.width) < 1, abs(current.height - target.height) < 1 { return }
        AX.setFrame(window, app: app, to: target)
        log.notice("snapped to \(NSStringFromRect(target), privacy: .public)")
    }

    /// Atrium moved or resized: carry the active app's window along (live, throttled, with a trailing final apply).
    func follow() {
        guard store.isAXTrusted else { log.notice("follow: AX not trusted"); return }
        guard let id = store.activeBundleID else { log.notice("follow: no active app"); return }
        guard let pid = Launcher.runningApp(bundleID: id)?.processIdentifier else { log.notice("follow: \(id, privacy: .public) not running"); return }
        guard let window = snapped[pid] else { log.notice("follow: pid \(pid) was never snapped (snapped: \(self.snapped.keys.map { String($0) }.joined(separator: ","), privacy: .public))"); return }
        log.notice("follow: pid \(pid) target \(NSStringFromRect(self.axTarget()), privacy: .public) current \(NSStringFromRect(AX.frame(window) ?? .zero), privacy: .public)")
        let app = AX.app(pid)
        if Date().timeIntervalSince(lastFollow) > 0.04 {
            lastFollow = Date()
            apply(window, app: app)
        }
        followTask?.cancel()
        followTask = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            apply(window, app: app)
        }
    }

    /// Brings Atrium's window forward and then lifts the snapped app's window above it (they overlap in the workspace).
    func raiseSnapped(pid: pid_t) {
        guard let window = snapped[pid] else { return }
        AX.raise(window)
    }
}
