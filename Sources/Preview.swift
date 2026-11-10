import AppKit

/// Takes the click on the thumbnail and shows a pointing hand over it.
private final class PreviewView: NSImageView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The thumbnail in the bottom-right corner for 4 seconds, longer while the mouse is on it. A click opens
/// the editor. The clipboard and the file are already done when it shows, so it never blocks the next shot.
final class Preview {
    private let panel: NSPanel
    private let imageView = PreviewView()
    private var hideWork: DispatchWorkItem?
    private var screen: NSScreen?
    /// Gets the screen the thumbnail was on.
    var onClick: ((NSScreen) -> Void)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        imageView.onClick = { [weak self] in
            guard let self, let screen = self.screen else { return }
            self.hideWork?.cancel()
            self.panel.orderOut(nil)
            self.onClick?(screen)
        }
        imageView.onHover = { [weak self] inside in
            guard let self else { return }
            if inside {
                self.hideWork?.cancel()
                self.panel.alphaValue = 1
            } else {
                self.scheduleHide(after: 2)
            }
        }
        panel.contentView = imageView
    }

    func show(_ image: CGImage, on screen: NSScreen) {
        let maxW: CGFloat = 220, maxH: CGFloat = 150
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let fit = min(maxW / w, maxH / h, 1)
        let size = NSSize(width: max(40, (w * fit).rounded()), height: max(30, (h * fit).rounded()))
        let area = screen.visibleFrame
        let frame = NSRect(x: area.maxX - size.width - 16, y: area.minY + 16, width: size.width, height: size.height)

        self.screen = screen
        imageView.image = NSImage(cgImage: image, size: size)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        scheduleHide(after: 4)
    }

    func hideNow() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
        })
    }
}
