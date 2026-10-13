import AppKit
import OSLog
import SwiftUI

/// The main Atrium window: borderless (no title bar), movable by dragging any empty background, resizable from its edges.
/// A *non-activating* panel: clicking it (an icon, the rail, a drag) neither activates Atrium nor brings its window in
/// front of the app it shows. A normal window would jump in front for a few frames on every click (the "blip" between
/// apps), then have to tuck itself back under the app.
final class AtriumWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .miniaturizable, .closable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = false                    // a normal-level window: other apps' windows still cover it
        level = .normal
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
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
        animationBehavior = .documentWindow            // the system's own open/close animation
    }
    override var canBecomeKey: Bool { true }       // borderless windows default to false
    override var canBecomeMain: Bool { true }

    /// Called right after a mouse-down was handled (a click, or the end of a window drag). A click on an already-key window
    /// still brings it to the front without any key/activation notification, so this is the reliable hook.
    var onMouseDown: (@MainActor () -> Void)?
    /// A double-click on the window's own background (the margin around the app).
    var onDoubleClick: (@MainActor () -> Void)?
    /// Window ▸ Zoom (the same as a double-click on empty space).
    var onZoom: (@MainActor () -> Void)?
    static let log = Logger(subsystem: "com.alif.atrium", category: "window")

    // A borderless window has no title-bar buttons, so AppKit's standard Close (⌘W), Minimize (⌘M) and Zoom would
    // only beep. Do what the buttons would do.
    override func performClose(_ sender: Any?) { close() }
    override func performMiniaturize(_ sender: Any?) { miniaturize(sender) }
    override func performZoom(_ sender: Any?) { onZoom?() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2 { onDoubleClick?(); return }
        super.sendEvent(event)
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?() }
    }
}

/// The rail's own window. The window server brings any clicked window to the front before the app even sees the click,
/// so if the rail were part of the main window, every click on an icon would put Atrium's whole window (and its empty
/// workspace) in front of the app for a few frames. As a separate strip that overlaps nothing, being raised changes
/// nothing on screen. It is attached to the main window (as a child) only while that window moves or resizes, so it tracks
/// it exactly; at rest it is separate, because clicking an attached window raises the whole family.
final class RailPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = false
        level = .normal
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false                          // drags on empty rail space move the main window instead
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.managed, .ignoresCycle]
    }
    /// The Atrium window this rail belongs to (drags on empty rail space move it).
    weak var atriumWindow: NSWindow?

    override var canBecomeKey: Bool { false }      // a click never takes keyboard focus from the app
    override var canBecomeMain: Bool { false }
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
        snapshotView.wantsLayer = true
        snapshotView.layer?.contentsGravity = .topLeft
        snapshotView.isHidden = true
        snapshotView.autoresizingMask = [.maxXMargin, .minYMargin]      // stays put at the top-left while resizing
        addSubview(snapshotView)
    }

    private let snapshotView = NSView()
    private var loadingView: NSView?

    /// Covers the workspace (opaque, so nothing being placed behind it shows through) until `hideLoading`.
    func showLoading(frame: CGRect) {
        guard loadingView == nil else { return }
        let view = NSHostingView(rootView: LoadingView())
        view.frame = frame
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        loadingView = view
    }

    func hideLoading() {
        guard let view = loadingView else { return }
        loadingView = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { view.removeFromSuperview() }
        }
    }

    /// Shows a still image of the app at `frame` (this view's coordinates), e.g. while the window moves.
    func showSnapshot(_ image: CGImage, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotView.frame = frame
        snapshotView.layer?.contentsScale = window?.backingScaleFactor ?? 2
        snapshotView.layer?.contents = image
        snapshotView.isHidden = false
        CATransaction.commit()
    }

    func hideSnapshot() {
        snapshotView.isHidden = true
        snapshotView.layer?.contents = nil
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// First click works even though the panel is never key; hover comes from an always-active tracking area
/// because SwiftUI `.onHover` is unreliable while Atrium is inactive (which is almost always).
final class SidebarHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (@MainActor (CGPoint?) -> Void)?
    /// True while the pointer is over an icon or button: a press there is a click or an icon drag, never a window drag.
    var isOverControl: (@MainActor () -> Bool)?
    /// A double-click on empty rail space.
    var onDoubleClick: (@MainActor () -> Void)?
    /// Any press on the rail.
    var onPress: (@MainActor () -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    /// A press on empty rail space drags the whole Atrium window (the rail's parent); on an icon it's a click or a reorder.
    override func mouseDown(with event: NSEvent) {
        onPress?()
        if !(isOverControl?() ?? false), let main = (window as? RailPanel)?.atriumWindow {
            if event.clickCount == 2 { onDoubleClick?(); return }
            main.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

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
