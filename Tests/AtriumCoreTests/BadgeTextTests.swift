import Testing
@testable import AtriumCore

@Test func emptyAndWhitespaceAreNil() {
    #expect(BadgeText.parse("") == nil)
    #expect(BadgeText.parse("  ") == nil)
}

@Test func countsParseAndCap() {
    #expect(BadgeText.parse("3") == .count(3))
    #expect(BadgeText.parse("120") == .count(120))
    #expect(BadgeText.count(120).display == "99+")
    #expect(BadgeText.count(99).display == "99")
    #expect(BadgeText.parse("0") == nil)
}

@Test func dotMarkers() {
    #expect(BadgeText.parse("•") == .dot)
    #expect(BadgeText.parse("●") == .dot)
    #expect(BadgeText.parse(".") == .dot)
}

@Test func shortTextShownLongTextBecomesDot() {
    #expect(BadgeText.parse("!") == .text("!"))
    #expect(BadgeText.parse("unread") == .dot)
}

@Test func unreadCountFromPageTitles() {
    #expect(TitleBadge.parse("Inbox (12) - me@gmail.com - Gmail") == .count(12))
    #expect(TitleBadge.parse("(3) Messenger") == .count(3))
    #expect(TitleBadge.parse("[2] Team chat") == .count(2))
    #expect(TitleBadge.parse("Google Calendar - October 2026") == nil)
    #expect(TitleBadge.parse("Report (2024) final") == nil)         // a year
    #expect(TitleBadge.parse("Plain title") == nil)
    #expect(TitleBadge.parse("Inbox (0)") == nil)
}
