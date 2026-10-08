import AppKit
import Observation
import AtriumCore

@MainActor @Observable
final class AppStore {
    var apps: [ManagedApp]
    var runningBundleIDs: Set<String> = []
    var activeBundleID: String?
    var launchingBundleIDs: Set<String> = []
    var badges: [String: BadgeText] = [:]
    var isAXTrusted = false

    init(apps: [ManagedApp] = []) { self.apps = apps }

    var activeIndex: Int? { apps.firstIndex { $0.bundleIdentifier == activeBundleID } }

    /// bundle id first, then the last known path.
    func resolvedURL(for app: ManagedApp) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) { return url }
        return FileManager.default.fileExists(atPath: app.lastKnownPath) ? URL(fileURLWithPath: app.lastKnownPath) : nil
    }

    func isMissing(_ app: ManagedApp) -> Bool { resolvedURL(for: app) == nil }

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
