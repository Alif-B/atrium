import AppKit
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "move")

/// Makes Atrium and its apps behave like ONE window whenever Atrium moves, resizes, zooms, minimizes, closes or hides:
///  1. a still image of the current app is put inside Atrium (behind the real window, so nothing changes yet);
///  2. the apps with windows in Atrium are hidden, revealing the image, which then goes wherever Atrium goes;
///  3. when Atrium is back at rest (or shown again), every window is moved to the right place *while still hidden*,
///     the apps are shown again right there, and the image is removed once they are back.
/// Without the Screen Recording permission there is no image: the area is simply empty meanwhile.
@MainActor
final class MoveCoordinator {
    enum Reason: Hashable { case moving, closed, minimized, appHidden, missionControl }

    private let store: AppStore
    private let snapper: WindowSnapper
    private let sidebar: SidebarController
    private let snapshotter: WindowSnapshotter
    private var reasons: Set<Reason> = []
    private var hiddenByUs: [NSRunningApplication] = []
    private var activeAtStart: String?
    /// Mission Control: whether you were using Atrium (or one of its apps) when it opened.
    private var mcFromAtrium = false

    /// Apps are hidden and Atrium is showing its image (or nothing): don't follow, reorder or react to activations.
    var isMoving: Bool { !reasons.isEmpty }
    /// Called once everything is back in place (Atrium re-slots itself under the app).
    var onSettled: (@MainActor () -> Void)?

    init(store: AppStore, snapper: WindowSnapper, sidebar: SidebarController, snapshotter: WindowSnapshotter) {
        self.store = store
        self.snapper = snapper
        self.sidebar = sidebar
        self.snapshotter = snapshotter
    }

    func began() { conceal(.moving) }

    /// Atrium is quitting: never leave its apps hidden behind.
    func releaseAll() {
        for app in hiddenByUs { app.unhide() }
        hiddenByUs = []
        reasons.removeAll()
        snapper.isSuspended = false
    }
    func ended() { reveal(.moving) }

    /// Mission Control shows every window separately. While it's open, Atrium's apps step aside so Atrium appears
    /// as one window, showing a still image of the app you were on.
    func missionControlOpened() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        mcFromAtrium = front == ProcessInfo.processInfo.processIdentifier || front.map(snapper.placedPIDs.contains) == true
        conceal(.missionControl)
    }

    /// Back from Mission Control. The app you were on gets focus again, unless you clicked another app's window there.
    /// (Leaving without a click, by Escape or a gesture, lets macOS bring forward whatever window is on top, which with
    /// Atrium's apps still hidden is some other app: that's not your choice, so it's undone.)
    func missionControlClosed() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pickedAtrium = front == ProcessInfo.processInfo.processIdentifier
        let clicked = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown) < 1
        reveal(.missionControl, restoreFocus: pickedAtrium || (!clicked && mcFromAtrium))
    }

    func conceal(_ reason: Reason) {
        let first = reasons.isEmpty
        reasons.insert(reason)
        guard first, store.isAXTrusted, snapper.hasPlacedWindows else { return }
        snapper.isSuspended = true
        activeAtStart = store.activeBundleID
        // Mission Control can come at any moment: an older picture of the app is better than an empty window.
        let maxAge: TimeInterval = reason == .missionControl ? 1800 : 120
        var pictured = false
        if let id = activeAtStart, let number = snapper.windowNumber(slot: id),
           let image = snapshotter.image(forWindow: number, maxAge: maxAge) {
            sidebar.showSnapshot(image)
            pictured = true
        }
        hiddenByUs = snapper.placedPIDs.compactMap { NSRunningApplication(processIdentifier: $0) }.filter { !$0.isHidden }
        for app in hiddenByUs { app.hide() }
        log.notice("concealed (\(String(describing: reason), privacy: .public)): hid \(self.hiddenByUs.count) apps; still image \(pictured) (Screen Recording allowed: \(WindowSnapshotter.hasPermission))")
    }

    /// - restoreFocus: give the app you were on its focus back (not when you went on to another app meanwhile).
    func reveal(_ reason: Reason, restoreFocus: Bool = true) {
        guard reasons.remove(reason) != nil, reasons.isEmpty else { return }
        snapper.placeAllNow()                                   // new place, while still hidden
        let active = activeAtStart.flatMap { snapper.pid(of: $0) }
        for app in hiddenByUs where app.processIdentifier != active { app.unhide() }
        if let active, let app = hiddenByUs.first(where: { $0.processIdentifier == active }) { app.unhide() }
        if restoreFocus, let id = activeAtStart, let window = snapper.placedWindow(id), let pid = snapper.pid(of: id) {
            AX.raise(window)
            AX.makeFrontmost(pid)
        }
        hiddenByUs = []
        snapper.isSuspended = false
        onSettled?()
        let activePID = restoreFocus ? active : nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))           // the windows are back on screen by now
            guard reasons.isEmpty else { return }
            sidebar.hideSnapshot()
            // Restoring Atrium's window (from the Dock, a minimize) activates Atrium itself, after we handed focus
            // over: give it back to the app, so typing goes where you're looking.
            if let activePID { AX.makeFrontmost(activePID) }
            onSettled?()
        }
        log.notice("revealed (\(String(describing: reason), privacy: .public)); focus restored \(restoreFocus)")
    }
}
