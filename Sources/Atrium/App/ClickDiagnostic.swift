import AppKit
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "switcher")

/// Developer aid for the switching "blip": posts a real click on a rail icon and samples, on a background thread, which
/// window is in front in the workspace area: Atrium's backdrop or an app.
enum ClickDiagnostic {
    /// `iconCenter` in Quartz (top-left) global coordinates. `atrium` is the main window's number.
    @MainActor
    static func run(iconCenter: CGPoint, atrium: Int, workspaceCenter: CGPoint) {
        let samples = Samples()
        let start = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos: .userInteractive).async {
            while (DispatchTime.now().uptimeNanoseconds - start) < 900_000_000 {
                samples.add(ms: Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000), owner: frontOwner(at: workspaceCenter, atrium: atrium))
                usleep(3000)
            }
            log.notice("diag click timeline: \(samples.summary(), privacy: .public)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: iconCenter, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: iconCenter, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            usleep(60_000)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Posts a real drag (press, move in steps, release) starting at `from` (Quartz coordinates).
    static func drag(from: CGPoint, by dx: CGFloat, then done: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            func post(_ type: CGEventType, _ p: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, from); usleep(80_000)
            post(.leftMouseDown, from); usleep(60_000)
            for i in 1...20 { post(.leftMouseDragged, CGPoint(x: from.x + dx * CGFloat(i) / 20, y: from.y)); usleep(16_000) }
            usleep(60_000)
            post(.leftMouseUp, CGPoint(x: from.x + dx, y: from.y))
            usleep(400_000)
            done()
        }
    }

    /// The owner of the front-most normal window covering `point` (Atrium's own window reported as "ATRIUM").
    private static func frontOwner(at point: CGPoint, atrium: Int) -> String {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.contains(point), r.width > 300 else { continue }
            if (w[kCGWindowNumber as String] as? Int) == atrium { return "ATRIUM" }
            return (w[kCGWindowOwnerName as String] as? String) ?? "?"
        }
        return "none"
    }

    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var runs: [(owner: String, from: Int, to: Int)] = []
        func add(ms: Int, owner: String) {
            lock.lock(); defer { lock.unlock() }
            if let last = runs.last, last.owner == owner { runs[runs.count - 1].to = ms } else { runs.append((owner, ms, ms)) }
        }
        func summary() -> String {
            lock.lock(); defer { lock.unlock() }
            return runs.map { "\($0.owner) \($0.from)-\($0.to)ms" }.joined(separator: " → ")
        }
    }
}
