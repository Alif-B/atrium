import Foundation

/// The ordered list of managed apps plus its JSON persistence. Pure logic, no AppKit.
public struct AppLibrary: Equatable, Sendable {
    public private(set) var apps: [ManagedApp]

    public init(apps: [ManagedApp] = []) { self.apps = apps }

    /// Returns false (and does nothing) when the bundle id is already present.
    @discardableResult
    public mutating func add(_ app: ManagedApp) -> Bool {
        guard !apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return false }
        apps.append(app)
        return true
    }

    public mutating func remove(bundleIdentifier: String) {
        apps.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Same semantics as SwiftUI's `onMove`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { apps[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { apps.remove(at: index) }
        apps.insert(contentsOf: moving, at: destination - before)
    }

    public mutating func update(bundleIdentifier: String, _ change: (inout ManagedApp) -> Void) {
        guard let i = apps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        change(&apps[i])
    }

    // MARK: Persistence

    public struct LoadResult: Sendable {
        public var library: AppLibrary
        /// Set when the file existed but couldn't be decoded; it was renamed to this URL.
        public var corruptBackup: URL?
    }

    /// Missing file → empty library. Corrupt file → renamed to `apps.corrupt-<timestamp>.json`, empty library.
    public static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return LoadResult(library: AppLibrary(), corruptBackup: nil) }
        do {
            let apps = try JSONDecoder().decode([ManagedApp].self, from: data)
            return LoadResult(library: AppLibrary(apps: apps), corruptBackup: nil)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent().appendingPathComponent("apps.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return LoadResult(library: AppLibrary(), corruptBackup: backup)
        }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(apps).write(to: url, options: .atomic)
    }
}
