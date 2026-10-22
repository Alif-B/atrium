import AppKit
import ScreenCaptureKit
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "snapshot")

/// Keeps a recent still image of the window Atrium is showing, for smooth moving and switching (ScreenCaptureKit).
/// Needs the Screen Recording permission; without it, `image` stays nil and callers fall back to plain behaviour.
@MainActor
final class WindowSnapshotter {
    private(set) var image: CGImage?
    private(set) var windowNumber = 0
    /// The sidebar app the picture shows (it stays usable while that app's window is hidden).
    private(set) var slot: String?
    private(set) var takenAt = Date.distantPast
    private var inFlight = false

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (once); the person turns Atrium on in System Settings ▸ Privacy & Security ▸ Screen Recording.
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    func image(forSlot id: String, maxAge: TimeInterval) -> CGImage? {
        guard id == slot, Date().timeIntervalSince(takenAt) <= maxAge else { return nil }
        return image
    }

    func image(forWindow number: Int, maxAge: TimeInterval) -> CGImage? {
        guard number == windowNumber, Date().timeIntervalSince(takenAt) <= maxAge else { return nil }
        return image
    }

    /// Captures the window (by its window-server number) in the background; cheap enough to call on hover.
    func refresh(windowNumber number: Int, slot id: String) {
        Task { await capture(windowNumber: number, slot: id) }
    }

    /// Captures the window now and returns once the picture is ready (or the capture failed).
    func capture(windowNumber number: Int, slot id: String) async {
        guard Self.hasPermission, !inFlight else { return }
        if number == windowNumber, Date().timeIntervalSince(takenAt) < 0.75 { return }      // fresh enough
        inFlight = true
        defer { inFlight = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == number }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            image = captured
            windowNumber = number
            slot = id
            takenAt = Date()
        } catch {
            log.debug("snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
