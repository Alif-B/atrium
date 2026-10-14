import Foundation

/// Where a link inside a web app goes: it stays in the app, opens as a small sign-in window, or goes to the default
/// browser (like a "new tab" would in a browser). Pure rules, so they can be tested.
public enum WebLinks {
    public enum NewWindow: Equatable, Sendable {
        case popup          // a sign-in or same-site window the page needs (it talks back to the page)
        case undecided      // a blank window the page fills in a moment: decided on its first real address
        case external       // the default browser
        case ignore
    }

    public enum Navigation: Equatable, Sendable {
        case allow
        case external
        case cancel
    }

    /// Hosts that sign you in. They stay inside the app, so the session lands where it is needed.
    static let signInHosts: Set<String> = [
        "accounts.google.com", "accounts.youtube.com", "login.microsoftonline.com", "login.microsoft.com", "login.live.com",
        "appleid.apple.com", "id.atlassian.com", "auth.atlassian.com", "www.facebook.com", "facebook.com", "m.facebook.com",
    ]
    static let signInSuffixes = [".okta.com", ".auth0.com", ".onelogin.com"]
    static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]
    /// Second-level labels used under country domains ("co.uk", "com.au"): the site is one label further left.
    static let secondLevelLabels: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu"]

    public static func isWebScheme(_ url: URL) -> Bool { webSchemes.contains(url.scheme?.lowercased() ?? "") }

    public static func isSignIn(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return signInHosts.contains(host) || signInSuffixes.contains { host.hasSuffix($0) }
    }

    /// "mail.google.com" → "google.com", "news.bbc.co.uk" → "bbc.co.uk".
    public static func site(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let last = labels[labels.count - 1], second = labels[labels.count - 2]
        let keep = last.count == 2 && secondLevelLabels.contains(second) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    public static func isSameSite(_ url: URL, as home: URL) -> Bool {
        guard let a = url.host(), let b = home.host() else { return false }
        return site(of: a) == site(of: b)
    }

    static func isBlank(_ url: URL?) -> Bool {
        guard let url else { return true }
        let s = url.absoluteString
        return s.isEmpty || s == "about:blank"
    }

    /// The page asked for a new window (a `target=_blank` link or `window.open`).
    public static func newWindow(url: URL?, isLinkClick: Bool, home: URL) -> NewWindow {
        if isBlank(url) { return .undecided }
        guard let url else { return .ignore }
        if !isWebScheme(url) { return .external }
        if isSignIn(url) { return .popup }
        if isLinkClick { return .external }                      // a link that would open a new tab
        return isSameSite(url, as: home) ? .popup : .external
    }

    /// A navigation inside the app's page (or one of its frames).
    public static func navigation(url: URL, isLinkClick: Bool, isMainFrame: Bool, home: URL) -> Navigation {
        if !isWebScheme(url) { return isLinkClick || isMainFrame ? .external : .cancel }   // mailto:, zoommtg:, slack:…
        if isMainFrame, isLinkClick, !isSameSite(url, as: home), !isSignIn(url) { return .external }
        return .allow                                            // redirects (sign-in, SSO) and frames go anywhere
    }

    /// A blank popup got its first real address: keep it as a window, or hand the address to the default browser.
    public static func keepsPopup(_ url: URL, home: URL) -> Bool {
        isWebScheme(url) && (isSignIn(url) || isSameSite(url, as: home))
    }
}
