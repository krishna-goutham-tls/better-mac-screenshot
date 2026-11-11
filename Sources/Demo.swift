import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Demo mode: `ScreenshotTool --demo <dir>` draws the clips for the tools page, frame by frame, as PNGs.
/// The screen is a drawn desktop with made-up values, so no real file or secret can show. Every blur, Post
/// image and editor view in a clip comes from the app's own code: Redact.detect, Output.finish and the
/// editor's view. Only the cursor, the key chips and the camera are drawn for the video.
/// `scripts/demo.sh` builds, runs this and encodes the MP4s.
@MainActor
enum Demo {
    nonisolated static let screen = CGSize(width: 1440, height: 900)
    nonisolated static let scale: CGFloat = 2
    nonisolated static let fps = 30.0
    nonisolated static let video = CGSize(width: 1600, height: 1000)

    static func run(dir: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        guard let scene = Scene() else { print("scene failed"); return 1 }
        print("shot \(scene.shot.width)x\(scene.shot.height), \(scene.hits.count) blurs: " +
              scene.hits.map { "\($0.kind.rawValue) \(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))" }.joined(separator: "; "))
        save(scene.desktop, to: root.appendingPathComponent("stills/desktop.png"))
        save(scene.shot, to: root.appendingPathComponent("stills/shot-raw.png"))
        save(scene.post, to: root.appendingPathComponent("stills/shot-post.png"))
        let only = CommandLine.arguments.firstIndex(of: "--clip").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        let clips: [(String, Clip)] = [
            ("capture", CaptureClip(scene)),
            ("blur", BlurClip(scene)),
            ("unblur", EditorClip(scene, kind: .unblur)),
            ("backgrounds", EditorClip(scene, kind: .backgrounds)),
        ]
        for (name, clip) in clips where only == nil || only == name {
            let out = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let frames = Int((clip.duration * fps).rounded())
            let t0 = Date()
            for f in 0..<frames {
                guard let image = clip.frame(Double(f) / fps) else { print("\(name) frame \(f) failed"); return 1 }
                save(image, to: out.appendingPathComponent(String(format: "f%04d.png", f)))
            }
            print("\(name): \(frames) frames \(clip.size.width)x\(clip.size.height) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        }
        return 0
    }

    static func save(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: - Timing

private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
private func ease(_ x: Double) -> Double { let t = clamp(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
/// 0 before `a`, 1 after `b`, eased between.
private func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }
/// Fades in over `f` seconds at `a`, out over `f` seconds before `b`.
private func window(_ t: Double, _ a: Double, _ b: Double, fade f: Double = 0.15) -> Double {
    min(clamp((t - a) / f), clamp((b - t) / f))
}
private func mix(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }
private func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, k), y: mix(a.y, b.y, k)) }
private func mix(_ a: CGRect, _ b: CGRect, _ k: Double) -> CGRect {
    CGRect(x: mix(a.minX, b.minX, k), y: mix(a.minY, b.minY, k), width: mix(a.width, b.width, k), height: mix(a.height, b.height, k))
}

/// Keyframed value: holds between keys, eases from one key to the next.
private struct Track<V> {
    let keys: [(t: Double, v: V)]
    let lerp: (V, V, Double) -> V
    func at(_ t: Double) -> V {
        guard var prev = keys.first else { fatalError("empty track") }
        for key in keys {
            if t < key.t {
                // A key is the end of a move that starts at the previous key's hold point.
                return lerp(prev.v, key.v, ease((t - prev.t) / max(key.t - prev.t, 0.0001)))
            }
            prev = key
        }
        return prev.v
    }
}

/// A move is a pair of keys: hold until `from`, arrive at `to`.
private func moves<V>(_ start: V, _ steps: [(from: Double, to: Double, v: V)], lerp: @escaping (V, V, Double) -> V) -> Track<V> {
    var keys: [(t: Double, v: V)] = [(0, start)]
    var last = start
    for s in steps {
        keys.append((s.from, last))
        keys.append((s.to, s.v))
        last = s.v
    }
    return Track(keys: keys, lerp: lerp)
}

/// Camera rect in screen points, widened to the video's aspect around its centre.
private func fit(_ r: CGRect, aspect: CGFloat) -> CGRect {
    var w = r.width, h = r.height
    if w / h > aspect { h = w / aspect } else { w = h * aspect }
    var x = r.midX - w / 2, y = r.midY - h / 2
    // Keep the camera on the drawn screen.
    if w <= Demo.screen.width { x = min(max(x, 0), Demo.screen.width - w) }
    if h <= Demo.screen.height { y = min(max(y, 0), Demo.screen.height - h) }
    return CGRect(x: x, y: y, width: w, height: h)
}

// MARK: - Drawing helpers

/// A context with top-left origin in points, `px` pixels per point.
private func context(_ size: CGSize, px: CGFloat) -> CGContext? {
    guard let ctx = CGContext(data: nil, width: Int(size.width * px), height: Int(size.height * px), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.translateBy(x: 0, y: size.height * px)
    ctx.scaleBy(x: px, y: -px)
    ctx.interpolationQuality = .high
    return ctx
}

/// Runs AppKit drawing (text, NSImage) in a top-left context.
private func appKit(_ ctx: CGContext, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

private func draw(_ image: CGImage, in rect: CGRect, _ ctx: CGContext, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

private func text(_ s: String, _ p: CGPoint, font: NSFont, color: NSColor) {
    (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

private func roundRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A window body with a soft shadow and a hairline, like a macOS window.
private func windowShape(_ ctx: CGContext, _ r: CGRect, fill: NSColor, radius: CGFloat = 12) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 50, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(roundRect(r, radius))
    ctx.setFillColor(fill.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundRect(r.insetBy(dx: 0.5, dy: 0.5), radius))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(1)
    ctx.strokePath()
}

private func trafficLights(_ ctx: CGContext, at p: CGPoint, only close: Bool = false) {
    let colors: [UInt32] = [0xff5f57, 0xfebc2e, 0x28c840]
    for (i, c) in colors.enumerated() where !close || i == 0 {
        ctx.setFillColor(rgb(c).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x + CGFloat(i) * 20 - 6, y: p.y - 6, width: 12, height: 12))
    }
}

/// The system cursor image, scaled up a little so it reads in a small video.
private func cursor(_ kind: NSCursor, at p: CGPoint, _ ctx: CGContext, alpha: CGFloat = 1, size k: CGFloat = 1.35) {
    let img = kind.image
    let hs = kind.hotSpot
    let r = CGRect(x: p.x - hs.x * k, y: p.y - hs.y * k, width: img.size.width * k, height: img.size.height * k)
    appKit(ctx) { img.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil) }
}

/// A key chip at the bottom of the video, in video points: "⌘ ⇧ 2".
private func keyChip(_ keys: [String], alpha: CGFloat, in video: CGSize, _ ctx: CGContext) {
    guard alpha > 0.001 else { return }
    let font = NSFont.systemFont(ofSize: 30, weight: .semibold)
    let cap: CGFloat = 58, gap: CGFloat = 10, pad: CGFloat = 14
    let w = CGFloat(keys.count) * cap + CGFloat(keys.count - 1) * gap + 2 * pad
    let box = CGRect(x: (video.width - w) / 2, y: video.height - 128 + (1 - alpha) * 12, width: w, height: cap + 2 * pad)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(roundRect(box, 20))
    ctx.setFillColor(rgb(0x14161c, 0.92).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    for (i, k) in keys.enumerated() {
        let r = CGRect(x: box.minX + pad + CGFloat(i) * (cap + gap), y: box.minY + pad, width: cap, height: cap)
        ctx.addPath(roundRect(r, 12))
        ctx.setFillColor(rgb(0x2a2d36).cgColor)
        ctx.fillPath()
        ctx.addPath(roundRect(r.insetBy(dx: 0.5, dy: 0.5), 12))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.strokePath()
        let size = (k as NSString).size(withAttributes: [.font: font])
        appKit(ctx) { text(k, CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), font: font, color: rgb(0xf4ede0)) }
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: - The scene

/// The drawn desktop, the shot taken from it, and the app's own output for that shot.
@MainActor
private final class Scene {
    let desktop: CGImage          // 2x pixels of the whole screen
    let terminal: CGRect          // window frame, points
    let notes: CGRect
    let selection: CGRect         // the region the demo drags, points
    let shot: CGImage             // the crop, 2x pixels
    let hits: [Redact.Hit]        // from Redact.detect
    let post: CGImage             // from Output.finish, dusk
    let editor: Editor

    private static let mono = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private static let lineH: CGFloat = 25

    /// Made-up secrets, built from pieces at run time so the source never holds a full key.
    private static func fake(_ n: Int, seed: UInt64) -> String {
        let set = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz0123456789")
        var x = seed
        return String((0..<n).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return set[Int(x % UInt64(set.count))]
        })
    }

    init?() {
        let terminal = CGRect(x: 96, y: 104, width: 860, height: 520)
        let notes = CGRect(x: 1000, y: 168, width: 380, height: 600)
        self.terminal = terminal
        self.notes = notes
        let ink = rgb(0xe8e6e1), dim = rgb(0x8a8f99), green = rgb(0x7fd18b), cyan = rgb(0x7cc7e8), orange = rgb(0xf5a04a), pink = rgb(0xd99be8)
        let openai = "sk-" + "proj-" + Self.fake(40, seed: 0x5eed1)
        let stripe = "sk_" + "live_" + Self.fake(30, seed: 0x5eed2)
        let lines: [[(String, NSColor)]] = [
            [("~/code/acme-api", cyan), (" on ", dim), ("main", pink)],
            [("❯ ", green), ("cat .env.production", ink)],
            [("NODE_ENV", orange), ("=production", ink)],
            [("REGION", orange), ("=us-east-1", ink)],
            [("OPENAI_API_KEY", orange), ("=" + openai, ink)],
            [("STRIPE_SECRET_KEY", orange), ("=" + stripe, ink)],
            [("SUPPORT_EMAIL", orange), ("=maya.chen@example.com", ink)],
            [("ONCALL_PHONE", orange), ("=+1 415 555 0134", ink)],
            [],
            [("❯ ", green), ("npm run deploy", ink)],
            [("✓ ", green), ("built in 4.21s", ink)],
            [("✓ ", green), ("deployed to production", ink)],
            [("❯ ", green)],
        ]
        let bodyTop = terminal.minY + 34 + 20
        let left = terminal.minX + 22
        let selTop = bodyTop - 14
        let selBottom = bodyTop + Self.lineH * 12 + 2
        selection = CGRect(x: terminal.minX + 8, y: selTop, width: 700, height: selBottom - selTop).integral

        guard let ctx = context(Demo.screen, px: Demo.scale) else { return nil }
        let full = CGRect(origin: .zero, size: Demo.screen)

        // Wallpaper: deep ink to a warm brass glow, no image assets.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let wash = CGGradient(colorsSpace: space, colors: [rgb(0x18202f).cgColor, rgb(0x2b3043).cgColor, rgb(0x6b5438).cgColor] as CFArray,
                              locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(wash, start: .zero, end: CGPoint(x: full.maxX, y: full.maxY), options: [])
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0xf5a04a, 0.22).cgColor, rgb(0xf5a04a, 0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 1250, y: 820), startRadius: 0, endCenter: CGPoint(x: 1250, y: 820),
                               endRadius: 700, options: [])

        // Menu bar.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: full.width, height: 26))
        appKit(ctx) {
            let bold = NSFont.systemFont(ofSize: 13, weight: .bold), reg = NSFont.systemFont(ofSize: 13, weight: .regular)
            let white = NSColor.white.withAlphaComponent(0.92)
            text("Terminal", CGPoint(x: 20, y: 4), font: bold, color: white)
            var x: CGFloat = 96
            for item in ["Shell", "Edit", "View", "Window", "Help"] {
                text(item, CGPoint(x: x, y: 4), font: reg, color: white)
                x += (item as NSString).size(withAttributes: [.font: reg]).width + 20
            }
            text("Wed 11 Nov  9:41", CGPoint(x: full.width - 128, y: 4), font: reg, color: white)
            let icon = menuBarIcon()
            let tinted = NSImage(size: icon.size, flipped: false) { r in
                icon.draw(in: r)
                NSColor.white.withAlphaComponent(0.92).set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(x: full.width - 162, y: 4, width: 18, height: 18), from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
        }

        // Notes window, where the shot gets pasted.
        windowShape(ctx, notes, fill: rgb(0xfbf9f5))
        trafficLights(ctx, at: CGPoint(x: notes.minX + 20, y: notes.minY + 18))
        appKit(ctx) {
            text("Launch notes", CGPoint(x: notes.minX + 24, y: notes.minY + 52), font: .systemFont(ofSize: 22, weight: .bold), color: rgb(0x1d1f24))
            text("Deploy went out at 9:40.", CGPoint(x: notes.minX + 24, y: notes.minY + 90), font: .systemFont(ofSize: 15), color: rgb(0x3b3f47))
            text("Env and output below.", CGPoint(x: notes.minX + 24, y: notes.minY + 112), font: .systemFont(ofSize: 15), color: rgb(0x3b3f47))
        }

        // Terminal.
        windowShape(ctx, terminal, fill: rgb(0x15171c))
        trafficLights(ctx, at: CGPoint(x: terminal.minX + 20, y: terminal.minY + 17))
        appKit(ctx) {
            let title = "acme-api — zsh"
            let f = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let w = (title as NSString).size(withAttributes: [.font: f]).width
            text(title, CGPoint(x: terminal.midX - w / 2, y: terminal.minY + 9), font: f, color: rgb(0x9a9ea8))
            for (i, pieces) in lines.enumerated() {
                var x = left
                let y = bodyTop + CGFloat(i) * Self.lineH
                for (s, c) in pieces {
                    text(s, CGPoint(x: x, y: y), font: Self.mono, color: c)
                    x += (s as NSString).size(withAttributes: [.font: Self.mono]).width
                }
                if i == lines.count - 1 {
                    NSColor.white.withAlphaComponent(0.8).setFill()
                    CGRect(x: x + 2, y: y + 2, width: 9, height: 18).fill()
                }
            }
        }
        guard let desktop = ctx.makeImage() else { return nil }
        self.desktop = desktop

        // The shot: the same crop the app makes from a frozen frame.
        let crop = CGRect(x: selection.minX * Demo.scale, y: selection.minY * Demo.scale,
                          width: selection.width * Demo.scale, height: selection.height * Demo.scale)
        guard let shot = desktop.cropping(to: crop) else { return nil }
        self.shot = shot
        hits = Redact.detect(in: shot)
        guard let done = Output.finish(shot, hits: hits, scale: Demo.scale, background: .dusk) else { return nil }
        post = done.image
        guard let screen = NSScreen.main else { return nil }
        editor = Editor(shot: EditableShot(raw: shot, hits: hits, scale: Demo.scale, background: .dusk, url: nil),
                        image: done.image, png: done.png, queue: DispatchQueue(label: "demo"), screen: screen)
        editor.copies = false
    }

    private var cache: [String: CGImage] = [:]
    /// The Post image for a set of removed blurs and a background, from Output.finish. Cached.
    func post(removed: Set<Int>, background: PostStyle.Background) -> CGImage {
        let key = "\(removed.sorted())-\(background.rawValue)"
        if let hit = cache[key] { return hit }
        let active = hits.indices.filter { !removed.contains($0) }.map { hits[$0] }
        let image = Output.finish(shot, hits: active, scale: Demo.scale, background: background)!.image
        cache[key] = image
        return image
    }
}

// MARK: - Clips

@MainActor
private protocol Clip {
    var duration: Double { get }
    var size: CGSize { get }
    func frame(_ t: Double) -> CGImage?
}

/// Cmd+Shift+2, drag a region, the thumbnail shows, Cmd+V puts the finished shot in a note.
@MainActor
private final class CaptureClip: Clip {
    let duration = 8.0
    let size = Demo.video
    private let s: Scene
    private let cam: Track<CGRect>
    private let pointer: Track<CGPoint>
    private var first: CGImage?

    init(_ s: Scene) {
        self.s = s
        let aspect = Demo.video.width / Demo.video.height
        let full = fit(CGRect(x: 40, y: 0, width: 1360, height: 900), aspect: aspect)
        let region = fit(s.selection.insetBy(dx: -70, dy: -60), aspect: aspect)
        let note = fit(s.notes.insetBy(dx: -40, dy: -20), aspect: aspect)
        cam = moves(full, [(0.7, 1.6, region), (3.0, 3.7, full), (4.9, 5.8, note)], lerp: mix)
        let sel = s.selection
        pointer = moves(CGPoint(x: 760, y: 700), [
            (0.2, 1.5, CGPoint(x: sel.minX, y: sel.minY)),
            (1.65, 2.75, CGPoint(x: sel.maxX, y: sel.maxY)),
            (3.6, 4.4, CGPoint(x: s.notes.minX + 120, y: s.notes.minY + 150)),
        ], lerp: mix)
    }

    func frame(_ t: Double) -> CGImage? {
        guard let ctx = context(size, px: 1) else { return nil }
        let c = cam.at(t)
        let k = size.width / c.width
        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -c.minX, y: -c.minY)
        draw(s.desktop, in: CGRect(origin: .zero, size: Demo.screen), ctx)

        // The pasted shot in the note.
        let pasted = ramp(t, 4.85, 5.05)
        if pasted > 0 {
            let w = s.notes.width - 48
            let h = w * CGFloat(s.post.height) / CGFloat(s.post.width)
            let r = CGRect(x: s.notes.minX + 24, y: s.notes.minY + 148, width: w, height: h)
            ctx.saveGState()
            ctx.addPath(roundRect(r, 6))
            ctx.clip()
            draw(s.post, in: r, ctx, alpha: CGFloat(pasted))
            ctx.restoreGState()
        }

        let p = pointer.at(t)
        let selecting = t >= 0.9 && t < 2.9
        if selecting {
            // The app's selection layer: 35% black, the region clear, a white edge and the size pill.
            let start = CGPoint(x: s.selection.minX, y: s.selection.minY)
            let dragging = t >= 1.65
            let sel = dragging ? CGRect(x: start.x, y: start.y, width: p.x - start.x, height: p.y - start.y) : nil
            let dim = CGMutablePath()
            dim.addRect(CGRect(origin: .zero, size: Demo.screen))
            if let sel { dim.addRect(sel) }
            ctx.addPath(dim)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.fillPath(using: .evenOdd)
            if let sel, sel.width > 2, sel.height > 2 {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
                let label = "\(Int(sel.width * Demo.scale)) × \(Int(sel.height * Demo.scale))"
                let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                let ls = (label as NSString).size(withAttributes: [.font: f])
                let o = CGPoint(x: sel.maxX - ls.width - 8, y: sel.maxY + 10)
                ctx.addPath(roundRect(CGRect(x: o.x - 6, y: o.y - 3, width: ls.width + 12, height: ls.height + 6), 5))
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
                ctx.fillPath()
                appKit(ctx) { text(label, o, font: f, color: .white) }
            }
        }

        // The corner thumbnail, 4 seconds, then a 0.25 s fade, as in Preview.
        let thumb = window(t, 2.95, 7.2, fade: 0.05) * (t > 6.95 ? 1 - clamp((t - 6.95) / 0.25) : 1)
        if thumb > 0 {
            let fitK = min(220 / (CGFloat(s.post.width) / Demo.scale), 150 / (CGFloat(s.post.height) / Demo.scale), 1)
            let w = (CGFloat(s.post.width) / Demo.scale * fitK).rounded(), h = (CGFloat(s.post.height) / Demo.scale * fitK).rounded()
            let r = CGRect(x: Demo.screen.width - w - 16, y: Demo.screen.height - h - 16, width: w, height: h)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(thumb))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 24, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.addPath(roundRect(r, 8))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.saveGState()
            ctx.addPath(roundRect(r, 8))
            ctx.clip()
            draw(s.post, in: r, ctx)
            ctx.restoreGState()
            ctx.addPath(roundRect(r.insetBy(dx: 0.5, dy: 0.5), 8))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        // Shutter flash.
        let flash = t >= 2.9 ? 1 - clamp((t - 2.9) / 0.3) : 0
        if flash > 0 {
            ctx.setFillColor(NSColor.white.withAlphaComponent(CGFloat(flash) * 0.45).cgColor)
            ctx.fill(CGRect(origin: .zero, size: Demo.screen))
        }

        cursor(selecting ? .crosshair : .arrow, at: p, ctx)
        ctx.restoreGState()

        keyChip(["⌘", "⇧", "2"], alpha: CGFloat(window(t, 0.45, 1.5)), in: size, ctx)
        keyChip(["⌘", "V"], alpha: CGFloat(window(t, 4.55, 5.4)), in: size, ctx)
        return loop(ctx, t)
    }

    /// The last 0.4 s fade into the first frame, so the clip loops without a jump.
    private func loop(_ ctx: CGContext, _ t: Double) -> CGImage? {
        if t == 0 { first = ctx.makeImage(); return first }
        let k = ramp(t, duration - 0.45, duration - 0.05)
        if k > 0, let first { draw(first, in: CGRect(origin: .zero, size: size), ctx, alpha: CGFloat(k)) }
        return ctx.makeImage()
    }
}

/// The shot as it was on screen, then the blur landing on each secret, as Redact found them.
@MainActor
private final class BlurClip: Clip {
    let duration = 5.4
    let size: CGSize
    private let s: Scene
    private let raw: CGImage
    private let shotRect: CGRect     // the shot inside the Post canvas, canvas pixels, top-left origin
    private let hitRects: [CGRect]   // canvas pixels, top-left origin

    init(_ s: Scene) {
        self.s = s
        raw = PostStyle.render(s.shot, scale: Demo.scale, background: .dusk)!
        let canvas = CGSize(width: raw.width, height: raw.height)
        let k = 1600 / canvas.width
        size = CGSize(width: 1600, height: (canvas.height * k / 2).rounded() * 2)
        let layout = PostStyle.layout(width: s.shot.width, height: s.shot.height, scale: Demo.scale)
        let shotRect = CGRect(x: layout.shot.minX, y: canvas.height - layout.shot.maxY, width: layout.shot.width, height: layout.shot.height)
        self.shotRect = shotRect
        hitRects = s.hits.map { $0.rect.offsetBy(dx: shotRect.minX, dy: shotRect.minY) }
    }

    func frame(_ t: Double) -> CGImage? {
        guard let ctx = context(size, px: 1) else { return nil }
        let canvas = CGSize(width: raw.width, height: raw.height)
        let zoom = 1 + 0.035 * CGFloat(ramp(t, 0, duration))
        let k = size.width / canvas.width * zoom
        ctx.saveGState()
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -canvas.width / 2, y: -canvas.height / 2)
        let all = CGRect(origin: .zero, size: canvas)
        draw(raw, in: all, ctx)

        // A scan line runs down the shot; each blur fades in as the line passes it.
        let a = 0.55, b = 2.35
        let lineY = shotRect.minY + shotRect.height * CGFloat(ramp(t, a, b))
        let back = ramp(t, duration - 0.5, duration - 0.1)
        for r in hitRects {
            let at = a + (b - a) * Double((r.midY - shotRect.minY) / shotRect.height)
            let on = clamp((t - at) / 0.22) * (1 - back)
            guard on > 0 else { continue }
            ctx.saveGState()
            ctx.clip(to: r.insetBy(dx: -2, dy: -2))
            draw(s.post, in: all, ctx, alpha: CGFloat(on))
            ctx.restoreGState()
        }
        let scan = window(t, a, b, fade: 0.12)
        if scan > 0 {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let band = CGGradient(colorsSpace: space, colors: [rgb(0xf5a04a, 0).cgColor, rgb(0xf5a04a, 0.22).cgColor] as CFArray, locations: [0, 1])!
            ctx.saveGState()
            ctx.setAlpha(CGFloat(scan))
            ctx.addPath(roundRect(shotRect, 20))
            ctx.clip()
            ctx.drawLinearGradient(band, start: CGPoint(x: 0, y: lineY - 90), end: CGPoint(x: 0, y: lineY), options: [])
            ctx.setFillColor(rgb(0xf8b56a, 0.95).cgColor)
            ctx.fill(CGRect(x: shotRect.minX, y: lineY - 2, width: shotRect.width, height: 4))
            ctx.restoreGState()
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// The editor over the desktop: a click removes the email blur and puts it back, or the swatches switch the background.
@MainActor
private final class EditorClip: Clip {
    enum Kind { case unblur, backgrounds }
    let duration: Double
    let size = Demo.video
    private let s: Scene
    private let kind: Kind
    private let win: CGRect          // editor window, screen points
    private let cam: Track<CGRect>
    private let pointer: Track<CGPoint>
    private let email: Int
    private var clicks: [(t: Double, act: (inout Set<Int>, inout PostStyle.Background) -> Void)] = []

    init(_ s: Scene, kind: Kind) {
        self.s = s
        self.kind = kind
        // The editor's own sizing, on this drawn screen's visible area.
        let pts = CGSize(width: CGFloat(s.post.width) / Demo.scale, height: CGFloat(s.post.height) / Demo.scale)
        let area = CGRect(x: 0, y: 26, width: Demo.screen.width, height: Demo.screen.height - 26)
        let fitK = min(1, (area.width * 0.8 - 56) / pts.width, (area.height * 0.8 - 100) / pts.height)
        let w = max(440, (pts.width * fitK + 56).rounded()), h = max(300, (pts.height * fitK + 100).rounded())
        let win = CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
        self.win = win
        let wide = fit(win.insetBy(dx: -36, dy: -30), aspect: Demo.video.width / Demo.video.height)
        let email = s.hits.firstIndex { $0.kind == .email } ?? 0
        self.email = email

        _ = s.editor.demoSnapshot(size: win.size, image: s.post, removed: [], background: .dusk, hoverBlur: nil, hoverSwatch: nil, copiedAlpha: 0)
        func screenPoint(_ r: NSRect) -> CGPoint { CGPoint(x: win.minX + r.midX, y: win.minY + win.height - r.midY) }
        let blur = screenPoint(s.editor.demoBlurRect(email))
        let rest = CGPoint(x: win.midX + 60, y: win.maxY + 40)
        switch kind {
        case .unblur:
            duration = 5.6
            pointer = moves(rest, [(0.3, 1.2, blur), (2.4, 2.8, CGPoint(x: blur.x + 30, y: blur.y + 46)),
                                   (3.2, 3.6, blur), (4.4, 5.2, rest)], lerp: mix)
            clicks = [(1.5, { r, _ in r.insert(email) }), (3.9, { r, _ in r.remove(email) })]
            let close = fit(CGRect(x: win.midX - 400, y: blur.y - 190, width: 800, height: 380), aspect: Demo.video.width / Demo.video.height)
            cam = moves(wide, [(0.2, 1.2, close), (4.3, 5.3, wide)], lerp: mix)
        case .backgrounds:
            duration = 5.4
            let sw = { (bg: PostStyle.Background) in screenPoint(s.editor.demoSwatchRect(bg)) }
            pointer = moves(rest, [(0.2, 0.9, sw(.sand)), (1.6, 1.95, sw(.night)), (2.7, 3.05, sw(.dusk)), (4.2, 5.0, rest)], lerp: mix)
            clicks = [(1.15, { _, b in b = .sand }), (2.2, { _, b in b = .night }), (3.3, { _, b in b = .dusk })]
            cam = moves(wide, [], lerp: mix)
        }
    }

    private func state(_ t: Double) -> (removed: Set<Int>, bg: PostStyle.Background, lastClick: Double?) {
        var removed = Set<Int>(), bg = PostStyle.Background.dusk, last: Double?
        for c in clicks where t >= c.t { c.act(&removed, &bg); last = c.t }
        return (removed, bg, last)
    }

    func frame(_ t: Double) -> CGImage? {
        guard let ctx = context(size, px: 1) else { return nil }
        let c = cam.at(t)
        let k = size.width / c.width
        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -c.minX, y: -c.minY)
        draw(s.desktop, in: CGRect(origin: .zero, size: Demo.screen), ctx)

        let st = state(t)
        let p = pointer.at(t)
        // Hover follows the pointer, as in the editor.
        let local = CGPoint(x: p.x - win.minX, y: win.height - (p.y - win.minY))
        var hoverBlur: Int?, hoverSwatch: PostStyle.Background?
        if s.editor.demoBlurRect(email).contains(local) { hoverBlur = email }
        for bg in PostStyle.Background.allCases where s.editor.demoSwatchRect(bg).insetBy(dx: -5, dy: -5).contains(local) { hoverSwatch = bg }
        // "Copied" shows for 1.2 s after each change, then fades over 0.5 s.
        var copied = 0.0
        if let c = st.lastClick { let d = t - c; copied = d < 0.12 ? d / 0.12 : d < 1.32 ? 1 : max(0, 1 - (d - 1.32) / 0.5) }

        let image = s.post(removed: st.removed, background: st.bg)
        windowShape(ctx, win, fill: NSColor(srgbRed: 0.085, green: 0.088, blue: 0.098, alpha: 1))
        if let content = s.editor.demoSnapshot(size: win.size, image: image, removed: st.removed, background: st.bg,
                                               hoverBlur: hoverBlur, hoverSwatch: hoverSwatch, copiedAlpha: CGFloat(copied)) {
            ctx.saveGState()
            ctx.addPath(roundRect(win, 12))
            ctx.clip()
            draw(content, in: win, ctx)
            ctx.restoreGState()
        }
        trafficLights(ctx, at: CGPoint(x: win.minX + 20, y: win.minY + 18), only: true)
        let pressed = st.lastClick.map { t - $0 < 0.12 } ?? false
        cursor(hoverBlur != nil || hoverSwatch != nil ? .pointingHand : .arrow, at: p, ctx, size: pressed ? 1.25 : 1.35)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
