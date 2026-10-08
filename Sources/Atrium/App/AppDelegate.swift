import AppKit
import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "switcher")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prefs: Preferences!
    private var store: AppStore!
    private var sidebar: SidebarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        prefs = Preferences()
        store = LaunchOptions.demo ? AppStore.demo() : AppStore()
        let actions = SidebarActions(
            switchTo: { [store] app in
                // M1: demo behaviour only. Real activation arrives in M3.
                log.debug("switchTo \(app.bundleIdentifier, privacy: .public)")
                store?.activeBundleID = app.bundleIdentifier
            },
            showAddApps: { log.debug("showAddApps (M2)") },
            showSettings: { log.debug("showSettings (M2)") })
        sidebar = SidebarController(store: store, prefs: prefs, actions: actions)
        sidebar.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
