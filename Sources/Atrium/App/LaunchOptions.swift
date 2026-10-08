import Foundation

/// Debug flags read from the command line, e.g. `./scripts/run.sh --demo`.
enum LaunchOptions {
    /// In-memory store with sample items from real installed apps; never writes apps.json or registers a login item.
    static let demo = CommandLine.arguments.contains("--demo")

    /// `--debug-follow=<bundle id>`: switch to that app, then move Atrium's window programmatically (see AppDelegate).
    static let debugFollow: String? = CommandLine.arguments.first { $0.hasPrefix("--debug-follow=") }.map { String($0.dropFirst(15)) }
}
