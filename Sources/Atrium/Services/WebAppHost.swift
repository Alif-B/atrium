import AppKit
import AtriumCore
import OSLog
import WebKit

private let log = Logger(subsystem: "com.alif.atrium", category: "web")

/// Runs the web apps inside Atrium's own window, the way Rambox does: no browser involved. Every web app is a page
/// (see WebPage) laid over Atrium's workspace; only the one on show is visible, the rest keep running out of sight so
/// their badges and notifications stay live. Closing one (or hibernating it) unloads its page.
@MainActor
final class WebAppHost {
    private let store: AppStore
    /// Sits over Atrium's workspace, inside its window.
    let container = WebContainerView()
    private var pages: [String: WebPage] = [:]
    /// The web app whose page is on show (nil while a native app is).
    private(set) var shownID: String?
    /// Every web app's private storage, so a removed app's data can be deleted.
    private var knownStores: [String: UUID] = [:]
    /// Pages playing media or using the camera/microphone (refreshed regularly; hibernation leaves them alone).
    private var busy: Set<String> = []
    private var busyTask: Task<Void, Never>?

    /// The page has something to show (its first load), or couldn't load at all.
    var onReady: (@MainActor (String) -> Void)?
    var onFailed: (@MainActor (String) -> Void)?
    /// A page posted a notification.
    var onNotification: (@MainActor (_ app: ManagedApp, _ title: String, _ body: String, _ noteID: String) -> Void)?

