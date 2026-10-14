import AppKit

/// What the View menu does to the web app on show.
@MainActor @objc protocol WebCommands: NSMenuItemValidation {
    func reloadWebPage(_ sender: Any?)
    func webGoBack(_ sender: Any?)
    func webGoForward(_ sender: Any?)
    func webActualSize(_ sender: Any?)
    func webZoomIn(_ sender: Any?)
    func webZoomOut(_ sender: Any?)
    func openWebPageInBrowser(_ sender: Any?)
}

@MainActor
enum MainMenu {
    static func build(settingsTarget: AnyObject, settingsAction: Selector, web: WebCommands) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenuItem(appMenu(settingsTarget: settingsTarget, settingsAction: settingsAction)))
        main.addItem(submenuItem(editMenu()))
        main.addItem(submenuItem(viewMenu(web)))
        main.addItem(submenuItem(windowMenu()))
        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func appMenu(settingsTarget: AnyObject, settingsAction: Selector) -> NSMenu {
        let name = AppInfo.name
        let menu = NSMenu(title: name)
        menu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: settingsAction, keyEquivalent: ",")
        settings.target = settingsTarget
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Required, or ⌘V/⌘C won't work in text fields.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    /// For the web app on show (disabled otherwise).
    private static func viewMenu(_ target: WebCommands) -> NSMenu {
        let menu = NSMenu(title: "View")
        func add(_ title: String, _ action: Selector, _ key: String, _ mask: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = target
        }
        add("Reload Page", #selector(WebCommands.reloadWebPage(_:)), "r")
        menu.addItem(.separator())
        add("Back", #selector(WebCommands.webGoBack(_:)), "[")
        add("Forward", #selector(WebCommands.webGoForward(_:)), "]")
        menu.addItem(.separator())
        add("Actual Size", #selector(WebCommands.webActualSize(_:)), "0")
        add("Zoom In", #selector(WebCommands.webZoomIn(_:)), "+")
        add("Zoom Out", #selector(WebCommands.webZoomOut(_:)), "-")
        menu.addItem(.separator())
        add("Open Page in Browser", #selector(WebCommands.openWebPageInBrowser(_:)), "")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = menu
        return menu
    }
}
