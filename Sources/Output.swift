import AppKit
import ImageIO
import UniformTypeIdentifiers

/// PNG encoding, the clipboard and the file on disk.
enum Output {
    /// The folder macOS uses for its own screenshots (Screenshot app > Options > Save to).
    /// Desktop when the user never changed it or the folder is gone.
    static func saveFolder() -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SCREENSHOTTOOL_SAVE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
              !raw.isEmpty else { return desktop }
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: path) else {
            return desktop
        }
        return URL(fileURLWithPath: path, isDirectory: true)
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
