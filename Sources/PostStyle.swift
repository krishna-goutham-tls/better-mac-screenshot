import AppKit

/// Post mode: puts a region shot on a calm background with padding, rounded corners and a soft
/// shadow, so it looks finished when pasted into an X post. Pure Core Graphics, safe on any queue.
enum PostStyle {
    /// The three backgrounds. Each is drawn in code, no image assets.
    enum Background: String, CaseIterable {
        /// Warm cream, the light tone of the app icon.
        case sand
        /// Deep navy, the app icon's tile, with a faint warm glow.
        case night
        /// A quiet diagonal from soft periwinkle to pale apricot.
        case dusk
    }

    static let defaultBackground: Background = .dusk

    /// X shows a single image uncropped in the feed between 4:5 (portrait) and 16:9 (wide).
    /// Outside that the canvas grows on its short side and the shot stays centred.
    static let minRatio: CGFloat = 4.0 / 5.0
    static let maxRatio: CGFloat = 16.0 / 9.0

    /// Canvas size and where the shot sits in it, in pixels. Bottom-left origin, like CGContext.
    static func layout(width w: Int, height h: Int, scale: CGFloat) -> (width: Int, height: Int, shot: CGRect) {
        let s = max(scale, 1)
        // 7% of the long side, never under 28 pt or over 80 pt.
        let pad = Int((min(max(CGFloat(max(w, h)) * 0.07, 28 * s), 80 * s)).rounded())
        var cw = w + 2 * pad
        var ch = h + 2 * pad
        if CGFloat(cw) / CGFloat(ch) > maxRatio { ch = Int((CGFloat(cw) / maxRatio).rounded(.up)) }
        if CGFloat(cw) / CGFloat(ch) < minRatio { cw = Int((CGFloat(ch) * minRatio).rounded(.up)) }
        // Whole-pixel origin, so the shot is copied 1:1 and never resampled.
        let x = (cw - w) / 2
        let y = (ch - h) / 2
        return (cw, ch, CGRect(x: x, y: y, width: w, height: h))
    }

    /// `scale` is the screen backing scale (2 on Retina). Returns nil only on context failure.
    static func render(_ shot: CGImage, scale: CGFloat, background: Background = defaultBackground) -> CGImage? {
        let s = max(scale, 1)
        let (cw, ch, rect) = layout(width: shot.width, height: shot.height, scale: s)
        // Draw in the shot's own colour space, so its pixels are copied without conversion.
        let space = shot.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: cw, height: ch)

        // The gradients have no detail, so they are drawn at quarter size and scaled up. Grain goes on at full size.
        if let wash = backgroundWash(background, width: cw, height: ch) {
            ctx.interpolationQuality = .high
            ctx.draw(wash, in: canvas)
        }
        addGrain(to: ctx, strength: background == .night ? 0.035 : 0.025)

        let radius = min(10 * s, CGFloat(min(shot.width, shot.height)) * 0.12)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let pad = min(rect.minX, rect.minY)
        let tone = shadowTone(background)

        // Wide, soft shadow. Blurred at quarter size and scaled up: it has no detail to lose and
        // a full-size blur this wide costs far more time.
        if let soft = softShadow(path: path, canvas: canvas, blur: pad * 0.75, dy: -pad * 0.22,
                                 color: tone.copy(alpha: background == .night ? 0.55 : 0.26)!) {
            ctx.interpolationQuality = .high
            ctx.draw(soft, in: canvas)
        }

