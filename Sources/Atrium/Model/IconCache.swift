import AppKit

/// App icons are cached by path so they never pop in after first display.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(forPath path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
