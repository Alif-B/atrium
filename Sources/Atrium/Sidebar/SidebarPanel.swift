import AppKit
import SwiftUI

final class SidebarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        isFloatingPanel = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
