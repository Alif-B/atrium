import AppKit
import SwiftUI
import AtriumCore

@MainActor @Observable
final class HoverLabelModel {
    var text = ""
    var visible = false
    var edge: SidebarEdge = .left
}

private struct HoverLabelView: View {
    let model: HoverLabelModel
    var body: some View {
        Text(model.text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .fixedSize()
            .glassEffect(.regular, in: .capsule)
            .opacity(model.visible ? 1 : 0)
            .offset(x: model.visible ? 0 : (model.edge == .left ? -4 : 4))
            .padding(DesignTokens.hoverLabelMargin)
    }
}

/// A standalone panel (not a child window: the active app's window would cover a child).
final class HoverLabelPanel: NSPanel {
    private let model = HoverLabelModel()
    private let host: NSHostingView<HoverLabelView>
    private var hideTask: Task<Void, Never>?

    init() {
        host = NSHostingView(rootView: HoverLabelView(model: model))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = host
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `glass` and `centerY` are in screen coordinates.
    func show(text: String, edge: SidebarEdge, glass: CGRect, centerY: CGFloat) {
        hideTask?.cancel()
        model.edge = edge
        model.text = text
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let m = DesignTokens.hoverLabelMargin
        let x = edge == .left
            ? glass.maxX + DesignTokens.hoverLabelGap - m
            : glass.minX - DesignTokens.hoverLabelGap + m - size.width
        setFrame(NSRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height), display: true)
        if !isVisible { orderFrontRegardless() }
        withAnimation(Motion.label) { model.visible = true }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(150))      // avoids flicker between items
            guard !Task.isCancelled else { return }
            withAnimation(Motion.label) { model.visible = false }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            orderOut(nil)
        }
    }
}
