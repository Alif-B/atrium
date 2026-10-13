import AppKit

/// A brief crossfade when switching apps: the old app's still image is laid over the workspace, the new app comes up
/// underneath, and the image fades away. Floats above everything for those ~0.2 s and ignores the mouse.
final class CrossfadePanel: NSPanel {
    private let imageLayer = CALayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        let view = NSView()
        view.wantsLayer = true
        imageLayer.contentsGravity = .topLeft
        view.layer?.addSublayer(imageLayer)
        contentView = view
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `frame` in Cocoa screen coordinates (the workspace).
    @MainActor
    func play(_ image: CGImage, frame: CGRect, duration: TimeInterval = 0.18) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(frame, display: false)
        imageLayer.frame = CGRect(origin: .zero, size: frame.size)
        imageLayer.contentsScale = screen?.backingScaleFactor ?? 2
        imageLayer.contents = image
        CATransaction.commit()
        alphaValue = 1
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.imageLayer.contents = nil
            }
        }
    }
}
