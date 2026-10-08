import SwiftUI
import AtriumCore

struct SidebarActions {
    var switchTo: @MainActor (ManagedApp) -> Void
    var showAddApps: @MainActor () -> Void
    var showSettings: @MainActor () -> Void
    var locate: @MainActor (ManagedApp) -> Void
    var showInFinder: @MainActor (ManagedApp) -> Void
    var remove: @MainActor (ManagedApp) -> Void
    var hide: @MainActor (ManagedApp) -> Void
    var quit: @MainActor (ManagedApp) -> Void
    var reload: @MainActor (ManagedApp) -> Void
    var edit: @MainActor (ManagedApp) -> Void
}

private struct UtilityButton: View {
    let symbol: String
    let label: String
    let isHovered: Bool
    let itemSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DesignTokens.utilitySymbolSize, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: itemSize, height: itemSize)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.lensCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .opacity(isHovered ? 1 : 0)
                        .animation(isHovered ? Motion.hoverIn : Motion.hoverOut, value: isHovered)
                }
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.lensCornerRadius, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(Text(label))
    }
}

struct SidebarView: View {
    let store: AppStore
    let prefs: Preferences
    let hover: HoverState
    let actions: SidebarActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var lensIndex: Int?
    @State private var lensVisible = false
    // Drag-to-reorder: the held icon follows the pointer; the others slide aside as the order changes live.
    @State private var draggingID: String?
    @State private var dragStartIndex = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var suppressClick = false

