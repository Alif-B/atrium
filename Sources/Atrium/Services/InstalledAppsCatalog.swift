import Foundation

struct InstalledApp: Sendable, Identifiable, Hashable {
    var bundleID: String
    var name: String
    var path: String
    var id: String { bundleID }
}

enum InstalledAppsCatalog {
    static let suggestedBundleIDs: [String] = [
        "com.tinyspeck.slackmacgap", "com.anthropic.claudefordesktop", "notion.id",
        "com.anysphere.sand", "com.microsoft.Outlook", "com.meta.endo",
    ]
    static let safariWebAppPrefix = "com.apple.Safari.WebApp."
    static let browserPWAPrefixes = ["com.microsoft.edgemac.app.", "com.google.Chrome.app."]

    static func isSafariWebApp(_ app: InstalledApp) -> Bool { app.bundleID.hasPrefix(safariWebAppPrefix) }
    static func isBrowserPWA(_ app: InstalledApp) -> Bool { browserPWAPrefixes.contains { app.bundleID.hasPrefix($0) } }

    /// Scans off the main thread and returns Sendable values.
    static func scan() async -> [InstalledApp] {
        await Task.detached(priority: .userInitiated) { scanSync() }.value
    }

    private static func scanSync() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        var seen = Set<String>()
        var result: [InstalledApp] = []

        func visit(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier,
                          id != "com.alif.atrium", seen.insert(id).inserted else { continue }
                    let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? (name as NSString).deletingPathExtension
                    result.append(InstalledApp(bundleID: id, name: display, path: path))
                } else if depth == 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { visit(path, depth: 1) }
                }
            }
        }
        for root in roots { visit(root, depth: 0) }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
