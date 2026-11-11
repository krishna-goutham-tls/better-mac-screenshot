import AppKit

/// The most recent shot, kept so the editor can render it again: the raw crop, every blur found,
/// which blurs the user turned off, and the file it was saved to.
struct EditableShot {
    let raw: CGImage
    let hits: [Redact.Hit]
    var removed: Set<Int> = []
    let scale: CGFloat
    var background: PostStyle.Background
    /// Nil when the save failed. The editor then only copies.
    let url: URL?

    var activeHits: [Redact.Hit] {
        hits.indices.filter { !removed.contains($0) }.map { hits[$0] }
    }

    /// Where a hit sits in the Post canvas, in canvas pixels with the origin bottom left. Hits are top-left pixels of the shot.
    static func canvasRect(for hit: CGRect, shotWidth: Int, shotHeight: Int, scale: CGFloat) -> CGRect {
        let shot = PostStyle.layout(width: shotWidth, height: shotHeight, scale: scale).shot
        return CGRect(x: shot.minX + hit.minX, y: shot.minY + CGFloat(shotHeight) - hit.maxY, width: hit.width, height: hit.height)
    }
}

/// What the pointer is over.
private enum Target: Equatable {
    case blur(Int)
    case swatch(PostStyle.Background)
}

/// Draws the Post image fitted to the window, the blur areas on hover, and the three background swatches.
private final class EditorView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var canvasSize = CGSize(width: 1, height: 1)
    var scale: CGFloat = 2
    /// Each blur in canvas pixels, bottom-left origin.
    var blurRects: [CGRect] = []
    var removed: Set<Int> = [] { didSet { needsDisplay = true } }
    var background: PostStyle.Background = .dusk { didSet { needsDisplay = true } }
    private var hovered: Target? { didSet { if hovered != oldValue { needsDisplay = true } } }

    var onBlur: ((Int) -> Void)?
    var onSwatch: ((PostStyle.Background) -> Void)?
    var onUndo: (() -> Void)?
    var onClose: (() -> Void)?
    var onEnter: (() -> Void)?

    static let side: CGFloat = 28, top: CGFloat = 40, bottom: CGFloat = 60
    private static let swatchSize: CGFloat = 16, swatchGap: CGFloat = 14

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The Post image in view points. Never drawn larger than its own size on screen.
    var imageRect: NSRect {
        let area = NSRect(x: Self.side, y: Self.bottom, width: bounds.width - 2 * Self.side,
                          height: bounds.height - Self.bottom - Self.top)
        let k = min(area.width / canvasSize.width, area.height / canvasSize.height, 1 / scale)
        let w = canvasSize.width * k, h = canvasSize.height * k
        return NSRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    func viewRect(forBlur i: Int) -> NSRect {
        let ir = imageRect, r = blurRects[i]
        let k = ir.width / canvasSize.width
        return NSRect(x: ir.minX + r.minX * k, y: ir.minY + r.minY * k, width: r.width * k, height: r.height * k)
    }

    private func swatchRect(_ bg: PostStyle.Background) -> NSRect {
        let all = PostStyle.Background.allCases
        let total = CGFloat(all.count) * Self.swatchSize + CGFloat(all.count - 1) * Self.swatchGap
        let i = CGFloat(all.firstIndex(of: bg) ?? 0)
        return NSRect(x: (bounds.midX - total / 2 + i * (Self.swatchSize + Self.swatchGap)).rounded(),
                      y: ((Self.bottom - Self.swatchSize) / 2).rounded(), width: Self.swatchSize, height: Self.swatchSize)
    }

    private func target(at p: NSPoint) -> Target? {
        for bg in PostStyle.Background.allCases where swatchRect(bg).insetBy(dx: -5, dy: -5).contains(p) { return .swatch(bg) }
        // Neighbouring lines can overlap; the smallest area under the pointer wins.
        let under = blurRects.indices.filter { viewRect(forBlur: $0).contains(p) }
        return under.min { blurRects[$0].width * blurRects[$0].height < blurRects[$1].width * blurRects[$1].height }.map(Target.blur)
    }

    /// Lets the editor test show a hover without a mouse.
    func setHover(_ i: Int) { hovered = .blur(i) }

    /// Demo mode: sets or clears the hover without a mouse.
    func demoHover(blur: Int?, swatch: PostStyle.Background?) {
        hovered = blur.map(Target.blur) ?? swatch.map(Target.swatch)
    }

    /// Demo mode: where a swatch sits, in view points.
    func demoSwatchRect(_ bg: PostStyle.Background) -> NSRect { swatchRect(bg) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func updateHover(_ event: NSEvent) {
        hovered = target(at: convert(event.locationInWindow, from: nil))
        (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func cursorUpdate(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        switch target(at: convert(event.locationInWindow, from: nil)) {
        case .blur(let i): onBlur?(i)
        case .swatch(let bg): onSwatch?(bg)
        case nil: break
        }
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, cmd) {
        case (53, _): onClose?()                   // Esc
        case (36, false), (76, false): onEnter?()  // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    /// The app has no main menu, so Cmd+Z and Cmd+W are caught here before they beep.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.keyCode {
        case 6: onUndo?(); return true   // Z
        case 13: onClose?(); return true // W
        default: return false
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ir = imageRect
        if let image {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.addPath(CGPath(roundedRect: ir, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: ir, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(image, in: ir)
            ctx.restoreGState()
        }

        for i in blurRects.indices {
            let isHovered = hovered == .blur(i)
            let isRemoved = removed.contains(i)
            guard isHovered || isRemoved else { continue }
            let r = viewRect(forBlur: i).insetBy(dx: -1.5, dy: -1.5)
            let path = NSBezierPath(roundedRect: r, xRadius: min(6, r.height / 3), yRadius: min(6, r.height / 3))
            path.lineWidth = 1.5
            if isRemoved {
                // A removed blur keeps a faint dashed outline, so it can be found and put back.
                path.setLineDash([4, 3], count: 2, phase: 0)
            } else {
                NSColor.white.withAlphaComponent(0.08).setFill()
                path.fill()
            }
            let faint = isRemoved && !isHovered
            // A dark halo under the line, so it shows on light shots too.
            let halo = path.copy() as! NSBezierPath
            halo.lineWidth = 3.5
            NSColor.black.withAlphaComponent(faint ? 0.15 : 0.35).setStroke()
            halo.stroke()
            NSColor.white.withAlphaComponent(faint ? 0.35 : 0.85).setStroke()
            path.stroke()
        }

        for bg in PostStyle.Background.allCases {
            let r = swatchRect(bg)
            let circle = NSBezierPath(ovalIn: r)
            Self.swatchGradient(bg).draw(in: circle, angle: -45)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if bg == background || hovered == .swatch(bg) {
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -4, dy: -4))
                ring.lineWidth = 1.5
                NSColor.white.withAlphaComponent(bg == background ? 0.85 : 0.35).setStroke()
                ring.stroke()
            }
        }
    }

    private static func swatchGradient(_ bg: PostStyle.Background) -> NSGradient {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        switch bg {
        case .sand: return NSGradient(colors: [c(0.965, 0.945, 0.910), c(0.915, 0.880, 0.825)])!
        case .night: return NSGradient(colors: [c(0.13, 0.16, 0.27), c(0.06, 0.08, 0.15)])!
        case .dusk: return NSGradient(colors: [c(0.780, 0.815, 0.930), c(0.880, 0.860, 0.925), c(0.975, 0.865, 0.800)])!
        }
    }
}

/// One window for the last shot. A click on a blur removes it, a second click puts it back, Cmd+Z undoes.
/// The swatches switch the Post background. Every change renders at once, replaces the clipboard and
/// overwrites the same file. Esc or Cmd+W closes, Enter copies again and closes.
final class Editor: NSObject, NSWindowDelegate {
    private enum Change {
        case blur(Int)
        /// Holds the background before the change.
        case background(PostStyle.Background)
    }

    private let window: NSWindow
    private let view = EditorView()
    private let copied = NSTextField(labelWithString: "Copied")
    private var shot: EditableShot
    private var png: Data
    /// Renders run on the app's output queue, after any shot still being saved.
    private let queue: DispatchQueue
    private var undo: [Change] = []
    private var requested = 0
    private var rendered = 0
    private var restoresFocus = true
    private var copiedWork: DispatchWorkItem?
    private(set) var previousApp: NSRunningApplication?
    /// Off only in the editor test, so it leaves the clipboard alone.
    var copies = true
    var onClose: (() -> Void)?

    init(shot: EditableShot, image: CGImage, png: Data, queue: DispatchQueue, screen: NSScreen) {
        self.shot = shot
        self.png = png
        self.queue = queue

        let points = CGSize(width: CGFloat(image.width) / shot.scale, height: CGFloat(image.height) / shot.scale)
        let area = screen.visibleFrame
        let maxW = area.width * 0.8, maxH = area.height * 0.8
        let chromeW = 2 * EditorView.side, chromeH = EditorView.top + EditorView.bottom
        let fit = min(1, (maxW - chromeW) / points.width, (maxH - chromeH) / points.height)
        let size = NSSize(width: max(440, (points.width * fit + chromeW).rounded()),
                          height: max(300, (points.height * fit + chromeH).rounded()))
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)

        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Screenshot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.085, green: 0.088, blue: 0.098, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 300)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init()
        window.delegate = self

        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        view.image = image
        view.canvasSize = CGSize(width: image.width, height: image.height)
        view.scale = shot.scale
        view.blurRects = shot.hits.map {
            EditableShot.canvasRect(for: $0.rect, shotWidth: shot.raw.width, shotHeight: shot.raw.height, scale: shot.scale)
        }
        view.removed = shot.removed
        view.background = shot.background
        view.onBlur = { [weak self] i in self?.toggle(i) }
        view.onSwatch = { [weak self] bg in self?.setBackground(bg) }
        view.onUndo = { [weak self] in self?.undoLast() }
        view.onClose = { [weak self] in self?.close() }
        view.onEnter = { [weak self] in self?.copyAndClose() }

        copied.font = .systemFont(ofSize: 12, weight: .medium)
        copied.textColor = NSColor.white.withAlphaComponent(0.6)
        copied.alphaValue = 0
        copied.sizeToFit()
        copied.frame.origin = NSPoint(x: frame.width - EditorView.side - copied.frame.width,
                                      y: ((EditorView.bottom - copied.frame.height) / 2).rounded())
        copied.autoresizingMask = [.minXMargin]
        view.addSubview(copied)
        window.contentView = view
    }

    /// Brings the app forward. `fallback` is the app to return to when this app is already in front.
    func show(returningTo fallback: NSRunningApplication? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? fallback : front
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// `restoreFocus` is false when a new shot replaces this one.
    func close(restoreFocus: Bool = true) {
        restoresFocus = restoreFocus
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if restoresFocus { previousApp?.activate() }
        onClose?()
    }

    func toggle(_ i: Int) {
        guard shot.hits.indices.contains(i) else { return }
        flip(i)
        undo.append(.blur(i))
        render()
    }

    func setBackground(_ bg: PostStyle.Background) {
        guard bg != shot.background else { return }
        undo.append(.background(shot.background))
        shot.background = bg
        view.background = bg
        PostStyle.savedBackground = bg
        render()
    }

    /// Lets the editor test show a hover without a mouse.
    func hover(_ i: Int) {
        guard shot.hits.indices.contains(i) else { return }
        view.setHover(i)
    }

    private func flip(_ i: Int) {
        if shot.removed.contains(i) { shot.removed.remove(i) } else { shot.removed.insert(i) }
        view.removed = shot.removed
    }

    private func undoLast() {
        guard let change = undo.popLast() else { return NSSound.beep() }
        switch change {
        case .blur(let i):
            flip(i)
        case .background(let bg):
            shot.background = bg
            view.background = bg
            PostStyle.savedBackground = bg
        }
        render()
    }

    private func copyAndClose() {
        // A render still running copies its own result when it lands.
        if copies, rendered == requested { Output.copy(png) }
        close()
    }

    private func render() {
        requested += 1
        let id = requested, s = shot, copies = copies
        queue.async { [weak self] in
            let t0 = Date()
            guard let done = Output.finish(s.raw, hits: s.activeHits, scale: s.scale, background: s.background) else {
                return Log.write("editor render failed, clipboard and file unchanged")
            }
            // The clipboard and file update even when the window has closed in the meantime.
            if copies { DispatchQueue.main.sync { _ = Output.copy(done.png) } }
            if let url = s.url {
                do { try done.png.write(to: url, options: .atomic) } catch { Log.write("editor save failed: \(error.localizedDescription)") }
            }
            Log.write("editor render \(s.activeHits.count)/\(s.hits.count) blurs, \(s.background.rawValue)\(done.stages.covered ? ", blur failed, covered" : ""): blur \(done.stages.blur), post \(done.stages.post), png \(done.stages.png), total \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            DispatchQueue.main.async {
                guard let self, id == self.requested else { return }
                self.rendered = id
                self.png = done.png
                self.view.image = done.image
                self.flashCopied()
            }
        }
    }

    private func flashCopied() {
        copiedWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            copied.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                self?.copied.animator().alphaValue = 0
            }
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

// MARK: - Demo mode

extension Editor {
    /// Demo mode: the editor's content at `size` points, drawn at 2x with the given state. The window is never shown.
    /// Rects come back in view points, origin bottom left.
    func demoSnapshot(size: NSSize, image: CGImage, removed: Set<Int>, background: PostStyle.Background,
                      hoverBlur: Int?, hoverSwatch: PostStyle.Background?, copiedAlpha: CGFloat) -> CGImage? {
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.image = image
        view.removed = removed
        view.background = background
        view.demoHover(blur: hoverBlur, swatch: hoverSwatch)
        copied.alphaValue = copiedAlpha
        copied.frame.origin = NSPoint(x: size.width - EditorView.side - copied.frame.width,
                                      y: ((EditorView.bottom - copied.frame.height) / 2).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    func demoBlurRect(_ i: Int) -> NSRect { view.viewRect(forBlur: i) }
    func demoSwatchRect(_ bg: PostStyle.Background) -> NSRect { view.demoSwatchRect(bg) }
}
