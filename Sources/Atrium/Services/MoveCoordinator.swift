import AppKit
import AtriumCore
import OSLog

private let log = Logger(subsystem: "com.alif.atrium", category: "move")

/// Makes moving/resizing Atrium feel like moving one window:
///  1. a still image of the current app is put inside Atrium (behind the real window, so nothing changes yet);
///  2. the apps with windows in Atrium are hidden, revealing the image, which then moves with Atrium perfectly;
///  3. on release, every window is moved to the new place *while still hidden*, the apps are shown again right there,
///     and the image is removed once they are back.
/// Without the Screen Recording permission there is no image: the area is simply empty during the move.
@MainActor
final class MoveCoordinator {
    private let store: AppStore
    private let snapper: WindowSnapper
    private let sidebar: SidebarController
    private let snapshotter: WindowSnapshotter
    private var hiddenByUs: [NSRunningApplication] = []
    private var activeAtStart: String?
    private var askedForPermission = false
    private(set) var isMoving = false
    /// Called once everything is back in place (Atrium re-slots itself under the app).
    var onSettled: (@MainActor () -> Void)?

    init(store: AppStore, snapper: WindowSnapper, sidebar: SidebarController, snapshotter: WindowSnapshotter) {
        self.store = store
        self.snapper = snapper
        self.sidebar = sidebar
        self.snapshotter = snapshotter
    }

    func began() {
        guard !isMoving, store.isAXTrusted, snapper.hasPlacedWindows else { return }
        isMoving = true
        snapper.isSuspended = true
        activeAtStart = store.activeBundleID
        if !WindowSnapshotter.hasPermission, !askedForPermission {
            askedForPermission = true
            WindowSnapshotter.requestPermission()
        }
        if let id = activeAtStart, let number = snapper.windowNumber(slot: id),
           let image = snapshotter.image(forWindow: number, maxAge: 120) {
            sidebar.showSnapshot(image)
        }
        hiddenByUs = snapper.placedPIDs.compactMap { NSRunningApplication(processIdentifier: $0) }.filter { !$0.isHidden }
        for app in hiddenByUs { app.hide() }
        log.debug("move began: hid \(self.hiddenByUs.count) apps")
    }

    func ended() {
        guard isMoving else { return }
        snapper.placeAllNow()                                   // new place, while still hidden
        let active = activeAtStart.flatMap { snapper.pid(of: $0) }
        for app in hiddenByUs where app.processIdentifier != active { app.unhide() }
        if let active, let app = hiddenByUs.first(where: { $0.processIdentifier == active }) { app.unhide() }
        if let id = activeAtStart, let window = snapper.placedWindow(id), let pid = snapper.pid(of: id) {
            AX.raise(window)
            AX.makeFrontmost(pid)
        }
        hiddenByUs = []
        isMoving = false
        snapper.isSuspended = false
        onSettled?()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))           // the windows are back on screen by now
            if !isMoving { sidebar.hideSnapshot() }
            onSettled?()
        }
        log.debug("move ended")
    }
}
