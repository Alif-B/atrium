import AppKit
import SwiftUI
import OSLog
import AtriumCore

private let log = Logger(subsystem: "com.alif.atrium", category: "switcher")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prefs: Preferences!
    private var store: AppStore!
    private var sidebar: SidebarController!
    private var addAppsWindow: HostingWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(settingsTarget: self, settingsAction: #selector(openSettings))
        prefs = Preferences()
        store = LaunchOptions.demo ? AppStore.demo() : AppStore.persistent()
        let actions = SidebarActions(
            switchTo: { [weak self] app in self?.handleClick(app) },
            showAddApps: { [weak self] in self?.showAddApps() },
            showSettings: { [weak self] in self?.showSettings() },
            locate: { [weak self] app in self?.locate(app) })
        sidebar = SidebarController(store: store, prefs: prefs, actions: actions)
        sidebar.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Actions

    private func handleClick(_ app: ManagedApp) {
        if store.isMissing(app) { locate(app); return }
        // M2: demo behaviour only (lens moves). Real activation arrives in M3.
        log.debug("switchTo \(app.bundleIdentifier, privacy: .public)")
        store.activeBundleID = app.bundleIdentifier
    }

    @objc private func openSettings() { showSettings() }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store, showAddApps: { [weak self] in self?.showAddApps() })
        }
        settingsWindow?.present()
    }

    private func showAddApps() {
        if addAppsWindow == nil {
            addAppsWindow = HostingWindowController(
                title: "Add Apps", size: NSSize(width: 600, height: 560), transparentTitlebar: true,
                rootView: AddAppsView(store: store, onDone: { [weak self] in self?.addAppsWindow?.dismiss() }))
        }
        addAppsWindow?.present()
    }

    /// Lets the user point at a moved app; updates `lastKnownPath`.
    private func locate(_ app: ManagedApp) {
        let panel = NSOpenPanel()
        panel.message = "Locate \(app.displayName)"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.update(bundleID: app.bundleIdentifier) { $0.lastKnownPath = url.path }
    }
}