    init(store: AppStore) {
        self.store = store
        for app in store.apps where app.isWebApp { knownStores[app.bundleIdentifier] = WebPage.storeID(for: app) }
        busyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15), tolerance: .seconds(3))
                await self?.refreshBusy()
            }
        }
    }

    func isLoaded(_ id: String) -> Bool { pages[id] != nil }
    func isReady(_ id: String) -> Bool { pages[id]?.isReady == true }
    func title(of id: String) -> String? { pages[id]?.webView.title }
    func isBusy(_ id: String) -> Bool { busy.contains(id) }
    func loadCount(_ id: String) -> Int { pages[id]?.loads ?? 0 }
    var shownPage: WebPage? { shownID.flatMap { pages[$0] } }
    func page(_ id: String) -> WebPage? { pages[id] }

    /// Starts the app's page out of sight (if it isn't running yet).
    @discardableResult
    func load(_ app: ManagedApp) -> WebPage? {
        let id = app.bundleIdentifier
        if let page = pages[id] { return page }
        guard let home = app.webURL.flatMap(URL.init(string:)) else { return nil }
        let page = WebPage(app: app, home: home)
        page.onReady = { [weak self] page in self?.pageReady(page) }
        page.onFail = { [weak self] page in
            self?.store.launchingBundleIDs.remove(page.id)
            self?.onFailed?(page.id)
        }
        page.onNotification = { [weak self] title, body, noteID in
            guard let self, let app = self.store.apps.first(where: { $0.bundleIdentifier == id }) else { return }
            self.onNotification?(app, title, body, noteID)
        }
        page.webView.frame = container.bounds
        container.addSubview(page.webView)
        page.acceptsDrops = false                                  // hidden until it's on show
        pages[id] = page
        knownStores[id] = WebPage.storeID(for: app)
        store.runningBundleIDs.insert(id)
        store.launchingBundleIDs.insert(id)
        log.notice("loading \(id, privacy: .public)")
        return page
    }

    /// Starts every web app that isn't set to hibernate, one after another, so their badges and notifications work.
    func preload(_ apps: [ManagedApp]) async {
        for app in apps where app.isWebApp && !app.hibernates && pages[app.bundleIdentifier] == nil {
            load(app)
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// Puts this app's page on show (starting it if needed; trying again if it had failed). The others are hidden.
    func show(_ app: ManagedApp) {
        let page = load(app)
        if page?.didFail == true { page?.reload() }
        shownID = app.bundleIdentifier
        updateVisibility()
    }

    /// Follows what Atrium shows: a native app hides the pages; nothing (another app in front) changes nothing.
    func activeChanged(_ id: String?) {
        guard let id else { return }
        let next = id.hasPrefix(ManagedApp.webAppIDPrefix) && pages[id] != nil ? id : nil
        guard next != shownID else { return }
        shownID = next
        updateVisibility()
    }

    /// Typing goes to the page on show.
    func focus() {
        guard let page = shownPage, !page.webView.isHidden, let window = container.window else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: page.webView) { return }
        window.makeFirstResponder(page.webView)
    }

    /// True when the point (Atrium window coordinates) is over the page on show.
    func hasContent(at windowPoint: NSPoint) -> Bool {
        guard let page = shownPage, !page.webView.isHidden else { return false }
        return page.webView.bounds.contains(page.webView.convert(windowPoint, from: nil))
    }

    /// Reload the page, or start it if it isn't running.
    func reload(_ app: ManagedApp) {
        if let page = pages[app.bundleIdentifier] { page.reload() } else { load(app) }
    }

    /// Unloads the page (Close, or hibernation). False if it wasn't running.
    @discardableResult
    func close(_ app: ManagedApp) -> Bool { unload(app.bundleIdentifier) }

    func notificationClicked(_ id: String, noteID: String) { pages[id]?.notificationClicked(noteID) }

    func goBack() { shownPage?.webView.goBack() }
    func goForward() { shownPage?.webView.goForward() }
    func zoom(by step: CGFloat?) { shownPage?.zoom(by: step) }
    var shownURL: URL? { shownPage?.webView.url }

    /// The sidebar list changed: a removed web app's page and private data go; an edited address loads.
    func syncApps() {
        let current = Dictionary(store.apps.filter(\.isWebApp).map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, page) in pages {
            if let app = current[id] {
                if let url = app.webURL.flatMap(URL.init(string:)), url != page.home { page.go(home: url) }
            }
        }
        for (id, storeID) in knownStores where current[id] == nil {
            knownStores[id] = nil
            unload(id)
            Task {
                try? await Task.sleep(for: .seconds(2))            // the page must be gone before its storage is
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: storeID)
                    log.notice("deleted the website data of removed web app \(id, privacy: .public)")
                } catch {
                    log.error("couldn't delete website data of \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        for (id, app) in current where knownStores[id] == nil { knownStores[id] = WebPage.storeID(for: app) }
    }

    // MARK: Private

    @discardableResult
    private func unload(_ id: String) -> Bool {
        guard let page = pages.removeValue(forKey: id) else { return false }
        page.close()
        if shownID == id { shownID = nil }
        busy.remove(id)
        store.runningBundleIDs.remove(id)
        store.launchingBundleIDs.remove(id)
        store.badges[id] = nil
        log.notice("unloaded \(id, privacy: .public)")
        return true
    }

    private func pageReady(_ page: WebPage) {
        store.launchingBundleIDs.remove(page.id)
        updateVisibility()
        onReady?(page.id)
    }

    private func updateVisibility() {
        for (id, page) in pages {
            let visible = id == shownID && page.isReady
            if page.webView.isHidden == visible { page.webView.isHidden = !visible }
            page.acceptsDrops = visible
        }
        // macOS gives a drag to the topmost view under the pointer, hidden or not: the page on show must be on top.
        // (Reordering in place: no page leaves the window, so none reloads or flickers.)
        if let top = container.subviews.last, top.isHidden, container.subviews.contains(where: { !$0.isHidden }) {
            container.sortSubviews({ a, b, _ in
                a.isHidden == b.isHidden ? .orderedSame : (a.isHidden ? .orderedAscending : .orderedDescending)
            }, context: nil)
        }
    }

    private func refreshBusy() async {
        let hibernating = Set(store.apps.filter { $0.isWebApp && $0.hibernates }.map(\.bundleIdentifier))
        var now: Set<String> = []
        for (id, page) in pages where hibernating.contains(id) {
            if await page.isBusy() { now.insert(id) }
        }
        busy = now
    }
}

/// Holds the web pages over Atrium's workspace, with corners concentric with the window's.
final class WebContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.webCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
    override var mouseDownCanMoveWindow: Bool { false }     // a drag on a page selects text; it never moves Atrium
}
