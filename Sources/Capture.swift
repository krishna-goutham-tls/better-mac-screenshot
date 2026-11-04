import AppKit
import ScreenCaptureKit

enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case noImage
    var description: String {
        switch self {
        case .noDisplay: return "display not found"
        case .noImage: return "capture returned no image"
        }
    }
}

/// Grabs the whole screen at once (the frozen frame). The user then drags a region on that image,
/// so the shot never depends on Apple's screenshot tool or its file save.
enum Capture {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Calls back on the main queue. Leaves this app's own windows (the corner preview) out of the frame.
    static func frozenFrame(of screen: NSScreen, completion: @escaping (Result<CGImage, Error>) -> Void) {
        let finish: (Result<CGImage, Error>) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        guard let id = displayID(of: screen) else { return finish(.failure(CaptureError.noDisplay)) }
        let pointSize = screen.frame.size
        let scale = screen.backingScaleFactor

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error { return finish(.failure(error)) }
            guard let content, let display = content.displays.first(where: { $0.displayID == id }) else {
                return finish(.failure(CaptureError.noDisplay))
            }
            let mine = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(pointSize.width * scale)
            config.height = Int(pointSize.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let error { return finish(.failure(error)) }
                guard let image else { return finish(.failure(CaptureError.noImage)) }
                finish(.success(image))
            }
        }
    }

    /// Converts a selection in view points (origin bottom left) to a pixel crop of the frozen frame.
    static func pixelRect(for selection: NSRect, viewSize: NSSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        let sx = CGFloat(imageWidth) / viewSize.width
        let sy = CGFloat(imageHeight) / viewSize.height
        let rect = CGRect(
            x: selection.minX * sx,
            y: (viewSize.height - selection.maxY) * sy,
            width: selection.width * sx,
            height: selection.height * sy)
        return rect.integral.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }
}
