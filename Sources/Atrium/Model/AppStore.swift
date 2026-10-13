import AppKit
import Observation
import OSLog
import AtriumCore

private let log = Logger(subsystem: "com.alif.atrium", category: "store")

@MainActor @Observable
final class AppStore {
    var apps: [ManagedApp]
    var runningBundleIDs: Set<String> = []
    var activeBundleID: String? {
        didSet {
            if let state = emptyState, state.appID != activeBundleID {
                emptyState = nil                                                     // moved on
                Logger(subsystem: "com.alif.atrium", category: "store").notice("card cleared: active is now \(self.activeBundleID ?? "none", privacy: .public)")
            }
        }
    }
    /// What Atrium's workspace shows while the selected app has no window (opening, quit, asleep).
    var emptyState: EmptyState?
    /// Apps just put to sleep by hibernation (so their exit reads "asleep", not "quit").
    @ObservationIgnored var recentlyHibernated: Set<String> = []
    var launchingBundleIDs: Set<String> = []
    var badges: [String: BadgeText] = [:]
    var isAXTrusted = false

    /// Nil for the in-memory demo store: it never touches apps.json.
    @ObservationIgnored private let storageURL: URL?

    init(apps: [ManagedApp] = [], storageURL: URL? = nil) {
        self.apps = apps
        self.storageURL = storageURL
    }

    var activeIndex: Int? { apps.firstIndex { $0.bundleIdentifier == activeBundleID } }

    // MARK: Persistence

    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atrium", isDirectory: true)
            .appendingPathComponent("apps.json")
    }

    static func persistent() -> AppStore {
        let url = defaultStorageURL
        let result = AppLibrary.load(from: url)
        if let backup = result.corruptBackup { log.error("apps.json was corrupt; moved to \(backup.path, privacy: .public)") }
        return AppStore(apps: result.library.apps, storageURL: url)
    }

    private func commit(_ library: AppLibrary) {
        apps = library.apps
        urlCache.removeAll()
        guard let storageURL else { return }
        do { try library.save(to: storageURL) } catch { log.error("save failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Editing

    func contains(bundleID: String) -> Bool { apps.contains { $0.bundleIdentifier == bundleID } }

    @discardableResult
    func add(_ app: ManagedApp) -> Bool {
        var library = AppLibrary(apps: apps)
        let added = library.add(app)
        if added { commit(library) }
        return added
    }

    func remove(bundleID: String) {
        var library = AppLibrary(apps: apps)
        library.remove(bundleIdentifier: bundleID)
        commit(library)
        if activeBundleID == bundleID { activeBundleID = nil }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var library = AppLibrary(apps: apps)
        library.move(fromOffsets: source, toOffset: destination)
        commit(library)
    }

    func update(bundleID: String, _ change: (inout ManagedApp) -> Void) {
        var library = AppLibrary(apps: apps)
        library.update(bundleIdentifier: bundleID, change)
        commit(library)
    }

    // MARK: Resolution

    /// bundle id first, then the last known path.
    /// Where each app lives. Asking Launch Services is cheap but not free, and the rail asks for every app on every
    /// redraw, so answers are kept for 30 s (and dropped whenever the app list changes).
    @ObservationIgnored private var urlCache: [String: (url: URL?, at: Date)] = [:]

    func resolvedURL(for app: ManagedApp) -> URL? {
        if let hit = urlCache[app.bundleIdentifier], Date().timeIntervalSince(hit.at) < 30 { return hit.url }
        let url = lookUpURL(for: app)
        urlCache[app.bundleIdentifier] = (url, Date())
        return url
    }

    private func lookUpURL(for app: ManagedApp) -> URL? {
        if app.isWebApp {        // a web app "exists" while its browser is installed
            return app.browserBundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) { return url }
        return FileManager.default.fileExists(atPath: app.lastKnownPath) ? URL(fileURLWithPath: app.lastKnownPath) : nil
    }

    func isMissing(_ app: ManagedApp) -> Bool { resolvedURL(for: app) == nil }

    func icon(for app: ManagedApp) -> NSImage {
        if let file = app.iconFile, let image = IconCache.shared.image(atPath: file) { return image }
        return IconCache.shared.icon(forPath: resolvedURL(for: app)?.path ?? app.lastKnownPath)
    }

    // MARK: Demo

    /// `--demo`: real installed apps with fake running/active/badge states.
    static func demo() -> AppStore {
        let wanted = [
            "com.tinyspeck.slackmacgap", "com.anthropic.claudefordesktop", "notion.id",
            "com.microsoft.Outlook", "com.anysphere.sand", "com.meta.endo", "com.apple.Safari",
        ]
        var apps: [ManagedApp] = []
        for id in wanted {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            apps.append(ManagedApp(bundleIdentifier: id, displayName: name, lastKnownPath: url.path))
        }
        let store = AppStore(apps: apps)
        let ids = apps.map(\.bundleIdentifier)
        store.runningBundleIDs = Set(ids.prefix(4))
        if ids.count > 4 { store.launchingBundleIDs = [ids[4]] }
        store.activeBundleID = ids.dropFirst().first
        if let first = ids.first { store.badges[first] = .count(3) }
        if ids.count > 3 { store.badges[ids[3]] = .dot }
        if ids.count > 2 { store.badges[ids[2]] = .count(120) }
        return store
    }
}
