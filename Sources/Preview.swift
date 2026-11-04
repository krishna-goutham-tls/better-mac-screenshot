import AppKit

/// The thumbnail in the bottom-right corner for 4 seconds. Clicks pass through it, and the
/// clipboard and the file are already done when it shows, so it never blocks the next shot.
final class Preview {
    private let panel: NSPanel
    private let imageView = NSImageView()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        panel.contentView = imageView
    }

    func show(_ image: CGImage, on screen: NSScreen) {
        let maxW: CGFloat = 220, maxH: CGFloat = 150
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let fit = min(maxW / w, maxH / h, 1)
        let size = NSSize(width: max(40, (w * fit).rounded()), height: max(30, (h * fit).rounded()))
        let area = screen.visibleFrame
        let frame = NSRect(x: area.maxX - size.width - 16, y: area.minY + 16, width: size.width, height: size.height)

        imageView.image = NSImage(cgImage: image, size: size)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
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
