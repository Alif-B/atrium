import CoreGraphics

public enum SidebarEdge: String, Sendable, CaseIterable {
    case left, right
}

public struct LayoutResult: Equatable, Sendable {
    /// The transparent strip the sidebar panel occupies (glass + gaps).
    public var panel: CGRect
    /// The visible glass rail.
    public var glass: CGRect
    /// Where a snapped app window goes.
    public var workspace: CGRect
}

public enum ScreenLayout {
    /// All frames are in Cocoa coordinates (bottom-left origin). `visibleFrame` excludes menu bar and Dock.
    public static func compute(
        visibleFrame v: CGRect,
        edge: SidebarEdge,
        gap: CGFloat = LayoutConstants.gap,
        sidebarWidth: CGFloat = LayoutConstants.sidebarWidth
    ) -> LayoutResult {
        let panelWidth = 2 * gap + sidebarWidth
        switch edge {
        case .left:
            let panel = CGRect(x: v.minX, y: v.minY, width: panelWidth, height: v.height)
            let workspace = CGRect(
                x: panel.maxX, y: v.minY + gap,
                width: v.maxX - gap - panel.maxX, height: v.height - 2 * gap)
            return LayoutResult(panel: panel, glass: panel.insetBy(dx: gap, dy: gap), workspace: workspace)
        case .right:
            let panel = CGRect(x: v.maxX - panelWidth, y: v.minY, width: panelWidth, height: v.height)
            let workspace = CGRect(
                x: v.minX + gap, y: v.minY + gap,
                width: panel.minX - (v.minX + gap), height: v.height - 2 * gap)
            return LayoutResult(panel: panel, glass: panel.insetBy(dx: gap, dy: gap), workspace: workspace)
        }
    }

    /// Converts a Cocoa rect into AX/Quartz coordinates (top-left origin of the primary screen).
    /// `primaryScreenFrame` is `NSScreen.screens[0].frame`.
    public static func axRect(fromCocoa r: CGRect, primaryScreenFrame p: CGRect) -> CGRect {
        CGRect(x: r.minX, y: p.maxY - r.maxY, width: r.width, height: r.height)
    }
}
