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
    /// With `--debug-follow`: simulate clicking Atrium's empty area while no sidebar app is current.
    static let debugEmptyClick = CommandLine.arguments.contains("--debug-empty-click")
    /// With `--debug-follow`: open Settings, then close it (the "Atrium goes empty after Settings" case).
    static let debugSettingsClose = CommandLine.arguments.contains("--debug-settings-close")
    /// `--debug-click=<from id>:<to id>`: show <from>, then post a real mouse click on <to>'s rail icon while recording
    /// the window order every few ms, to see whether Atrium's window ever covers the app (the "blip").
    static let debugClick: String? = CommandLine.arguments.first { $0.hasPrefix("--debug-click=") }.map { String($0.dropFirst(14)) }
    /// `--debug-drag`: post a real drag on empty rail space; log how far the window and the rail moved.
    static let debugDrag = CommandLine.arguments.contains("--debug-drag")
    /// Opens the Settings window at launch (used to verify it opens).
    static let debugSettings = CommandLine.arguments.contains("--debug-settings")
}
