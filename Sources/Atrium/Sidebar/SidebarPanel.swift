import AppKit
import SwiftUI

/// The main Atrium window: borderless (no title bar), movable by dragging any empty background, resizable from its edges.
final class AtriumWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .miniaturizable, .closable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isRestorable = false
        title = AppInfo.name                       // shown in the Window menu and Mission Control
        minSize = NSSize(width: 520, height: 360)
        collectionBehavior = [.managed, .participatesInCycle]
        setFrameAutosaveName("AtriumMainWindow")
    }
    override var canBecomeKey: Bool { true }       // borderless windows default to false
    override var canBecomeMain: Bool { true }

    /// Called right after a mouse-down was handled (a click, or the end of a window drag). A click on an already-key window
    /// still brings it to the front without any key/activation notification, so this is the reliable hook.
    var onMouseDown: (@MainActor () -> Void)?

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?() }
    }
}

/// Rounded, softly translucent backdrop for the whole window. Visible in the gaps and while no app is snapped in.
final class WindowBackdropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.windowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// First click works even though the panel is never key; hover comes from an always-active tracking area
/// because SwiftUI `.onHover` is unreliable while Atrium is inactive (which is almost always).
final class SidebarHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (@MainActor (CGPoint?) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    private func report(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onHover?(CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))
    }
}
