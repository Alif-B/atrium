// Run: swift scripts/make-icon.swift   → writes Resources/AppIcon.iconset/*.png and Resources/AppIcon.icns
import AppKit

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(pixels) / 1024
    ctx.cgContext.scaleBy(x: s, y: s)          // draw in a 1024 canvas, y up

    func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }

    // Squircle body: 824 × 824 at (100, 100), radius ≈ 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = rounded(body, 185)
    NSGradient(starting: color(0x3B3FD8), ending: color(0x8B4DFF))!.draw(in: bodyPath, angle: -45)
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: CGRect(x: 100, y: 594, width: 824, height: 330), angle: -90)

    func shadowed(_ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
        sh.shadowBlurRadius = 24
        sh.shadowOffset = NSSize(width: 0, height: -12)
        sh.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Workspace pane (right).
    let pane = CGRect(x: 350, y: 232, width: 484, height: 560)
    shadowed {
        NSColor.white.withAlphaComponent(0.22).setFill()
        rounded(pane, 44).fill()
    }
    NSColor.white.withAlphaComponent(0.5).setStroke()
    let paneStroke = rounded(pane.insetBy(dx: 1.5, dy: 1.5), 43)
    paneStroke.lineWidth = 3
    paneStroke.stroke()

    // Sidebar pill (left) with three tiles.
    let pill = CGRect(x: 190, y: 232, width: 120, height: 560)
    shadowed {
        NSGradient(starting: NSColor.white.withAlphaComponent(0.85), ending: NSColor.white.withAlphaComponent(0.65))!
            .draw(in: rounded(pill, 60), angle: -90)
    }
    let tileColors: [UInt32] = [0x3B3FD8, 0x6A47EE, 0x8B4DFF]
    for (i, c) in tileColors.enumerated() {
        let tile = CGRect(x: pill.midX - 32, y: pill.maxY - 110 - CGFloat(i) * 96, width: 64, height: 64)
        color(c, 0.35).setFill()
        rounded(tile, 16).fill()
    }
    NSGraphicsContext.restoreGraphicsState()   // clip
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
