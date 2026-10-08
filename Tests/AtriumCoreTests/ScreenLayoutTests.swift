import CoreGraphics
import Testing
@testable import AtriumCore

private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)   // menu bar already excluded

@Test func leftEdgeFrames() {
    let r = ScreenLayout.compute(visibleFrame: visible, edge: .left)
    #expect(r.panel == CGRect(x: 0, y: 0, width: 80, height: 875))
    #expect(r.glass == CGRect(x: 8, y: 8, width: 64, height: 859))
    #expect(r.workspace == CGRect(x: 80, y: 8, width: 1352, height: 859))
}

@Test func rightEdgeMirrorsLeft() {
    let r = ScreenLayout.compute(visibleFrame: visible, edge: .right)
    #expect(r.panel == CGRect(x: 1360, y: 0, width: 80, height: 875))
    #expect(r.glass == CGRect(x: 1368, y: 8, width: 64, height: 859))
    #expect(r.workspace == CGRect(x: 8, y: 8, width: 1352, height: 859))
}

@Test func gapsAreEvenBetweenGlassAndWorkspace() {
    let r = ScreenLayout.compute(visibleFrame: visible, edge: .left)
    #expect(r.workspace.minX - r.glass.maxX == LayoutConstants.gap)
    #expect(visible.maxX - r.workspace.maxX == LayoutConstants.gap)
}

@Test func dockOnLeftOffsetsVisibleFrame() {
    let v = CGRect(x: 60, y: 0, width: 1380, height: 875)
    let r = ScreenLayout.compute(visibleFrame: v, edge: .left)
    #expect(r.panel.minX == 60)
    #expect(r.workspace.maxX == 1432)
}

@Test func dockOnBottomOffsetsVisibleFrame() {
    let v = CGRect(x: 0, y: 70, width: 1440, height: 805)
    let r = ScreenLayout.compute(visibleFrame: v, edge: .left)
    #expect(r.glass.minY == 78)
    #expect(r.workspace.height == 789)
}

// Primary: (0,0,1440,900). Cocoa y grows up, AX y grows down from the primary's top-left.
private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

@Test func axConversionOnPrimary() {
    let ax = ScreenLayout.axRect(fromCocoa: CGRect(x: 60, y: 0, width: 1380, height: 875), primaryScreenFrame: primary)
    #expect(ax == CGRect(x: 60, y: 25, width: 1380, height: 875))
}

@Test func axConversionSecondaryAbove() {
    // Display above the primary: Cocoa y 900..1800 → AX y negative.
    let ax = ScreenLayout.axRect(fromCocoa: CGRect(x: 0, y: 900, width: 1440, height: 875), primaryScreenFrame: primary)
    #expect(ax.minY == -875)
}

@Test func axConversionSecondaryBelow() {
    let ax = ScreenLayout.axRect(fromCocoa: CGRect(x: 0, y: -900, width: 1440, height: 875), primaryScreenFrame: primary)
    #expect(ax.minY == 925)
}

@Test func axConversionSecondaryLeftAndRight() {
    let left = ScreenLayout.axRect(fromCocoa: CGRect(x: -1440, y: 0, width: 1440, height: 875), primaryScreenFrame: primary)
    #expect(left.minX == -1440)
    let right = ScreenLayout.axRect(fromCocoa: CGRect(x: 1440, y: 0, width: 1440, height: 875), primaryScreenFrame: primary)
    #expect(right.minX == 1440)
}
