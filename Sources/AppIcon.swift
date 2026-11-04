import AppKit
import SwiftUI

private struct ViewfinderCorners: Shape {
    var length: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = length
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

/// The Finder, Dock and Login Items icon: cream viewfinder corners and an orange shutter dot on a
/// dark tile. Drawn in code so it can be regenerated: `ScreenshotTool --render-iconset dir.iconset`.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.13, green: 0.16, blue: 0.27), Color(red: 0.06, green: 0.08, blue: 0.15)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 2))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            ViewfinderCorners(length: 130)
                .stroke(Color(red: 0.96, green: 0.93, blue: 0.87), style: StrokeStyle(lineWidth: 46, lineCap: .round, lineJoin: .round))
                .frame(width: 470, height: 470)
            Circle().fill(Color(red: 0.98, green: 0.60, blue: 0.22)).frame(width: 120, height: 120)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// The menu bar icon: the same corners and dot, as a template image so macOS tints it for light and dark menu bars.
func menuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        let r = rect.insetBy(dx: 2, dy: 2)
        let l: CGFloat = 4.5
        let p = NSBezierPath()
        p.lineWidth = 1.8
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: r.minX, y: r.minY + l)); p.line(to: NSPoint(x: r.minX, y: r.minY)); p.line(to: NSPoint(x: r.minX + l, y: r.minY))
        p.move(to: NSPoint(x: r.maxX - l, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.minY + l))
        p.move(to: NSPoint(x: r.maxX, y: r.maxY - l)); p.line(to: NSPoint(x: r.maxX, y: r.maxY)); p.line(to: NSPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: NSPoint(x: r.minX + l, y: r.maxY)); p.line(to: NSPoint(x: r.minX, y: r.maxY)); p.line(to: NSPoint(x: r.minX, y: r.maxY - l))
        NSColor.black.setStroke()
        p.stroke()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - 2.25, y: rect.midY - 2.25, width: 4.5, height: 4.5)).fill()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Screenshot Tool"
    return image
}

@MainActor
func renderIconset(to directory: String) -> Bool {
    let sizes: [(String, CGFloat)] = [
        ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
        ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
        ("512x512", 512), ("512x512@2x", 1024),
    ]
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (name, pixels) in sizes {
        let renderer = ImageRenderer(content: AppIconArt().environment(\.colorScheme, .light))
        renderer.scale = pixels / 1024
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("icon_\(name).png"))
        } catch {
            return false
        }
    }
    return true
}
