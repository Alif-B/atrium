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
    /// Atrium started / finished moving or resizing (a drag, an edge resize, a zoom).
    var onMoveBegan: (@MainActor () -> Void)?
    var onMoveEnded: (@MainActor () -> Void)?
    /// The pointer arrived on the rail (a good moment to refresh the app's snapshot, before any drag or click).
    var onPointerEnteredRail: (@MainActor () -> Void)?
    /// Atrium is about to minimize / close, or was just shown again: its apps go and come with it.
    var onWillMinimize: (@MainActor () -> Void)?
    var onDidDeminiaturize: (@MainActor () -> Void)?
    var onWillClose: (@MainActor () -> Void)?
    var onShown: (@MainActor () -> Void)?
    private(set) var isMoving = false
    /// Keeps the rail attached to the main window (Mission Control).
    var railAttached = false {
        didSet {
            guard railAttached != oldValue, window.isVisible, !window.isMiniaturized else { return }
            if railAttached, rail.parent == nil { window.addChildWindow(rail, ordered: .above) }
        }
    }
    private var backdrop: WindowBackdropView?

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
        host.onDoubleClick = { [weak self] in self?.titleBarDoubleClick() }
        host.onPress = { [weak self] in self?.watchFastNow() }

        let backdrop = WindowBackdropView(frame: CGRect(origin: .zero, size: size))
        window.contentView = CornerGripView.container(around: backdrop)
        self.backdrop = backdrop
        glassView.cornerRadius = DesignTokens.sidebarCornerRadius
        glassView.contentView = host
        glassView.autoresizingMask = [.width, .height]
        rail.contentView = glassView
        window.onDoubleClick = { [weak self] in self?.titleBarDoubleClick() }
        window.onZoom = { [weak self] in self?.toggleZoom() }
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
        observers.append(center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rail.orderOut(nil)
                self?.onWillMinimize?()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rail.orderOut(nil)
                self?.onWillClose?()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keepRailOnMain()
                self?.onDidDeminiaturize?()
            }
        })
        window.onMouseDown = { [weak self] in                              // a click on the backdrop raised the main window
            self?.watchFastNow()
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
        let ws = layout.workspace.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        backdrop.installEmptyState(NSHostingView(rootView: EmptyStateView(store: store, open: actions.switchTo)), frame: ws)
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
            if !isMoving {
                isMoving = true
                onMoveBegan?()
            }
            frameChanged()
        }
        // Done moving: nothing changed for a moment, no button held, not resizing.
        if isMoving, Date().timeIntervalSince(lastFrameChange) > 0.15, NSEvent.pressedMouseButtons == 0, !window.inLiveResize {
            isMoving = false
            onMoveEnded?()
        }
        let busy = NSEvent.pressedMouseButtons != 0 || window.inLiveResize || Date().timeIntervalSince(lastFrameChange) < 0.5
        if busy != watchingFast { scheduleWatch(fast: busy) }
        // Attach the rail only while the window is actually moving or resizing (so it follows exactly), or while
        // Mission Control is open (so it shows the rail and the window as one).
        let attach = railAttached || window.inLiveResize || Date().timeIntervalSince(lastFrameChange) < 0.5
        if attach != (rail.parent != nil) {
            if attach { window.addChildWindow(rail, ordered: .above) } else { window.removeChildWindow(rail) }
        }
        if !watchingFast {
            slowTicks += 1
            if slowTicks % 10 == 0 {                              // once a second: the safety net
                keepRailOnMain()
                onCheckOrder?()
            }
        }
    }

    /// A press on Atrium (it may become a drag or resize): watch the frame at full speed right away.
    private func watchFastNow() {
        if !watchingFast { scheduleWatch(fast: true) }
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
        if hover.target == nil, point != nil { onPointerEnteredRail?() }
        if target != hover.target { hover.target = target }
    }

    // MARK: Double-click to zoom

    private var frameBeforeZoom: CGRect?

    /// Like a title bar: does what System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to" says
    /// (fill the screen by default, or minimize, or nothing).
    private func titleBarDoubleClick() {
        let defaults = UserDefaults.standard
        let action = defaults.string(forKey: "AppleActionOnDoubleClick")
            ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
        switch action {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: toggleZoom()
        }
    }

    /// Fill the screen's usable area; the next double-click goes back to the previous size and place.
    func toggleZoom() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let filled = screen.visibleFrame
        let isFilled = abs(window.frame.minX - filled.minX) < 2 && abs(window.frame.minY - filled.minY) < 2
            && abs(window.frame.width - filled.width) < 2 && abs(window.frame.height - filled.height) < 2
        if isFilled, let previous = frameBeforeZoom {
            frameBeforeZoom = nil
            window.setFrame(previous, display: true, animate: true)
        } else {
            frameBeforeZoom = window.frame
            window.setFrame(filled, display: true, animate: true)
        }
        lastFrameChange = Date()
        frameChanged()
    }

    func show() {
        let wasHidden = !window.isVisible
        window.makeKeyAndOrderFront(nil)
        relayout()
        keepRailOnMain()
        if wasHidden { onShown?() }
    }

    /// While Atrium opens your apps at launch: keep Atrium in front, its workspace covered.
    func showLoading() {
        let ws = layout.workspace.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        backdrop?.showLoading(frame: ws)
        window.orderFrontRegardless()
        keepRailOnMain()
    }

    /// Web pages live in Atrium's workspace (see WebAppHost).
    func installWebContainer(_ view: NSView) {
        backdrop?.installWebContainer(view, frame: layout.workspace.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY))
    }

    /// A web app is on show: Atrium comes in front of everything, with keyboard focus.
    func bringForward() {
        if !window.isVisible { show(); return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        window.makeKey()
        keepRailOnMain()
    }

    /// Keeps Atrium (and its cover) above windows that open while loading.
    func stayInFront() {
        window.orderFrontRegardless()
        keepRailOnMain()
    }

    func hideLoading() { backdrop?.hideLoading() }

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

    /// Shows a still image of the app in Atrium's workspace (behind the app's real window until that is hidden).
    func showSnapshot(_ image: CGImage) {
        let ws = layout.workspace.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let scale = window.backingScaleFactor
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        backdrop?.showSnapshot(image, frame: CGRect(x: ws.minX, y: ws.maxY - size.height, width: size.width, height: size.height))
    }

    func hideSnapshot() { backdrop?.hideSnapshot() }

    /// The rectangle (Cocoa screen coordinates) the active app's window should fill.
    var workspaceRect: CGRect { layout.workspace }

    /// The user resized the app by its own edge (`app` in Cocoa coordinates): wrap Atrium around it, keeping the same
    /// margins and rail. Quietly: this is not an Atrium move, so its apps stay visible.
    func wrap(around app: CGRect) {
        let f = window.frame, ws = layout.workspace
        var new = CGRect(x: app.minX - (ws.minX - f.minX), y: app.minY - (ws.minY - f.minY),
                         width: app.width + (f.width - ws.width), height: app.height + (f.height - ws.height))
        // Below Atrium's minimum, hold the edge that isn't being dragged (the app is fitted back on release).
        if new.width < window.minSize.width {
            new.origin.x = abs(app.minX - ws.minX) > abs(app.maxX - ws.maxX) ? f.maxX - window.minSize.width : f.minX
            new.size.width = window.minSize.width
        }
        if new.height < window.minSize.height {
            new.origin.y = abs(app.minY - ws.minY) > abs(app.maxY - ws.maxY) ? f.maxY - window.minSize.height : f.minY
            new.size.height = window.minSize.height
        }
        new = new.integral
        guard new != f else { return }
        window.setFrame(new, display: true)
        lastWatchedFrame = window.frame
        relayout()
    }

    func relayout() {
        layout = ScreenLayout.compute(visibleFrame: window.frame, edge: prefs.sidebarEdge)
        backdrop?.layoutWorkspace(layout.workspace.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY))
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
