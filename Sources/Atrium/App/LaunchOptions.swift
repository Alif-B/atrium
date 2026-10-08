import Foundation

/// Debug flags read from the command line, e.g. `./scripts/run.sh --demo`.
enum LaunchOptions {
    /// In-memory store with sample items from real installed apps; never writes apps.json or registers a login item.
    static let demo = CommandLine.arguments.contains("--demo")
    /// Turns off the lens "lift" into glass so the fill-only lens can be compared (§7.5).
    static let lensFillOnly = CommandLine.arguments.contains("--lens-fill-only")
    /// Glass variant (b): force the active appearance on the SwiftUI glass (§7.3).
    static let glassActive = CommandLine.arguments.contains("--glass-active")
    /// Glass variant (c): NSGlassEffectView as the rail background (§7.3).
    static let appKitGlass = CommandLine.arguments.contains("--appkit-glass")
}
