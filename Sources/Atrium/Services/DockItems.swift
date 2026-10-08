import AppKit

/// The Dock's own list of apps, read through Accessibility. Each running app's tile carries its notification badge
/// (`AXStatusLabel`), which is how unread counts of native apps are read. The Dock posts no reliable "badge changed"
/// notification, so callers poll.
@MainActor
final class DockItems {
    private var dockPID: pid_t = 0
    private var items: [String: AXUIElement] = [:]          // bundle id → Dock tile element
    private var bundleIDForURL: [URL: String] = [:]

    /// Rebuilds the cache when the Dock restarted or it was never filled.
    func refreshIfNeeded(force: Bool = false) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { items = [:]; return }
        guard force || dock.processIdentifier != dockPID || items.isEmpty else { return }
        dockPID = dock.processIdentifier
        let dockElement = AX.app(dockPID)
        AXUIElementSetMessagingTimeout(dockElement, 0.25)
        var map: [String: AXUIElement] = [:]
        for list in AX.elements(dockElement, kAXChildrenAttribute) where AX.string(list, kAXRoleAttribute) == kAXListRole {
            for item in AX.elements(list, kAXChildrenAttribute) where AX.string(item, kAXSubroleAttribute) == "AXApplicationDockItem" {
                guard let url = (AX.attribute(item, kAXURLAttribute) as? NSURL) as URL? else { continue }   // may end in a slash
                let id = bundleIDForURL[url] ?? Bundle(url: url)?.bundleIdentifier
                guard let id else { continue }
                bundleIDForURL[url] = id
                map[id] = item
            }
        }
        items = map
    }

    /// Raw badge strings by bundle id (only apps with a non-empty badge).
    func badges() -> [String: String] {
        refreshIfNeeded()
        var result: [String: String] = [:]
        var stale = false
        for (id, item) in items {
            guard let label = AX.attribute(item, "AXStatusLabel") else {
                if AX.attribute(item, kAXRoleAttribute) == nil { stale = true }       // the tile went away
                continue
            }
            if let text = label as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { result[id] = text }
        }
        if stale { refreshIfNeeded(force: true) }
        return result
    }
}
