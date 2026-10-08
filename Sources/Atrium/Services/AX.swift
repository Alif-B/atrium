import AppKit
import ApplicationServices

@MainActor
enum AX {
    /// Literal key string: the `kAXTrustedCheckOptionPrompt` global is not concurrency-safe in Swift 6.
    nonisolated static func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { attribute(el, name) as? String }
    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { (attribute(el, name) as? NSNumber)?.boolValue }
    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] { (attribute(el, name) as? [AXUIElement]) ?? [] }
    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(v, to: AXUIElement.self)
    }
    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Largest non-minimized standard window (skips compose/call/dialog windows).
    /// Main/focused first: kAXWindowsAttribute is filtered to the current Space, they aren't.
    static func primaryWindow(of app: AXUIElement) -> AXUIElement? {
        var all: [AXUIElement] = [element(app, kAXMainWindowAttribute), element(app, kAXFocusedWindowAttribute)].compactMap { $0 }
        for w in elements(app, kAXWindowsAttribute) where !all.contains(where: { CFEqual($0, w) }) { all.append(w) }
        let standard = all.filter { string($0, kAXRoleAttribute) == kAXWindowRole && string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
        let visible = standard.filter { bool($0, kAXMinimizedAttribute) != true }
        return visible.max { area(frame($0)) < area(frame($1)) } ?? standard.first
    }
    private static func area(_ r: CGRect?) -> CGFloat { (r?.width ?? 0) * (r?.height ?? 0) }

    /// Presses the first enabled menu-bar item whose title matches (e.g. Edge's "Reload This Page"). Acts on the app's
    /// focused window, like choosing it from the menu.
    @discardableResult
    static func pressMenuItem(in pid: pid_t, where matches: (String) -> Bool) -> Bool {
        guard let bar = element(app(pid), kAXMenuBarAttribute) else { return false }
        for barItem in elements(bar, kAXChildrenAttribute) {
            for menu in elements(barItem, kAXChildrenAttribute) {
                for item in elements(menu, kAXChildrenAttribute) {
                    guard let title = string(item, kAXTitleAttribute), matches(title), bool(item, kAXEnabledAttribute) != false else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool { bool(window, "AXFullScreen") == true }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        set(window, kAXMainAttribute, true as CFBoolean)
    }

    /// `frame` is in AX coordinates (top-left origin of the primary screen). Order: size → position → size
    /// (macOS clamps a size to the display the window is currently on).
    static func setFrame(_ window: AXUIElement, app: AXUIElement, to frame: CGRect) {
        let enhanced = bool(app, "AXEnhancedUserInterface") ?? false
        if enhanced { set(app, "AXEnhancedUserInterface", false as CFBoolean) }   // avoids animated/partial resizes
        defer { if enhanced { set(app, "AXEnhancedUserInterface", true as CFBoolean) } }
        var size = frame.size, origin = frame.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &origin) else { return }
        set(window, kAXSizeAttribute, s)
        set(window, kAXPositionAttribute, p)
        set(window, kAXSizeAttribute, s)
    }
}
