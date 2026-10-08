import AppKit
import SwiftUI
import AtriumCore

/// Owns the Atrium window: the glass rail on one side, and the "workspace" rectangle where the selected app's
/// real window is placed (M4). Everything is derived from the window's current frame, so moving, resizing or
/// dragging it to another display just works.
@MainActor
final class SidebarController {
    let window: AtriumWindow
    private(set) var layout: LayoutResult
    private let prefs: Preferences
    private let hover = HoverState()
    private let labelPanel = HoverLabelPanel()
    private let glassView = NSGlassEffectView()
    private var observers: [NSObjectProtocol] = []
    private var screenTask: Task<Void, Never>?
    private var watchTimer: Timer?
    private var lastWatchedFrame: CGRect = .zero

    /// Called after the window moved, resized or changed display (debounced by AppKit's live-resize end).
    var onFrameChange: (@MainActor () -> Void)?
    /// Atrium's window became key (a click on it); it may have been raised above the snapped app.
    var onBecameKey: (@MainActor () -> Void)?

    init(store: AppStore, prefs: Preferences, actions: SidebarActions) {
        self.prefs = prefs
        let size = DesignTokens.defaultWindowSize
        let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window = AtriumWindow(contentRect: CGRect(origin: origin, size: size))   // autosaved frame (if any) overrides below
        layout = ScreenLayout.compute(visibleFrame: window.frame, edge: prefs.sidebarEdge)

        let host = SidebarHostingView(rootView: SidebarView(store: store, prefs: prefs, hover: hover, actions: actions))
        host.sizingOptions = []
        host.onHover = { [hover] point in hover.point = point }

        let backdrop = WindowBackdropView(frame: CGRect(origin: .zero, size: size))
        glassView.cornerRadius = DesignTokens.sidebarCornerRadius
        glassView.contentView = host
        backdrop.addSubview(glassView)
        window.contentView = backdrop

        hover.onTargetChange = { [weak self] target in self?.updateLabel(target) }
        prefs.onLayoutChange = { [weak self] in self?.relayout() }

        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.frameChanged() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onBecameKey?() }
        })
        observers.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFrameChange?() }
        })
        screenTask = Task { [weak self] in
            for await _ in center.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                try? await Task.sleep(for: .milliseconds(300))      // display changes arrive in bursts
                guard !NSScreen.screens.isEmpty else { continue }
                self?.frameChanged()
                self?.onFrameChange?()
            }
        }
        relayout()
        startFrameWatcher()
    }

    /// A borderless window dragged by its background doesn't reliably post move notifications, and while the user drags,
    /// AppKit runs the main thread in "event tracking" mode where plain timers and async tasks don't fire. A timer
    /// registered for the *common* run-loop modes keeps firing, so the snapped app can follow live. The check is just a
    /// frame comparison (60 Hz), so it costs next to nothing.
    private func startFrameWatcher() {
        lastWatchedFrame = window.frame
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrame() }
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func checkFrame() {
        if window.frame != lastWatchedFrame { frameChanged() }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        relayout()
    }

    /// The rectangle (Cocoa screen coordinates) the active app's window should fill.
    var workspaceRect: CGRect { layout.workspace }

    func relayout() {
        layout = ScreenLayout.compute(visibleFrame: window.frame, edge: prefs.sidebarEdge)
        glassView.frame = layout.glass.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        window.invalidateShadow()
    }

    private func frameChanged() {
        lastWatchedFrame = window.frame
        relayout()
        onFrameChange?()
    }

    private func updateLabel(_ target: HoverTarget?) {
        guard let target else { labelPanel.hide(); return }
        labelPanel.show(text: target.title, edge: prefs.sidebarEdge, glass: layout.glass,
                        centerY: layout.panel.maxY - target.centerYInPanel)
    }
}
