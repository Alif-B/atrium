import CoreGraphics
import AtriumCore

/// Every design number lives here (or in AtriumCore/LayoutConstants). See docs/PLAN.md §7.2.
enum DesignTokens {
    static let gap = LayoutConstants.gap
    static let sidebarWidth = LayoutConstants.sidebarWidth
    static let sidebarPadding = LayoutConstants.sidebarPadding
    static let itemSize = LayoutConstants.itemSize
    static let itemSpacing = LayoutConstants.itemSpacing
    static let itemPitch = LayoutConstants.itemPitch

    static let sidebarCornerRadius: CGFloat = 24
    static let iconSize: CGFloat = 40
    static let lensCornerRadius: CGFloat = 14
    static let runningDotSize: CGFloat = 4
    static let badgeHeight: CGFloat = 16
    static let dotBadgeSize: CGFloat = 8
    static let utilitySymbolSize: CGFloat = 13
    static let hoverLabelGap: CGFloat = 10
    static let hoverLabelMargin: CGFloat = 12      // transparent margin so label glass isn't clipped
    static let hairlineInset: CGFloat = 14
    static let hairlineSpacing: CGFloat = 8
    static let minItemScale: CGFloat = 0.75
    static let amberDotSize: CGFloat = 6
}
