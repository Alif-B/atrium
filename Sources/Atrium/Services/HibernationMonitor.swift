import AppKit
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "hibernation")

/// Quits apps that opted in to hibernation once they have gone unused for 15 minutes. "In use" means the app is the one
/// showing in Atrium while you look at Atrium, or it is the frontmost app itself. Native apps get a normal quit request
/// (so they can ask to save); a web app's page is unloaded.
@MainActor
final class HibernationMonitor {
    private let store: AppStore
    private let closeWebApp: @MainActor (ManagedApp) async -> Bool
    private let webAppBusy: @MainActor (String) -> Bool
    private let idleLimit: TimeInterval
    private var lastUsed: [String: TimeInterval] = [:]
    private var task: Task<Void, Never>?

    init(store: AppStore, closeWebApp: @escaping @MainActor (ManagedApp) async -> Bool,
         webAppBusy: @escaping @MainActor (String) -> Bool, idleLimit: TimeInterval = Hibernation.idleLimit) {
        self.store = store
        self.closeWebApp = closeWebApp
        self.webAppBusy = webAppBusy
        self.idleLimit = idleLimit
        let interval = min(30, max(2, idleLimit / 6))             // check often enough to be on time
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 6))
                self?.check()
            }
        }
    }

    /// In use = you're looking at it, or it is making sound / using the camera or microphone (music, a call).
    private func isInUse(_ app: ManagedApp, audio: Set<String>) -> Bool {
        let id = app.bundleIdentifier
        if app.isWebApp {                                              // it lives inside Atrium
            return webAppBusy(id) || (store.activeBundleID == id && NSApp.isActive)
        }
        if audio.contains(id) { return true }
        guard store.activeBundleID == id, let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return front == Bundle.main.bundleIdentifier || front == id
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        guard store.apps.contains(where: { $0.hibernates }) else { return }
        let audio = AudioActivity.appsUsingAudio()
        for app in store.apps {
            let id = app.bundleIdentifier
            guard app.hibernates, store.runningBundleIDs.contains(id) else { lastUsed[id] = nil; continue }
            if isInUse(app, audio: audio) || lastUsed[id] == nil { lastUsed[id] = now; continue }
            guard let last = lastUsed[id], Hibernation.shouldHibernate(now: now, lastUsed: last, limit: idleLimit) else { continue }
            log.notice("hibernating \(id, privacy: .public)")
            store.recentlyHibernated.insert(id)
            lastUsed[id] = nil
            if app.isWebApp {
                Task { if await !closeWebApp(app) { lastUsed[id] = now } }      // still open: try again later
            } else if let running = Launcher.runningApp(bundleID: id) {
                running.terminate()                              // a normal Quit: the app may ask to save first
            }
        }
    }
}
