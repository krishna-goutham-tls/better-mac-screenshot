import AppKit

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Dims the frozen frame and lets the user drag a region. Esc or a click with no drag cancels.
private final class SelectionView: NSView {
    var onDone: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private var finished = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let sel = selection {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        guard let sel = selection else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        let scale = window?.backingScaleFactor ?? 2
        let label = "\(Int(sel.width * scale)) × \(Int(sel.height * scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        var origin = NSPoint(x: sel.maxX - size.width - 8, y: sel.minY - size.height - 10)
        if origin.y < 4 { origin.y = sel.minY + 6 }
        let pill = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        label.draw(at: origin, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        current = NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let sel = selection, sel.width >= 4, sel.height >= 4 else { return finish(nil) }
        finish(sel)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) }  // Esc
    }

    override func rightMouseDown(with event: NSEvent) {
        finish(nil)
    }

    private func finish(_ rect: NSRect?) {
        guard !finished else { return }
        finished = true
        onDone?(rect)
    }
}

/// One full-screen window per capture, showing the frozen frame under the dimmed selection layer.
final class SelectionOverlay {
    private let window: NSWindow
    private let view: SelectionView

    /// `onDone` gets the selected region in view points, or nil when the user cancelled.
    init(screen: NSScreen, image: CGImage, onDone: @escaping (NSRect?, NSSize) -> Void) {
        let frame = screen.frame
        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.setFrame(frame, display: false)

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.contents = image
        root.layer?.contentsGravity = .resize

        view = SelectionView(frame: root.bounds)
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        window.contentView = root

        let size = frame.size
        view.onDone = { rect in onDone(rect, size) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        window.invalidateCursorRects(for: view)
        NSCursor.crosshair.set()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
