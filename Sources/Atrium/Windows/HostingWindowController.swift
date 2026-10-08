import AppKit
import SwiftUI

/// A window whose content is a SwiftUI view. Reusable: `present()` shows or re-fronts it.
@MainActor
final class HostingWindowController: NSWindowController {
    init<Content: View>(title: String, size: NSSize, transparentTitlebar: Bool, rootView: Content) {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if transparentTitlebar { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: rootView)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        if transparentTitlebar {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func dismiss() { window?.close() }
}
