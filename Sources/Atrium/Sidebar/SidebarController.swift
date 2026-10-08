import AppKit
import SwiftUI
import AtriumCore

@MainActor
final class SidebarController {
    let panel: SidebarPanel
    private(set) var layout: LayoutResult
    private let prefs: Preferences
    private let hover = HoverState()
    private let labelPanel = HoverLabelPanel()
    private var glassView: NSGlassEffectView?
    private var relayoutTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?

    init(store: AppStore, prefs: Preferences, actions: SidebarActions) {
        self.prefs = prefs
        let initial = Self.computeLayout(edge: prefs.sidebarEdge)
        layout = initial
        panel = SidebarPanel(contentRect: initial.panel)

        let mode: RailGlass = LaunchOptions.appKitGlass ? .appKit : .swiftUI
        var root = AnyView(SidebarView(store: store, prefs: prefs, hover: hover, railGlass: mode, actions: actions))
        if LaunchOptions.glassActive { root = AnyView(root.environment(\.appearsActive, true)) }
        let host = SidebarHostingView(rootView: root)
        host.sizingOptions = []
        host.onHover = { [hover] point in hover.point = point }

        switch mode {
        case .swiftUI:
            panel.contentView = host
        case .appKit:
            let container = NSView()
            let glass = NSGlassEffectView()
            glass.cornerRadius = DesignTokens.sidebarCornerRadius
            glass.contentView = host
            container.addSubview(glass)
            panel.contentView = container
            glassView = glass
        }

        hover.onTargetChange = { [weak self] target in self?.updateLabel(target) }
        prefs.onLayoutChange = { [weak self] in self?.relayout() }

        screenTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                self?.scheduleRelayout()
            }
        }
        relayout()
    }

    func show() {
        relayout()
        panel.orderFrontRegardless()
    }

    private static func computeLayout(edge: SidebarEdge) -> LayoutResult {
        // Always the primary display (the one with the menu bar).
        let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        return ScreenLayout.compute(visibleFrame: visible, edge: edge)
    }

    func relayout() {
        layout = Self.computeLayout(edge: prefs.sidebarEdge)
        panel.setFrame(layout.panel, display: true)
        glassView?.frame = layout.glass.offsetBy(dx: -layout.panel.minX, dy: -layout.panel.minY)
    }

    /// Display changes arrive in bursts; wait 300 ms and ignore the "no screens" moment while reconfiguring.
    private func scheduleRelayout() {
        relayoutTask?.cancel()
        relayoutTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !NSScreen.screens.isEmpty else { return }
            relayout()
        }
    }

    private func updateLabel(_ target: HoverTarget?) {
        guard let target else { labelPanel.hide(); return }
        labelPanel.show(text: target.title, edge: prefs.sidebarEdge, glass: layout.glass,
                        centerY: layout.panel.maxY - target.centerYInPanel)
    }
}