    /// The panel's content view is exactly the glass rail (NSGlassEffectView supplies the glass), so there is no outer inset.
    private let outerInset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let glassHeight = geo.size.height - 2 * outerInset
            let metrics = SidebarMetrics.fit(count: store.apps.count, glassHeight: glassHeight)
            rail(metrics: metrics)
        }
        .onAppear {
            lensIndex = store.activeIndex
            lensVisible = lensIndex != nil
        }
        .onChange(of: store.activeIndex) { old, new in moveLens(from: old, to: new) }
    }

    // MARK: Rail

    private func rail(metrics: SidebarMetrics) -> some View {
        let content = VStack(spacing: 0) {
            Spacer(minLength: 0)                       // equal spacers: the app list sits vertically centred
            itemsStack(metrics: metrics)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1 / (NSScreen.screens.first?.backingScaleFactor ?? 2))
                .padding(.horizontal, DesignTokens.hairlineInset - DesignTokens.sidebarPadding)
                .padding(.vertical, DesignTokens.hairlineSpacing)
            gearButton
        }
        .padding(DesignTokens.sidebarPadding)
        .frame(width: DesignTokens.sidebarWidth)
        .contextMenu {
            Button("Add App…") { actions.showAddApps() }
            Button("Settings…") { actions.showSettings() }
        }

        return content
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: DesignTokens.sidebarCornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
    }

    private func itemsStack(metrics: SidebarMetrics) -> some View {
        VStack(spacing: metrics.spacing) {
            ForEach(Array(store.apps.enumerated()), id: \.element.id) { index, app in
                SidebarItemView(
                    app: app,
                    icon: store.icon(for: app),
                    metrics: metrics,
                    isActive: store.activeBundleID == app.bundleIdentifier,
                    isRunning: store.runningBundleIDs.contains(app.bundleIdentifier),
                    isLaunching: store.launchingBundleIDs.contains(app.bundleIdentifier),
                    isMissing: store.isMissing(app),
                    isHovered: hover.target?.slot == .item(index),
                    magnification: draggingID == app.bundleIdentifier ? DesignTokens.dragLiftScale : magnification(for: index),
                    badge: prefs.showBadges ? store.badges[app.bundleIdentifier] : nil,
                    edge: prefs.sidebarEdge,
                    action: { if !suppressClick { actions.switchTo(app) } },
                    menu: ItemMenuActions(
                        open: { actions.switchTo(app) },
                        locate: { actions.locate(app) },
                        showInFinder: { actions.showInFinder(app) },
                        reload: { actions.reload(app) },
                        edit: { actions.edit(app) },
                        remove: { actions.remove(app) },
                        hide: { actions.hide(app) },
                        quit: { actions.quit(app) },
                        toggleSnap: { store.update(bundleID: app.bundleIdentifier) { $0.snapWindow.toggle() } },
                        toggleOpenAtLogin: { store.update(bundleID: app.bundleIdentifier) { $0.openAtLogin.toggle() } },
                        toggleHibernate: { store.update(bundleID: app.bundleIdentifier) { $0.hibernates.toggle() } }))
                .offset(y: draggingID == app.bundleIdentifier ? dragOffset(for: index, metrics: metrics) : 0)
                .shadow(color: .black.opacity(draggingID == app.bundleIdentifier ? 0.28 : 0), radius: 9, y: 4)
                .zIndex(draggingID == app.bundleIdentifier ? 1 : 0)
                .simultaneousGesture(reorderGesture(for: app, metrics: metrics))
            }
            UtilityButton(symbol: "plus", label: "Add App", isHovered: hover.target?.slot == .plus,
                          itemSize: metrics.itemSize, action: actions.showAddApps)
        }
        .background(alignment: .top) { lensFill(metrics: metrics) }
        .animation(reduceMotion ? nil : Motion.reorder, value: store.apps.map(\.id))
    }

    // MARK: Reordering

    /// Keeps the held icon under the pointer while its slot changes.
    private func dragOffset(for index: Int, metrics: SidebarMetrics) -> CGFloat {
        dragTranslation - CGFloat(index - dragStartIndex) * metrics.pitch
    }

    private func reorderGesture(for app: ManagedApp, metrics: SidebarMetrics) -> some Gesture {
        DragGesture(minimumDistance: DesignTokens.dragStartDistance, coordinateSpace: .global)
            .onChanged { value in
                if draggingID == nil {
                    guard let start = store.apps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
                    draggingID = app.bundleIdentifier
                    dragStartIndex = start
                    suppressClick = true
                    hover.target = nil
                }
                guard draggingID == app.bundleIdentifier,
                      let current = store.apps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
                dragTranslation = value.translation.height
                let wanted = Int((CGFloat(dragStartIndex) + value.translation.height / metrics.pitch).rounded())
                let target = min(max(wanted, 0), store.apps.count - 1)
                if target != current {
                    store.move(fromOffsets: IndexSet(integer: current), toOffset: target > current ? target + 1 : target)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : Motion.reorder) {
                    draggingID = nil
                    dragTranslation = 0
                }
                // The press that ended the drag must not count as a click on the icon.
                Task { try? await Task.sleep(for: .milliseconds(200)); suppressClick = false }
            }
    }

    /// Dock-style: the hovered icon grows most, its direct neighbours a little.
    private func magnification(for index: Int) -> CGFloat {
        guard !reduceMotion, case .item(let hovered)? = hover.target?.slot else { return 1 }
        switch abs(index - hovered) {
        case 0: return DesignTokens.magnifyHovered
        case 1: return DesignTokens.magnifyNeighbour
        default: return 1
        }
    }

    private var gearButton: some View {
        UtilityButton(symbol: "gearshape", label: "Settings", isHovered: hover.target?.slot == .gear,
                      itemSize: DesignTokens.itemSize, action: actions.showSettings)
            .overlay(alignment: .topTrailing) {
                if !store.isAXTrusted {
                    Circle()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: DesignTokens.amberDotSize, height: DesignTokens.amberDotSize)
                        .offset(x: -6, y: 6)
                        .accessibilityHidden(true)
                }
            }
    }

    // MARK: Lens (§7.5)

    @ViewBuilder
    private func lensFill(metrics: SidebarMetrics) -> some View {
        if let i = lensIndex {
            LensFill(cornerRadius: DesignTokens.lensCornerRadius * metrics.scale)
                .frame(width: metrics.itemSize, height: metrics.itemSize)
                .opacity(lensVisible ? 1 : 0)
                .offset(y: CGFloat(i) * metrics.pitch)
        }
    }

    private func moveLens(from old: Int?, to new: Int?) {
        guard let new else {
            withAnimation(Motion.fade) { lensVisible = false }
            return
        }
        if old == nil || lensIndex == nil || !lensVisible {
            // First appearance: fade in at the destination, no travel.
            withTransaction(Transaction(animation: nil)) { lensIndex = new }
            withAnimation(Motion.fade) { lensVisible = true }
        } else if reduceMotion {
            withAnimation(.easeOut(duration: 0.075)) { lensVisible = false } completion: {
                withTransaction(Transaction(animation: nil)) { lensIndex = new }
                withAnimation(.easeIn(duration: 0.075)) { lensVisible = true }
            }
        } else {
            withAnimation(Motion.lensSlide) { lensIndex = new }
        }
    }

    // MARK: Hover (§6 B1)

    /// What the pointer is over. Called by the controller on every mouse move, *outside* SwiftUI, so moving the pointer
    /// doesn't redraw the rail; only a change of target does. `point` is top-left based, inside the glass.
    static func hitTest(_ point: CGPoint?, glassHeight: CGFloat, apps: [ManagedApp]) -> HoverTarget? {
        guard let point else { return nil }
        let x = point.x, y = point.y
        guard x >= 0, x <= DesignTokens.sidebarWidth, y >= 0, y <= glassHeight else { return nil }
        let metrics = SidebarMetrics.fit(count: apps.count, glassHeight: glassHeight)

        let panelTop = DesignTokens.gap          // glass top inside the window
        let gearTop = glassHeight - DesignTokens.sidebarPadding - DesignTokens.itemSize
        if y >= gearTop {
            return HoverTarget(slot: .gear, title: "Settings", centerYInPanel: panelTop + gearTop + DesignTokens.itemSize / 2)
        }
        let itemsTop = metrics.itemsTop(count: apps.count, glassHeight: glassHeight)
        let local = y - itemsTop
        guard local >= 0 else { return nil }
        let index = Int(local / metrics.pitch)
        let centerY = panelTop + itemsTop + CGFloat(index) * metrics.pitch + metrics.itemSize / 2
        if index < apps.count { return HoverTarget(slot: .item(index), title: apps[index].displayName, centerYInPanel: centerY) }
        if index == apps.count { return HoverTarget(slot: .plus, title: "Add App", centerYInPanel: centerY) }
        return nil
    }
}
