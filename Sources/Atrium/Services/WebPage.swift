import AppKit
import AtriumCore
import OSLog
import WebKit

private let log = Logger(subsystem: "com.alif.atrium", category: "web")

/// One web app, running inside Atrium: its own web view with its own private website data (cookies, sign-ins,
/// storage), kept apart from every browser and from the other web apps. Links to other sites open in the default
/// browser; sign-in windows open as small windows of their own; downloads go to Downloads.
@MainActor
final class WebPage: NSObject {
    let id: String
    private(set) var home: URL
    let webView: WKWebView
    /// Something is on screen (the first load finished, or committed a moment ago). Hidden until then.
    private(set) var isReady = false
    /// The first load failed (offline, bad address): `reload` starts over from the home page.
    private(set) var didFail = false
    /// Finished loads so far (used by the diagnostics).
    private(set) var loads = 0
    var onReady: (@MainActor (WebPage) -> Void)?
    var onFail: (@MainActor (WebPage) -> Void)?
    var onNotification: (@MainActor (_ title: String, _ body: String, _ noteID: String) -> Void)?

    private var popups: [WebPopup] = []
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var readyTask: Task<Void, Never>?

    /// Each web app's private storage, named after the UUID in its sidebar id (stable for the app's whole life).
    static func storeID(for app: ManagedApp) -> UUID {
        UUID(uuidString: String(app.bundleIdentifier.dropFirst(ManagedApp.webAppIDPrefix.count))) ?? app.id
    }

    /// Completes WebKit's user agent to Safari's own, so sites treat the page exactly like Safari.
    private static var safariSuffix: String {
        "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 Safari/605.1.15"
    }

    private static func zoomKey(_ id: String) -> String { "webZoom.\(id)" }

    init(app: ManagedApp, home: URL) {
        id = app.bundleIdentifier
        self.home = home
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID(for: app))
        config.applicationNameForUserAgent = Self.safariSuffix
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: WebScripts.notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = scripts
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        scripts.add(ScriptBridge(self), name: WebScripts.notifyHandler)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.autoresizingMask = [.width, .height]
        webView.isHidden = true
        let zoom = UserDefaults.standard.double(forKey: Self.zoomKey(id))
        if zoom > 0 { webView.pageZoom = zoom }
        webView.load(URLRequest(url: home))
    }

    // MARK: Actions

    func reload() {
        if didFail || webView.url == nil {
            didFail = false
            webView.load(URLRequest(url: home))
        } else {
            webView.reload()
        }
    }

    /// The app's address was edited: start over there.
    func go(home newHome: URL) {
        home = newHome
        didFail = false
        webView.load(URLRequest(url: newHome))
    }

    func zoom(by step: CGFloat?) {
        let value = step.map { min(DesignTokens.webZoomRange.upperBound, max(DesignTokens.webZoomRange.lowerBound, webView.pageZoom + $0)) } ?? 1
        webView.pageZoom = value
        UserDefaults.standard.set(Double(value), forKey: Self.zoomKey(id))
    }

    func notificationClicked(_ noteID: String) {
        webView.evaluateJavaScript(WebScripts.notificationClick(id: noteID), completionHandler: nil)
    }

    /// Playing sound or video, or using the camera or microphone: never put to sleep then.
    func isBusy() async -> Bool {
        if webView.cameraCaptureState == .active || webView.microphoneCaptureState == .active { return true }
        return await webView.requestMediaPlaybackState() == .playing
    }

    /// Stops everything and lets go of the page (closing, hibernating, or the app was removed).
    func close() {
        readyTask?.cancel()
        for popup in popups { popup.window.close() }
        popups = []
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    fileprivate func received(_ body: Any) {
        guard let note = body as? [String: Any] else { return }
        onNotification?(note["title"] as? String ?? "", note["body"] as? String ?? "", note["id"] as? String ?? "")
    }

    private func markReady() {
        readyTask?.cancel()
        guard !isReady else { return }
        isReady = true
        onReady?(self)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        // Cancelled (a newer load replaced it), or handed over to a download / another app: not a failure.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == WKError.errorDomain && [102, 204].contains(e.code) { return }
        log.notice("\(self.id, privacy: .public) failed to load: \(e.localizedDescription, privacy: .public)")
        guard !isReady else { return }
        didFail = true
        onFail?(self)
    }
}

// MARK: - Navigation