        // Tight contact shadow and a hairline edge, so the shot separates from any background.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * s), blur: 2 * s,
                      color: tone.copy(alpha: background == .night ? 0.5 : 0.18))
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -0.5 * s, dy: -0.5 * s),
                           cornerWidth: radius + 0.5 * s, cornerHeight: radius + 0.5 * s, transform: nil))
        ctx.setFillColor(background == .night ? srgb(1, 1, 1, 0.10) : srgb(0, 0, 0, 0.06))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(shot, in: rect)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func shadowTone(_ background: Background) -> CGColor {
        switch background {
        case .sand: return srgb(0.30, 0.22, 0.14)
        case .night: return srgb(0, 0, 0)
        case .dusk: return srgb(0.20, 0.18, 0.32)
        }
    }

    private static func backgroundWash(_ background: Background, width: Int, height: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = max(width / 4, 1), h = max(height / 4, 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
        }
        let top = CGPoint(x: rect.midX, y: rect.maxY)
        let bottom = CGPoint(x: rect.midX, y: rect.minY)
        let reach = hypot(rect.width, rect.height)
        let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        switch background {
        case .sand:
            ctx.drawLinearGradient(gradient([srgb(0.965, 0.945, 0.910), srgb(0.915, 0.880, 0.825)], [0, 1]),
                                   start: top, end: bottom, options: opts)
            // Soft light from the top left.
            ctx.drawRadialGradient(gradient([srgb(1, 0.99, 0.97, 0.55), srgb(1, 0.99, 0.97, 0)], [0, 1]),
                                   startCenter: CGPoint(x: rect.width * 0.2, y: rect.maxY), startRadius: 0,
                                   endCenter: CGPoint(x: rect.width * 0.2, y: rect.maxY), endRadius: reach * 0.7, options: [])
        case .night:
            ctx.drawLinearGradient(gradient([srgb(0.13, 0.16, 0.27), srgb(0.06, 0.08, 0.15)], [0, 1]),
                                   start: top, end: bottom, options: opts)
            // A faint glow of the icon's orange, low and to the right.
            ctx.drawRadialGradient(gradient([srgb(0.98, 0.60, 0.22, 0.13), srgb(0.98, 0.60, 0.22, 0)], [0, 1]),
                                   startCenter: CGPoint(x: rect.width * 0.85, y: rect.minY), startRadius: 0,
                                   endCenter: CGPoint(x: rect.width * 0.85, y: rect.minY), endRadius: reach * 0.6, options: [])
        case .dusk:
            ctx.drawLinearGradient(gradient([srgb(0.780, 0.815, 0.930), srgb(0.880, 0.860, 0.925), srgb(0.975, 0.865, 0.800)],
                                            [0, 0.5, 1]),
                                   start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
                                   options: opts)
        }
        return ctx.makeImage()
    }

    /// Fine grain, so the gradients do not band in 8-bit output.
    private static func addGrain(to ctx: CGContext, strength: CGFloat) {
        guard let grain = grainTile else { return }
        ctx.saveGState()
        ctx.setAlpha(strength)
        ctx.setBlendMode(.overlay)
        ctx.interpolationQuality = .none
        ctx.draw(grain, in: CGRect(x: 0, y: 0, width: grain.width, height: grain.height), byTiling: true)
        ctx.restoreGState()
    }

    /// 128x128 grey noise, made once from a fixed seed so every render is identical.
    private static let grainTile: CGImage? = {
        let n = 128
        var bytes = [UInt8](repeating: 0, count: n * n)
        var x: UInt32 = 0x9E3779B9
        for i in 0..<bytes.count {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            bytes[i] = UInt8(truncatingIfNeeded: x >> 24)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    /// The shadow of `path` alone, drawn at quarter size. The shape is drawn off the canvas and
    /// only its shadow is offset back in, so no hard edge can show around the shot.
    private static func softShadow(path: CGPath, canvas: CGRect, blur: CGFloat, dy: CGFloat, color: CGColor) -> CGImage? {
        let k: CGFloat = 0.25
        let w = max(Int((canvas.width * k).rounded(.up)), 1)
        let h = max(Int((canvas.height * k).rounded(.up)), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let away = CGFloat(w) * 2
        ctx.setShadow(offset: CGSize(width: -away, height: dy * k), blur: blur * k, color: color)
        ctx.translateBy(x: away, y: 0)
        ctx.scaleBy(x: k, y: k)
        ctx.addPath(path)
        ctx.setFillColor(srgb(0, 0, 0))
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// Pure checks for the app selftest. No screen capture, no files.
    static func selfCheck() -> [(name: String, ok: Bool, detail: String)] {
        var results: [(name: String, ok: Bool, detail: String)] = []
        let shapes: [(String, Int, Int)] = [("normal", 1600, 1000), ("very wide", 2000, 200), ("very tall", 300, 2000), ("tiny", 200, 80)]
        for (label, w, h) in shapes {
            guard let shot = testShot(width: w, height: h) else {
                results.append(("post \(label): test shot", false, "context failed"))
                continue
            }
            for bg in Background.allCases {
                guard let out = render(shot, scale: 2, background: bg) else {
                    results.append(("post \(label) \(bg.rawValue): renders", false, "nil"))
                    continue
                }
                let ratio = CGFloat(out.width) / CGFloat(out.height)
                let larger = out.width > w && out.height > h
                let inRange = ratio >= minRatio - 0.005 && ratio <= maxRatio + 0.005
                let same = centreMatches(shot: shot, output: out)
                results.append(("post \(label) \(bg.rawValue): larger, ratio in 4:5..16:9, shot pixels unchanged",
                                larger && inRange && same,
                                "\(w)x\(h) -> \(out.width)x\(out.height), ratio \(String(format: "%.3f", ratio)), pixels \(same ? "same" : "changed")"))
            }
        }
        if let shot = testShot(width: 1600, height: 1000) {
            _ = render(shot, scale: 2)
            var best = Double.infinity
            for _ in 0..<5 {
                let t0 = Date()
                _ = render(shot, scale: 2)
                best = min(best, Date().timeIntervalSince(t0) * 1000)
            }
            results.append(("post render 1600x1000 under 60 ms", best < 60, String(format: "best of 5: %.1f ms", best)))
        }
        return results
    }

    /// A shot with a different colour in every pixel, so any resampling or shift shows.
    private static func testShot(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return nil }
        let row = ctx.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: row * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * row + x * 4
                p[i] = UInt8(truncatingIfNeeded: x &* 7 &+ y)      // B
                p[i + 1] = UInt8(truncatingIfNeeded: y &* 13 &+ x)  // G
                p[i + 2] = UInt8(truncatingIfNeeded: (x ^ y) &* 3)  // R
                p[i + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    /// Compares a 9x9 grid of points across the inner 80% of the shot with the same points in the output.
    private static func centreMatches(shot: CGImage, output: CGImage) -> Bool {
        guard let a = pixels(shot), let b = pixels(output) else { return false }
        let rect = layout(width: shot.width, height: shot.height, scale: 2).shot
        for gy in 1...9 {
            for gx in 1...9 {
                let x = Int(CGFloat(shot.width) * (0.1 + 0.8 * CGFloat(gx - 1) / 8))
                let y = Int(CGFloat(shot.height) * (0.1 + 0.8 * CGFloat(gy - 1) / 8))
                let sx = min(x, shot.width - 1), sy = min(y, shot.height - 1)
                // Bitmap rows run top-down; the layout rect is bottom-up.
                let ox = Int(rect.minX) + sx
                let oy = (output.height - Int(rect.maxY)) + sy
                let i = sy * a.row + sx * 4, j = oy * b.row + ox * 4
                if a.bytes[i] != b.bytes[j] || a.bytes[i + 1] != b.bytes[j + 1] || a.bytes[i + 2] != b.bytes[j + 2] { return false }
            }
        }
        return true
    }

    private static func pixels(_ image: CGImage) -> (bytes: [UInt8], row: Int)? {
        let row = image.width * 4
        var bytes = [UInt8](repeating: 0, count: row * image.height)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? (bytes, row) : nil
    }
}
