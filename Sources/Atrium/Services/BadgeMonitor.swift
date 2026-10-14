import AppKit
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "badges")

/// Keeps `store.badges` current and plays a short sound when something new arrives for an app you're not looking at.
///  - Native apps: the badge on their Dock tile.
///  - Web apps (they run inside Atrium, with no Dock tile): an unread count in the page title, e.g. "Inbox (3)".
@MainActor
final class BadgeMonitor {
    private let store: AppStore
    private let prefs: Preferences
    private let webTitle: @MainActor (String) -> String?
    private let dock = DockItems()
    private var task: Task<Void, Never>?
    private var primed = false                    // the first reading is the baseline: never a sound
    private var lastSound = Date.distantPast
    private var sound: NSSound?

    init(store: AppStore, prefs: Preferences, webTitle: @escaping @MainActor (String) -> String?) {
        self.store = store
        self.prefs = prefs
        self.webTitle = webTitle
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.store.isAXTrusted && self.prefs.showBadges
                if active { self.poll() } else { self.clearIfOff() }
                try? await Task.sleep(for: .seconds(active ? 2 : 5), tolerance: .milliseconds(500))
            }
        }
    }

    /// Bypasses the wait (used by the Settings "try the sound" button).
    func preview(soundNamed name: String) { play(name) }

    private func clearIfOff() {
        if !store.badges.isEmpty && !prefs.showBadges { store.badges = [:] }
        primed = false
    }

    /// Holds blinking title badges steady and decides when something is genuinely new (see BadgeTracker).
    private var tracker = BadgeTracker()

    private func poll() {
        let dockBadges = dock.badges()
        var readings: [String: BadgeText?] = [:]
        var titleBased: Set<String> = []
        for app in store.apps {
            let id = app.bundleIdentifier
            if app.isWebApp {
                titleBased.insert(id)
                readings[id] = webTitle(id).flatMap(TitleBadge.parse)
            } else {
                readings[id] = dockBadges[id].flatMap(BadgeText.parse)
            }
        }
        let inView = Set(store.apps.map(\.bundleIdentifier).filter(isInView))
        let result = tracker.update(now: ProcessInfo.processInfo.systemUptime, readings: readings, titleBased: titleBased,
                                    shown: store.badges, inView: inView)
        primed = true
        guard result.badges != store.badges else { return }
        store.badges = result.badges
        log.notice("badges now: \(result.badges.map { "\($0.key)=\($0.value.display.isEmpty ? "dot" : $0.value.display)" }.sorted().joined(separator: ", "), privacy: .public) (dock saw \(dockBadges.count))")
        if result.newArrival, prefs.playBadgeSound { playThrottled() }
    }

    /// No sound for an app you're already looking at (it is in front, inside Atrium).
    private func isInView(_ id: String) -> Bool {
        guard store.activeBundleID == id else { return false }
        if app(id)?.isWebApp == true { return NSApp.isActive }                 // its page shows in Atrium, in front
        return Launcher.runningApp(bundleID: id)?.isActive == true
    }

    private func app(_ id: String) -> ManagedApp? { store.apps.first { $0.bundleIdentifier == id } }

    private func playThrottled() {
        guard Date().timeIntervalSince(lastSound) > 2 else { return }          // a burst makes one sound, not five
        lastSound = Date()
        play(prefs.badgeSoundName)
    }

    private func play(_ name: String) {
        sound?.stop()
        sound = NSSound(named: NSSound.Name(name))
        sound?.play()
    }
}
