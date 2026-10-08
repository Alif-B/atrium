import CoreGraphics

/// Geometry constants shared by the pure layout code and the UI design tokens.
public enum LayoutConstants {
    public static let gap: CGFloat = 8
    public static let sidebarPadding: CGFloat = 10
    public static let itemSize: CGFloat = 44
    public static let itemSpacing: CGFloat = 4
    public static var itemPitch: CGFloat { itemSize + itemSpacing }
    public static var sidebarWidth: CGFloat { itemSize + 2 * sidebarPadding }
}
