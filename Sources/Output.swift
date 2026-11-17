import AppKit
import ImageIO
import UniformTypeIdentifiers

/// PNG encoding, the clipboard and the file on disk.
enum Output {
    /// The folder macOS uses for its own screenshots (Screenshot app > Options > Save to), when the
    /// user picked one. Otherwise, or when that folder is gone, a "Screenshots" folder on the Desktop,
    /// made on first use. The Desktop itself only if that folder cannot be made.
    static func saveFolder() -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BETTERMACSCREENSHOT_SAVE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        var isDir: ObjCBool = false
        if let raw = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !raw.isEmpty {
            let path = ((raw as NSString).expandingTildeInPath as NSString).standardizingPath
            // macOS's default is the Desktop; only a folder the user chose wins over ours.
            if path != desktop.path, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        let folder = desktop.appendingPathComponent("Screenshots", isDirectory: true)
        if fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue { return folder }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return desktop
        }
    }

    /// "Screenshot 2026-11-04 at 20.41.37.png", then " (2)", " (3)" for shots in the same second.
    static func fileURL(in folder: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screenshot \(formatter.string(from: date))"
        var url = folder.appendingPathComponent("\(base).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).png")
            n += 1
        }
        return url
    }

    /// PNG with the screen's DPI (144 on Retina), so apps show it at its on-screen size.
    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Replaces the clipboard with the PNG. Returns the clipboard's change count after the write.
    @discardableResult
    static func copy(_ png: Data) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        return pb.changeCount
    }
}

extension Output {
    /// Milliseconds per stage, for the log. `covered` is true when the blur failed and solid boxes went on instead.
    struct Stages {
        var blur = 0, post = 0, png = 0
        var covered = false
    }

    /// The shot as it leaves the app: blur, Post look, PNG. The blur runs first, so no pixel under a hit
    /// reaches the clipboard or the disk unblurred. If the blur fails, the hits are covered with solid boxes.
    /// If that fails too, this returns nil and the caller delivers nothing. Safe on any queue.
    static func finish(_ shot: CGImage, hits: [Redact.Hit], scale: CGFloat,
                       background: PostStyle.Background) -> (image: CGImage, png: Data, stages: Stages)? {
        var stages = Stages()
        var t = Date()
        func lap() -> Int {
            let now = Date()
            defer { t = now }
            return Int((now.timeIntervalSince(t) * 1000).rounded())
        }
        var clean = shot
        if !hits.isEmpty {
            if let blurred = Redact.apply(hits, to: shot) {
                clean = blurred
            } else if let covered = cover(hits, on: shot) {
                clean = covered
                stages.covered = true
            } else {
                return nil
            }
        }
        stages.blur = lap()
        guard let post = PostStyle.render(clean, scale: scale, background: background) else { return nil }
        stages.post = lap()
        guard let data = png(post, scale: scale) else { return nil }
        stages.png = lap()
        return (post, data, stages)
    }

    /// The fallback when the blur fails: an opaque grey box over each hit. Plain Core Graphics, no Core Image.
    static func cover(_ hits: [Redact.Hit], on image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.55, blue: 0.57, alpha: 1))
        for hit in hits {
            // Hits are top-left pixels; the context is bottom-left.
            ctx.fill(CGRect(x: hit.rect.minX, y: CGFloat(h) - hit.rect.maxY, width: hit.rect.width, height: hit.rect.height))
        }
        return ctx.makeImage()
    }
}

extension Redact {
    private static let isOnKey = "blurSensitiveText"

    /// The "Blur sensitive text" menu item. On by default.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: isOnKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: isOnKey) }
    }
}

extension PostStyle {
    private static let backgroundKey = "postBackground"

    /// The background picked last in the editor. Later shots use it too.
    static var savedBackground: Background {
        get { UserDefaults.standard.string(forKey: backgroundKey).flatMap(Background.init(rawValue:)) ?? defaultBackground }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backgroundKey) }
    }
}
