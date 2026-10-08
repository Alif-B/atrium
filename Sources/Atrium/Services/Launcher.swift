import AppKit

@MainActor
enum Launcher {
    /// Launches if needed; for a running app, activates it and sends "reopen" (creates a window if none).
    /// NSWorkspace handles cooperative activation for us (macOS 14+).
    @discardableResult
    static func open(_ url: URL, activate: Bool = true, hide: Bool = false) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        config.hides = hide
        return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
}
