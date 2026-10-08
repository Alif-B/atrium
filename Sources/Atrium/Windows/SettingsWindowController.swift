import AppKit
import SwiftUI

/// Native preference-style window: toolbar tabs, title follows the selected pane, last pane remembered.
@MainActor
final class SettingsWindowController: NSWindowController, NSTabViewDelegate {
    private let tabController = NSTabViewController()
    private static let lastTabKey = "settingsSelectedTab"

    init(store: AppStore, showAddApps: @escaping @MainActor () -> Void) {
        tabController.tabStyle = .toolbar
        tabController.canPropagateSelectedChildViewControllerTitle = true

        let apps = NSHostingController(rootView: AppsSettingsView(store: store, showAddApps: showAddApps))
        apps.title = "Apps"
        apps.sizingOptions = .preferredContentSize
        let appsItem = NSTabViewItem(viewController: apps)
        appsItem.label = "Apps"
        appsItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Apps")
        tabController.addTabViewItem(appsItem)

        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable]            // no minimize or zoom, per the HIG for Settings windows
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        super.init(window: window)

        let saved = UserDefaults.standard.integer(forKey: Self.lastTabKey)
        if saved < tabController.tabViewItems.count { tabController.selectedTabViewItemIndex = saved }
        tabController.tabView.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        UserDefaults.standard.set(tabController.selectedTabViewItemIndex, forKey: Self.lastTabKey)
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