extension WebPage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let frame = action.targetFrame, let url = action.request.url else { return .allow }   // a new window: see createWebViewWith
        switch WebLinks.navigation(url: url, isLinkClick: action.navigationType == .linkActivated, isMainFrame: frame.isMainFrame, home: home) {
        case .allow: return .allow
        case .external:
            NSWorkspace.shared.open(url)
            return .cancel
        case .cancel: return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { return .download }
        if let http = response.response as? HTTPURLResponse,
           (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isReady, readyTask == nil else { return }
        // Big apps keep loading long after they show something: reveal the page shortly after it starts drawing.
        readyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.markReady()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loads += 1
        didFail = false
        markReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        readyTask?.cancel(); readyTask = nil
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("\(self.id, privacy: .public): page crashed; reloading")
        reload()
    }
}

// MARK: - Windows, dialogs, files, camera

extension WebPage: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        switch WebLinks.newWindow(url: url, isLinkClick: action.navigationType == .linkActivated, home: home) {
        case .external:
            if let url { NSWorkspace.shared.open(url) }
            return nil
        case .ignore:
            return nil
        case .popup, .undecided:
            let popup = WebPopup(configuration: configuration, features: windowFeatures, home: home,
                                 undecided: url.map { !WebLinks.keepsPopup($0, home: home) } ?? true, near: webView.window)
            popup.onClose = { [weak self, weak popup] in self?.popups.removeAll { $0 === popup } }
            popups.append(popup)
            return popup.webView
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = Dialogs.alert(message, from: frame, buttons: ["OK"])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        Dialogs.alert(message, from: frame, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 280
        return Dialogs.alert(prompt, from: frame, buttons: ["OK", "Cancel"], accessory: field) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }

    /// Camera and microphone: the app's own site may use them (calls); anything else embedded in it is asked about.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let url = URL(string: "\(origin.protocol)://\(origin.host)") else { return .prompt }
        return WebLinks.isSameSite(url, as: home) ? .grant : .prompt
    }
}

// MARK: - Downloads

extension WebPage: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        downloads[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        log.notice("\(self.id, privacy: .public) downloaded \(url.lastPathComponent, privacy: .public)")
        // Bounces the Downloads stack in the Dock, as Safari does.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        log.error("\(self.id, privacy: .public) download failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// Passes the page's notifications to its WebPage without the page's script controller keeping the page alive.
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    private weak var page: WebPage?
    init(_ page: WebPage) { self.page = page }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        page?.received(message.body)
    }
}

@MainActor
private enum Dialogs {
    static func alert(_ message: String, from frame: WKFrameInfo, buttons: [String], accessory: NSView? = nil) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? AppInfo.name : frame.securityOrigin.host
        alert.informativeText = message
        for title in buttons { alert.addButton(withTitle: title) }
        alert.accessoryView = accessory
        return alert.runModal()
    }
}

/// A window a page opened for itself: usually a sign-in ("Continue with Google"). It shares the page's session and
/// talks back to it, then closes itself. A blank one is only shown once its address turns out to belong here.
@MainActor
final class WebPopup: NSObject {
    let webView: WKWebView
    let window: NSWindow
    var onClose: (@MainActor () -> Void)?
    private let home: URL
    private var undecided: Bool

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, home: URL, undecided: Bool, near parent: NSWindow?) {
        self.home = home
        self.undecided = undecided
        webView = WKWebView(frame: .zero, configuration: configuration)
        let size = CGSize(width: features.width.map { CGFloat($0.doubleValue) } ?? DesignTokens.webPopupSize.width,
                          height: features.height.map { CGFloat($0.doubleValue) } ?? DesignTokens.webPopupSize.height)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let parent {
            let p = parent.frame
            window.setFrameOrigin(CGPoint(x: p.midX - size.width / 2, y: p.midY - size.height / 2))
        } else {
            window.center()
        }
        if undecided {
            Task { [weak self] in                              // a blank page the opener writes into itself (e.g. print)
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, self.undecided, !self.window.isVisible else { return }
                self.undecided = false
                self.show()
            }
        } else {
            show()
        }
    }

    private func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

extension WebPopup: WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard undecided, action.targetFrame?.isMainFrame == true, let url = action.request.url,
              WebLinks.isWebScheme(url), url.absoluteString != "about:blank" else { return .allow }
        undecided = false
        if WebLinks.keepsPopup(url, home: home) {
            show()
            return .allow
        }
        NSWorkspace.shared.open(url)
        window.close()
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { window.title = webView.title ?? "" }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, WebLinks.isWebScheme(url) { NSWorkspace.shared.open(url) }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) { window.close() }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onClose?()
    }
}
