import AppKit
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "badges")

/// Keeps `store.badges` current and plays a short sound when something new arrives for an app you're not looking at.
///  - Native apps: the badge on their Dock tile.
///  - Web apps (Edge windows have no Dock badge): an unread count in the page title, e.g. "Inbox (3)".
@MainActor
final class BadgeMonitor {
    private let store: AppStore
    private let prefs: Preferences
    private let snapper: WindowSnapper
    private let dock = DockItems()
    private var task: Task<Void, Never>?
    private var primed = false                    // the first reading is the baseline: never a sound
    private var lastSound = Date.distantPast
    private var sound: NSSound?

    init(store: AppStore, prefs: Preferences, snapper: WindowSnapper) {
        self.store = store
        self.prefs = prefs
        self.snapper = snapper
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

    private func poll() {
        let dockBadges = dock.badges()
        var next: [String: BadgeText] = [:]
        for app in store.apps {
            let id = app.bundleIdentifier
            if app.isWebApp {
                if let window = snapper.placedWindow(id), let title = AX.string(window, kAXTitleAttribute),
                   let badge = TitleBadge.parse(title) { next[id] = badge }
            } else if let raw = dockBadges[id], let badge = BadgeText.parse(raw) {
                next[id] = badge
            }
        }
        let previous = store.badges
        guard next != previous else { primed = true; return }

        // Something is new when a count went up, or a badge appeared where there was none.
        var arrived: [String] = []
        for (id, badge) in next where primed && isNew(badge, over: previous[id]) && !isInView(id) { arrived.append(id) }
        store.badges = next
        primed = true
        log.notice("badges now: \(next.map { "\($0.key)=\($0.value.display.isEmpty ? "dot" : $0.value.display)" }.sorted().joined(separator: ", "), privacy: .public) (dock saw \(dockBadges.count))")
        if !arrived.isEmpty, prefs.playBadgeSound { playThrottled() }
    }

    private func isNew(_ badge: BadgeText, over old: BadgeText?) -> Bool {
        guard let old else { return true }
        if case .count(let n) = badge, case .count(let m) = old { return n > m }
        return false
    }

    /// No sound for an app you're already looking at (it is in front, inside Atrium).
    private func isInView(_ id: String) -> Bool {
        guard store.activeBundleID == id else { return false }
        if app(id)?.isWebApp == true { return NSApp.isActive == false }        // its window is the front one only if Atrium isn't
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
