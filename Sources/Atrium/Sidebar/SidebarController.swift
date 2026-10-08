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
    private let store: AppStore
    private let hover = HoverState()
    private let labelPanel = HoverLabelPanel()
    private let glassView = NSGlassEffectView()
    private let rail = RailPanel()
    private var observers: [NSObjectProtocol] = []
    private var screenTask: Task<Void, Never>?
    private var watchTimer: Timer?
    private var watchingFast = false
    private var lastWatchedFrame: CGRect = .zero
    private var lastFrameChange = Date.distantPast
    private var slowTicks = 0

    /// Called after the window moved, resized or changed display (debounced by AppKit's live-resize end).
    var onFrameChange: (@MainActor () -> Void)?
    /// Atrium's window became key (a click on it); it may have been raised above the snapped app.
    var onBecameKey: (@MainActor () -> Void)?
    /// Something about Atrium's own windows changed (one closed, focus moved, Atrium (de)activated): re-check that the
    /// selected app is still in front of Atrium's window. Also called once a second as a safety net.
    var onCheckOrder: (@MainActor () -> Void)?
    /// A click on the main window itself (the backdrop around the app).
    var onMainMouseDown: (@MainActor () -> Void)?

    init(store: AppStore, prefs: Preferences, actions: SidebarActions) {
        self.prefs = prefs
        self.store = store
        let size = DesignTokens.defaultWindowSize
        let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window = AtriumWindow(contentRect: CGRect(origin: origin, size: size))   // autosaved frame (if any) overrides below
        layout = ScreenLayout.compute(visibleFrame: window.frame, edge: prefs.sidebarEdge)

        let host = SidebarHostingView(rootView: SidebarView(store: store, prefs: prefs, hover: hover, actions: actions))
        host.sizingOptions = []
        host.onHover = { [weak self] point in self?.pointerMoved(point) }
        host.isOverControl = { [hover] in hover.target != nil }

        let backdrop = WindowBackdropView(frame: CGRect(origin: .zero, size: size))
        window.contentView = backdrop
        glassView.cornerRadius = DesignTokens.sidebarCornerRadius
        glassView.contentView = host
        glassView.autoresizingMask = [.width, .height]
        rail.contentView = glassView
        rail.atriumWindow = window

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
        // Any of Atrium's windows closing or trading focus (Settings, Add Apps, Edit) can leave Atrium's main window in
        // front of the selected app. Re-check right after AppKit has finished reordering.
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleOrderCheck() }
            })
        }
        // The rail is its own window: hide and show it with the main window.
        observers.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rail.orderOut(nil) }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rail.orderOut(nil) }
        })
        observers.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepRailOnMain() }
        })
        window.onMouseDown = { [weak self] in                              // a click on the backdrop raised the main window
            self?.keepRailOnMain()
            self?.onMainMouseDown?()
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleOrderCheck() }
            })
        }
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
    /// AppKit runs the main thread in "event tracking" mode where plain timers and async tasks don't fire. A timer in the
    /// *common* run-loop modes keeps firing. It runs at 60 Hz only while a button is held or the window just moved, and
    /// at 10 Hz otherwise, so an idle Atrium barely wakes the CPU.
    private func startFrameWatcher() {
        lastWatchedFrame = window.frame
        scheduleWatch(fast: false)
    }

    private func scheduleWatch(fast: Bool) {
        watchTimer?.invalidate()
        let timer = Timer(timeInterval: fast ? 1.0 / 60 : 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = fast ? 0.004 : 0.03
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
        watchingFast = fast
    }

    private func tick() {
        if window.frame != lastWatchedFrame {
            lastFrameChange = Date()
            frameChanged()
        }
        let busy = NSEvent.pressedMouseButtons != 0 || window.inLiveResize || Date().timeIntervalSince(lastFrameChange) < 0.5
        if busy != watchingFast { scheduleWatch(fast: busy) }
        // Attach the rail only while the window is actually moving or resizing (so it follows exactly).
        let moving = window.inLiveResize || Date().timeIntervalSince(lastFrameChange) < 0.5
        if moving != (rail.parent != nil) {
            if moving { window.addChildWindow(rail, ordered: .above) } else { window.removeChildWindow(rail) }
        }
        if !watchingFast {
            slowTicks += 1
            if slowTicks % 10 == 0 {                              // once a second: the safety net
                keepRailOnMain()
                onCheckOrder?()
            }
        }
    }

    private var orderCheckPending = false
    private func scheduleOrderCheck() {
        guard !orderCheckPending else { return }
        orderCheckPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.orderCheckPending = false
                self?.onCheckOrder?()
            }
        }
    }

    /// Hit-test on every mouse move here, outside SwiftUI: the rail only redraws when the target actually changes.
    private func pointerMoved(_ point: CGPoint?) {
        let target = SidebarView.hitTest(point, glassHeight: glassView.frame.height, apps: store.apps)
        if target != hover.target { hover.target = target }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        relayout()
        keepRailOnMain()
    }

    /// Main window right below the app it shows, rail right above the main window (where it sits).
    func placeMain(below number: Int) {
        window.order(.below, relativeTo: number)
        keepRailOnMain()
    }

    private func keepRailOnMain() {
        guard window.isVisible, !window.isMiniaturized else { return }
        rail.order(.above, relativeTo: window.windowNumber)
    }

    var railFrame: CGRect { rail.frame }

    /// The rectangle (Cocoa screen coordinates) the active app's window should fill.
    var workspaceRect: CGRect { layout.workspace }

    func relayout() {
        layout = ScreenLayout.compute(visibleFrame: window.frame, edge: prefs.sidebarEdge)
        if rail.frame != layout.glass { rail.setFrame(layout.glass, display: true) }
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
