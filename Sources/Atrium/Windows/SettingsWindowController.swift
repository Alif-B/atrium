import AppKit
import SwiftUI

/// Remembers the selected pane. Subclassing is required: an NSTabViewController must stay its tab view's delegate
/// (replacing that delegate throws, which is why the gear button used to do nothing).
private final class SettingsTabController: NSTabViewController {
    static let lastTabKey = "settingsSelectedTab"
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.lastTabKey)
    }
}

/// Native preference-style window: toolbar tabs, title follows the selected pane, last pane remembered.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabController: SettingsTabController

    init(store: AppStore, prefs: Preferences, showAddApps: @escaping @MainActor () -> Void) {
        let tabController = SettingsTabController()
        tabController.tabStyle = .toolbar
        tabController.canPropagateSelectedChildViewControllerTitle = true
        self.tabController = tabController

        func pane<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view)
            host.title = title
            host.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabController.addTabViewItem(item)
        }
        pane("General", "gearshape", GeneralSettingsView(store: store, prefs: prefs))
        pane("Apps", "square.grid.2x2", AppsSettingsView(store: store, showAddApps: showAddApps))

        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable]            // no minimize or zoom, per the HIG for Settings windows
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)

        let saved = UserDefaults.standard.integer(forKey: SettingsTabController.lastTabKey)
        if saved < tabController.tabViewItems.count { tabController.selectedTabViewItemIndex = saved }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
