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
