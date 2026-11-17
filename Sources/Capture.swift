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

    /// One filter per display, built ahead of time, so a shot skips the window list (the slow part).
    /// Main thread only. `prepare()` refreshes it at launch and when displays change.
    private static var filters: [CGDirectDisplayID: SCContentFilter] = [:]

    static func prepare(completion: (() -> Void)? = nil) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            DispatchQueue.main.async {
                if let content {
                    // Excluding the app (not its windows) also leaves out windows it opens later, such as
                    // the selection overlay that is already on screen when the frame is taken.
                    let mine = content.applications.filter { $0.processID == getpid() }
                    var next: [CGDirectDisplayID: SCContentFilter] = [:]
                    for display in content.displays {
                        next[display.displayID] = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                    }
                    filters = next
                }
                completion?()
            }
        }
    }

    /// Calls back on the main queue. Leaves this app's own windows (overlay, corner preview) out of the frame.
    static func frozenFrame(of screen: NSScreen, completion: @escaping (Result<CGImage, Error>) -> Void) {
        let finish: (Result<CGImage, Error>) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        guard let id = displayID(of: screen) else { return finish(.failure(CaptureError.noDisplay)) }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        config.captureResolution = .best

        func shoot(_ filter: SCContentFilter, retry: Bool) {
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image { return finish(.success(image)) }
                // A stale filter (display gone, app list changed): rebuild once, then give up.
                if retry { return DispatchQueue.main.async { refreshThenShoot() } }
                finish(.failure(error ?? CaptureError.noImage))
            }
        }
        func refreshThenShoot() {
            prepare {
                guard let filter = filters[id] else { return finish(.failure(CaptureError.noDisplay)) }
                shoot(filter, retry: false)
            }
        }
        if let filter = filters[id] { shoot(filter, retry: true) } else { refreshThenShoot() }
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
