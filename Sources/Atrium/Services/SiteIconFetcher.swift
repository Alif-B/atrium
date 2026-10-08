import AppKit
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "store")

/// Fetches a website's own icon and renders it as a macOS-style app icon (rounded square on the Tahoe icon grid).
/// Order of preference: apple-touch-icon (large, full-bleed), declared icons by size, /apple-touch-icon.png, /favicon.ico.
/// Falls back to a monogram tile, so a web app always gets a decent icon.
enum SiteIconFetcher {
    static var iconsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atrium/Icons", isDirectory: true)
    }

    /// Returns the path of a 512×512 PNG written to Application Support.
    /// Prefers the favicon Edge already has for the site (what the user actually sees), then the network.
    static func makeIcon(for site: URL, name: String, id: String) async -> String? {
        if let path = await iconFromBrowser(for: site, name: name, id: id) { return path }
        let fetched = await fetchBestImage(for: site)
        let png = await MainActor.run { render(fetched.map { ($0.image, $0.fullBleed) }, name: name) }
        return png.flatMap { write($0, id: id) }
    }

    /// Only Edge's stored favicon; nil if Edge hasn't recorded one for this site yet.
    static func iconFromBrowser(for site: URL, name: String, id: String) async -> String? {
        guard let stored = BrowserFavicons.edgeIcon(for: site), var image = NSImage(data: stored.data), image.isValid else { return nil }
        var pixels = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        // Edge keeps only small bitmaps; the original file (often a multi-size .ico or a large PNG) may be sharper.
        if pixels < 120, let source = stored.sourceURL,
           let (data, _) = try? await URLSession(configuration: .ephemeral).data(from: source),
           let original = NSImage(data: data), original.isValid {
            let originalPixels = original.representations.map(\.pixelsWide).max() ?? 0
            if originalPixels > pixels { image = original; pixels = originalPixels }
        }
        let png = await MainActor.run { render((image, pixels >= 120), name: name) }
        return png.flatMap { write($0, id: id) }
    }

    /// A new file name each time, so cached images of the old icon are never reused.
    private static func write(_ png: Data, id: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
            let url = iconsDirectory.appendingPathComponent("\(id)-\(Int(Date().timeIntervalSince1970)).png")
            try png.write(to: url, options: .atomic)
            return url.path
        } catch {
            log.error("icon write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Fetching

    private struct Candidate { var url: URL; var size: Int; var touch: Bool }

    private static func fetchBestImage(for site: URL) async -> (image: NSImage, fullBleed: Bool)? {
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral          // never touches the user's cookies
            c.timeoutIntervalForRequest = 6
            c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
            return c
        }())
        var candidates: [Candidate] = []
        var base = site
        if let (data, response) = try? await session.data(from: site), let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            base = response.url ?? site                       // follow redirects (e.g. a login page on another host)
            candidates = parseIconLinks(html: html, base: base)
        }
        let root = URL(string: "/", relativeTo: base)?.absoluteURL ?? base
        if let u = URL(string: "apple-touch-icon.png", relativeTo: root) { candidates.append(Candidate(url: u, size: 180, touch: true)) }
        if let u = URL(string: "favicon.ico", relativeTo: root) { candidates.append(Candidate(url: u, size: 32, touch: false)) }

        // Best first: touch icons, then bigger declared sizes.
        candidates.sort { ($0.touch ? 1 : 0, $0.size) > ($1.touch ? 1 : 0, $1.size) }
        for c in candidates {
            guard let (data, response) = try? await session.data(from: c.url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = NSImage(data: data), image.isValid else { continue }
            let pixels = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
            guard pixels >= 16 else { continue }
            return (image, c.touch && pixels >= 120)
        }
        return nil
    }

    private static func parseIconLinks(html: String, base: URL) -> [Candidate] {
        guard let linkRegex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        func attr(_ name: String, in tag: String) -> String? {
            let pattern = "\(name)\\s*=\\s*([\"'])(.*?)\\1"
            guard let r = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = r.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let range = Range(m.range(at: 2), in: tag) else { return nil }
            return String(tag[range])
        }
        var result: [Candidate] = []
        for m in linkRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(m.range, in: html) else { continue }
            let tag = String(html[range])
            guard let rel = attr("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attr("href", in: tag), let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let size = attr("sizes", in: tag).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? (rel.contains("apple") ? 180 : 32)
            result.append(Candidate(url: url, size: size, touch: rel.contains("apple-touch")))
        }
        return result
    }

    // MARK: Rendering

    /// 512 px canvas; body = 412 px squircle at (50, 50), radius 92 (the macOS icon grid, scaled from 1024).
    @MainActor
    private static func render(_ source: (NSImage, Bool)?, name: String) -> Data? {
        let px = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        defer { NSGraphicsContext.restoreGraphicsState() }

        let body = CGRect(x: 50, y: 50, width: 412, height: 412)
        let shape = NSBezierPath(roundedRect: body, xRadius: 92, yRadius: 92)

        // Soft drop shadow, like system icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let (image, fullBleed) = source {
            if fullBleed {
                image.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                // Small favicon: centred on a white tile with a whisper of gradient.
                NSGradient(starting: .white, ending: NSColor(white: 0.94, alpha: 1))?.draw(in: shape, angle: -90)
                let side = body.width * 0.56
                image.draw(in: CGRect(x: body.midX - side / 2, y: body.midY - side / 2, width: side, height: side),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
        } else {
            // Monogram fallback on a calm gradient.
            NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.40, blue: 0.95, alpha: 1),
                       ending: NSColor(srgbRed: 0.55, green: 0.31, blue: 1.0, alpha: 1))?.draw(in: shape, angle: -45)
            let letter = String(name.prefix(1)).uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 220, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2), withAttributes: attrs)
        }
        // Hairline inner edge so white icons don't melt into light glass.
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let edge = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 91.5, yRadius: 91.5)
        edge.lineWidth = 1
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
