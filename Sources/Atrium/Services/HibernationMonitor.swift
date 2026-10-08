import AppKit
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "hibernation")

/// Quits apps that opted in to hibernation once they have gone unused for 15 minutes. "In use" means the app is the one
/// showing in Atrium while you look at Atrium, or it is the frontmost app itself. Native apps get a normal quit request
/// (so they can ask to save); a web app's window is closed.
@MainActor
final class HibernationMonitor {
    private let store: AppStore
    private let closeWebApp: @MainActor (ManagedApp) -> Void
    private var lastUsed: [String: TimeInterval] = [:]
    private var task: Task<Void, Never>?

    init(store: AppStore, closeWebApp: @escaping @MainActor (ManagedApp) -> Void) {
        self.store = store
        self.closeWebApp = closeWebApp
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(5))
                self?.check()
            }
        }
    }

    private func isInUse(_ app: ManagedApp) -> Bool {
        guard store.activeBundleID == app.bundleIdentifier else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        let host = app.browserBundleID ?? app.bundleIdentifier          // a web app lives in its browser
        return front == Bundle.main.bundleIdentifier || front == host
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        for app in store.apps {
            let id = app.bundleIdentifier
            guard app.hibernates, store.runningBundleIDs.contains(id) else { lastUsed[id] = nil; continue }
            if isInUse(app) || lastUsed[id] == nil { lastUsed[id] = now; continue }
            guard let last = lastUsed[id], Hibernation.shouldHibernate(now: now, lastUsed: last) else { continue }
            log.notice("hibernating \(id, privacy: .public)")
            lastUsed[id] = nil
            if app.isWebApp {
                closeWebApp(app)
            } else {
                Launcher.runningApp(bundleID: id)?.terminate()
            }
        }
    }
}
