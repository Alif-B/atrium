import Foundation

/// Debug flags read from the command line, e.g. `./scripts/run.sh --demo`.
enum LaunchOptions {
    /// In-memory store with sample items from real installed apps; never writes apps.json or registers a login item.
    static let demo = CommandLine.arguments.contains("--demo")

    /// `--debug-follow=<bundle id>`: switch to that app, then move Atrium's window programmatically (see AppDelegate).
    static let debugFollow: String? = CommandLine.arguments.first { $0.hasPrefix("--debug-follow=") }.map { String($0.dropFirst(15)) }
    /// With `--debug-follow`: instead of moving the window, simulate a click that brings Atrium in front of the app.
    static let debugOrder = CommandLine.arguments.contains("--debug-order")
    /// `--debug-icon=<input image>:<output png>[:scale]`: render a picture through the web-app icon pipeline, then quit.
    static let debugIcon: String? = CommandLine.arguments.first { $0.hasPrefix("--debug-icon=") }.map { String($0.dropFirst(13)) }
    /// Opens the Settings window at launch (used to verify it opens).
    static let debugSettings = CommandLine.arguments.contains("--debug-settings")
}
