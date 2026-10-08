import Testing
@testable import AtriumCore

@Test func sidebarWidthMatchesDesignTokens() {
    #expect(LayoutConstants.sidebarWidth == 64)
    #expect(LayoutConstants.itemPitch == 48)
}
