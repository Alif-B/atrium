import AppKit
import Observation
import OSLog
import AtriumCore

private let log = Logger(subsystem: "com.alif.atrium", category: "store")

@MainActor @Observable
final class AppStore {
    var apps: [ManagedApp]
    var runningBundleIDs: Set<String> = []
    var activeBundleID: String?
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
    func resolvedURL(for app: ManagedApp) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) { return url }
        return FileManager.default.fileExists(atPath: app.lastKnownPath) ? URL(fileURLWithPath: app.lastKnownPath) : nil
    }

    func isMissing(_ app: ManagedApp) -> Bool { resolvedURL(for: app) == nil }

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
