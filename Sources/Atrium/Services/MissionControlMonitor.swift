import AppKit
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "move")

/// Notices Mission Control (and App Exposé) opening and closing. macOS has no notification for it, but while it is
/// open the Dock covers each display with full-screen overlay windows (window layers 18 and 20) that aren't there
/// otherwise. If a future macOS changes that, this simply never fires and Atrium behaves as before.
@MainActor
final class MissionControlMonitor {
    /// Mission Control opened (true) or closed (false).
    var onChange: (@MainActor (Bool) -> Void)?
    /// Only look while this is true (Atrium's window is on screen with apps in it).
    var isWanted: (@MainActor () -> Bool)?
    private(set) var isOpen = false
    private var misses = 0
    private var timer: Timer?

    static let overlayLayers: Set<Int> = [18, 20]
    /// Polls this often: Mission Control's opening animation lasts about a third of a second.
    static let interval: TimeInterval = 0.08
    /// Closed only after this many empty looks in a row, so one odd sample doesn't flicker the apps.
    static let missesToClose = 2

    func start() {
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isOpen || isWanted?() != false else { return }
        let open = Self.overlayIsUp()
        if open {
            misses = 0
            guard !isOpen else { return }
            isOpen = true
            log.notice("Mission Control opened")
            onChange?(true)
        } else if isOpen {
            misses += 1
            guard misses >= Self.missesToClose else { return }
            isOpen = false
            misses = 0
            log.notice("Mission Control closed")
            onChange?(false)
        }
    }

    /// A Dock-owned overlay window exactly the size of one of the displays.
    private static func overlayIsUp() -> Bool {
        let screens = Set(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" })
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Dock",
                  let layer = w[kCGWindowLayer as String] as? Int, overlayLayers.contains(layer),
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { return false }
            return screens.contains("\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
        }
    }
}
