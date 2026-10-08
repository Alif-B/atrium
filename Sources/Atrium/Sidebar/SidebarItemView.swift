import SwiftUI
import AtriumCore

struct SidebarMetrics {
    var scale: CGFloat
    var itemSize: CGFloat { DesignTokens.itemSize * scale }
    var iconSize: CGFloat { DesignTokens.iconSize * scale }
    var spacing: CGFloat { DesignTokens.itemSpacing * scale }
    var pitch: CGFloat { itemSize + spacing }

    /// Items shrink (down to 0.75) when they don't fit, like the Dock. Fixed chrome: + cell, hairline block, gear cell.
    static func fit(count: Int, glassHeight: CGFloat) -> SidebarMetrics {
        guard count > 0 else { return SidebarMetrics(scale: 1) }
        let fixed = 2 * DesignTokens.sidebarPadding
            + DesignTokens.itemPitch                                   // + cell
            + 2 * DesignTokens.hairlineSpacing + 1                     // hairline block
            + DesignTokens.itemSize                                    // gear cell
        let available = glassHeight - fixed
        let s = available / (CGFloat(count) * DesignTokens.itemPitch)
        return SidebarMetrics(scale: min(1, max(DesignTokens.minItemScale, s)))
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.2 : 0)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Resting lens: a softly raised plate drawn ON the rail's glass (no glass of its own).
struct LensFill: View {
    var cornerRadius: CGFloat = DesignTokens.lensCornerRadius
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .quaternarySystemFill))
        } else {
            shape
                .fill(Color.primary.opacity(contrast == .increased ? 0.20 : (scheme == .dark ? 0.14 : 0.10)))
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
                }
        }
    }
}

private struct PulsingDot: View {
    let pulsing: Bool
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(Color.primary.opacity(0.6))
            .frame(width: DesignTokens.runningDotSize, height: DesignTokens.runningDotSize)
            .opacity(pulsing && dim ? 0.35 : 1)
            .onAppear { restart() }
            .onChange(of: pulsing) { restart() }
    }
    private func restart() {
        dim = false
        guard pulsing else { return }
        withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) { dim = true }
    }
}

struct ItemMenuActions {
    var open: () -> Void
    var locate: () -> Void
    var showInFinder: () -> Void
    var remove: () -> Void
    var hide: () -> Void
    var quit: () -> Void
    var toggleSnap: () -> Void
    var toggleOpenAtLogin: () -> Void
}

struct SidebarItemView: View {
    let app: ManagedApp
    let icon: NSImage
    let metrics: SidebarMetrics
    let isActive: Bool
    let isRunning: Bool
    let isLaunching: Bool
    let isMissing: Bool
    let isHovered: Bool
    let badge: BadgeText?
    let edge: SidebarEdge
    let action: () -> Void
    let menu: ItemMenuActions

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.lensCornerRadius * metrics.scale, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .opacity(isHovered && !isActive ? 1 : 0)
                    .animation(isHovered ? Motion.hoverIn : Motion.hoverOut, value: isHovered)
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                    .opacity(isMissing ? 0.4 : 1)
                if isMissing {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: metrics.itemSize, height: metrics.itemSize)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.lensCornerRadius, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .overlay(alignment: edge == .left ? .leading : .trailing) {
            if isRunning || isLaunching {
                PulsingDot(pulsing: isLaunching && !isRunning)
                    .offset(x: edge == .left ? -8 : 8)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: isRunning)
        .overlay(alignment: .topTrailing) {
            if let badge {
                BadgeView(badge: badge)
                    .offset(x: badge == .dot ? -4 : 0, y: badge == .dot ? 4 : 0)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(Motion.badgeIn, value: badge != nil)
        .contextMenu {
            if isMissing {
                Button("Locate…", action: menu.locate)
                Button("Remove from Sidebar", role: .destructive, action: menu.remove)
            } else {
                if !isRunning { Button("Open", action: menu.open); Divider() }
                Toggle("Snap Window When Opened", isOn: Binding(get: { app.snapWindow }, set: { _ in menu.toggleSnap() }))
                Toggle("Open at Login", isOn: Binding(get: { app.openAtLogin }, set: { _ in menu.toggleOpenAtLogin() }))
                Button("Show in Finder", action: menu.showInFinder)
                Button("Remove from Sidebar", role: .destructive, action: menu.remove)
                if isRunning {
                    Divider()
                    Button("Hide", action: menu.hide)
                    Button("Quit", action: menu.quit)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(app.displayName))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isActive { parts.append("active") }
        if isRunning { parts.append("running") }
        if let badge {
            switch badge {
            case .count(let n): parts.append("\(n) unread")
            case .text(let s): parts.append(s)
            case .dot: parts.append("has notifications")
            }
        }
        return parts.joined(separator: ", ")
    }
}
