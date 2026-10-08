import Foundation
import Testing
@testable import AtriumCore

@Test func normalizesBareHosts() {
    #expect(WebAddress.normalize("jira.acme.com")?.absoluteString == "https://jira.acme.com")
    #expect(WebAddress.normalize(" https://mail.google.com/mail ")?.absoluteString == "https://mail.google.com/mail")
    #expect(WebAddress.normalize("not a url") == nil)
    #expect(WebAddress.normalize("nodot") == nil)
}

@Test func suggestsNameFromHost() {
    #expect(WebAddress.suggestedName(for: URL(string: "https://mail.google.com")!) == "Mail")
    #expect(WebAddress.suggestedName(for: URL(string: "https://www.notion.so")!) == "Notion")
}

@Test func webAppFieldsRoundTripAndOldJSONStillDecodes() throws {
    let app = ManagedApp(bundleIdentifier: "atrium.web.x", displayName: "Jira", lastKnownPath: "",
                         webURL: "https://jira.acme.com", browserBundleID: "com.microsoft.edgemac", iconFile: "/tmp/x.png")
    let back = try JSONDecoder().decode(ManagedApp.self, from: JSONEncoder().encode(app))
    #expect(back == app)
    #expect(back.isWebApp)
    let old = try JSONDecoder().decode(ManagedApp.self, from: Data(#"{"bundleIdentifier":"a","displayName":"A","lastKnownPath":"/a"}"#.utf8))
    #expect(!old.isWebApp)
}

@Test func customIconFlagRoundTripsAndDefaultsToFalse() throws {
    let app = ManagedApp(bundleIdentifier: "atrium.web.y", displayName: "Y", lastKnownPath: "", webURL: "https://y.example.com", customIcon: true)
    #expect(try JSONDecoder().decode(ManagedApp.self, from: JSONEncoder().encode(app)).customIcon)
    let old = try JSONDecoder().decode(ManagedApp.self, from: Data(#"{"bundleIdentifier":"a","displayName":"A","lastKnownPath":"/a","webURL":"https://a.com"}"#.utf8))
    #expect(!old.customIcon)
}
