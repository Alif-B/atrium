import ApplicationServices
import Foundation

/// Moves one window during a drag as fast as the target app can accept it.
/// Runs the AX writes on a dedicated high-priority queue (so Atrium's own drag never stalls on a slow app) and
/// coalesces: only the newest target is ever sent, so a slow app skips ahead instead of replaying a backlog.
final class LiveMover: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.alif.atrium.livemove", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: (window: AXUIElement, frame: CGRect, resize: Bool)?
    private var draining = false

    /// `frame` is in AX coordinates. `resize` false = position only (one AX call instead of three).
    func move(_ window: AXUIElement, to frame: CGRect, resize: Bool) {
        lock.lock()
        // If a pending job needed a resize, keep that requirement even if the newer one doesn't.
        let keepResize = latest?.resize ?? false
        latest = (window, frame, resize || keepResize)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = latest else { draining = false; lock.unlock(); return }
            latest = nil
            lock.unlock()

            var size = job.frame.size, origin = job.frame.origin
            guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &origin) else { continue }
            if job.resize { AXUIElementSetAttributeValue(job.window, kAXSizeAttribute as CFString, s) }
            AXUIElementSetAttributeValue(job.window, kAXPositionAttribute as CFString, p)
            if job.resize { AXUIElementSetAttributeValue(job.window, kAXSizeAttribute as CFString, s) }
        }
    }
}
