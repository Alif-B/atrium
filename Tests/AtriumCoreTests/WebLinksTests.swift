import Foundation
import Testing
@testable import AtriumCore

private let gmail = URL(string: "https://mail.google.com/mail/u/0/#inbox")!
private let jira = URL(string: "https://intime-soft.atlassian.net/jira/software")!

@Test func siteIgnoresSubdomainsAndKnowsCountryDomains() {
    #expect(WebLinks.site(of: "mail.google.com") == "google.com")
    #expect(WebLinks.site(of: "google.com") == "google.com")
    #expect(WebLinks.site(of: "news.bbc.co.uk") == "bbc.co.uk")
    #expect(WebLinks.site(of: "a.b.example.io") == "example.io")
}

@Test func newTabLinksGoToTheBrowserButSignInStaysInside() {
    #expect(WebLinks.newWindow(url: URL(string: "https://docs.google.com/x")!, isLinkClick: true, home: gmail) == .external)
    #expect(WebLinks.newWindow(url: URL(string: "https://example.com")!, isLinkClick: false, home: gmail) == .external)
    #expect(WebLinks.newWindow(url: URL(string: "https://accounts.google.com/o/oauth2")!, isLinkClick: false, home: jira) == .popup)
    #expect(WebLinks.newWindow(url: URL(string: "https://mail.google.com/popout")!, isLinkClick: false, home: gmail) == .popup)
    #expect(WebLinks.newWindow(url: nil, isLinkClick: false, home: gmail) == .undecided)
    #expect(WebLinks.newWindow(url: URL(string: "about:blank")!, isLinkClick: false, home: gmail) == .undecided)
    #expect(WebLinks.newWindow(url: URL(string: "mailto:a@b.com")!, isLinkClick: true, home: gmail) == .external)
}

@Test func navigationsStayUnlessALinkLeavesTheSite() {
    #expect(WebLinks.navigation(url: URL(string: "https://mail.google.com/x")!, isLinkClick: true, isMainFrame: true, home: gmail) == .allow)
    #expect(WebLinks.navigation(url: URL(string: "https://example.com")!, isLinkClick: true, isMainFrame: true, home: gmail) == .external)
    // Redirects (sign-in, SSO) and frames may go anywhere.
    #expect(WebLinks.navigation(url: URL(string: "https://login.microsoftonline.com/x")!, isLinkClick: false, isMainFrame: true, home: jira) == .allow)
    #expect(WebLinks.navigation(url: URL(string: "https://ads.example.com")!, isLinkClick: true, isMainFrame: false, home: gmail) == .allow)
    #expect(WebLinks.navigation(url: URL(string: "zoommtg://join")!, isLinkClick: true, isMainFrame: true, home: gmail) == .external)
    #expect(WebLinks.navigation(url: URL(string: "slack://open")!, isLinkClick: false, isMainFrame: false, home: gmail) == .cancel)
}

@Test func blankPopupsAreKeptOnlyForSignInOrTheSameSite() {
    #expect(WebLinks.keepsPopup(URL(string: "https://accounts.google.com/x")!, home: jira))
    #expect(WebLinks.keepsPopup(URL(string: "https://acme.okta.com/x")!, home: jira))
    #expect(WebLinks.keepsPopup(URL(string: "https://mail.google.com/print")!, home: gmail))
    #expect(!WebLinks.keepsPopup(URL(string: "https://example.com")!, home: gmail))
}

@Test func aSignInWindowFromALinkHandsBackToTheApp() {
    let signIn = URL(string: "https://accounts.google.com/v3/signin")!
    let done = URL(string: "https://mail.google.com/mail/u/0/")!
    #expect(WebLinks.popupStep(url: signIn, home: gmail, openedByLink: true) == .stay)
    #expect(WebLinks.popupStep(url: done, home: gmail, openedByLink: true) == .toApp)
    #expect(WebLinks.popupStep(url: URL(string: "https://example.com")!, home: gmail, openedByLink: true) == .external)
    // Opened by the page's own script ("Continue with Google"): the page is waiting on that window; leave it alone.
    #expect(WebLinks.popupStep(url: done, home: gmail, openedByLink: false) == .stay)
}
