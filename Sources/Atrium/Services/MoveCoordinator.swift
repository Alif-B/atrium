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
    enum Reason: Hashable { case moving, closed, minimized, appHidden }

    private let store: AppStore
    private let snapper: WindowSnapper
    private let sidebar: SidebarController
    private let snapshotter: WindowSnapshotter
    private var reasons: Set<Reason> = []
    private var hiddenByUs: [NSRunningApplication] = []
    private var activeAtStart: String?

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

    func conceal(_ reason: Reason) {
        let first = reasons.isEmpty
        reasons.insert(reason)
        guard first, store.isAXTrusted, snapper.hasPlacedWindows else { return }
        snapper.isSuspended = true
        activeAtStart = store.activeBundleID
        if let id = activeAtStart, let number = snapper.windowNumber(slot: id),
           let image = snapshotter.image(forWindow: number, maxAge: 120) {
            sidebar.showSnapshot(image)
        }
        hiddenByUs = snapper.placedPIDs.compactMap { NSRunningApplication(processIdentifier: $0) }.filter { !$0.isHidden }
        for app in hiddenByUs { app.hide() }
        log.debug("concealed (\(String(describing: reason), privacy: .public)): hid \(self.hiddenByUs.count) apps")
    }

    func reveal(_ reason: Reason) {
        guard reasons.remove(reason) != nil, reasons.isEmpty else { return }
        snapper.placeAllNow()                                   // new place, while still hidden
        let active = activeAtStart.flatMap { snapper.pid(of: $0) }
        for app in hiddenByUs where app.processIdentifier != active { app.unhide() }
        if let active, let app = hiddenByUs.first(where: { $0.processIdentifier == active }) { app.unhide() }
        if let id = activeAtStart, let window = snapper.placedWindow(id), let pid = snapper.pid(of: id) {
            AX.raise(window)
            AX.makeFrontmost(pid)
        }
        hiddenByUs = []
        snapper.isSuspended = false
        onSettled?()
        let activePID = active
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))           // the windows are back on screen by now
            guard reasons.isEmpty else { return }
            sidebar.hideSnapshot()
            // Restoring Atrium's window (from the Dock, a minimize) activates Atrium itself, after we handed focus
            // over: give it back to the app, so typing goes where you're looking.
            if let activePID { AX.makeFrontmost(activePID) }
            onSettled?()
        }
        log.debug("revealed (\(String(describing: reason), privacy: .public))")
    }
}
