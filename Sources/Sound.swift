import AppKit

/// The macOS screenshot shutter sound, played from the system's own file. On by default; the
/// "Play capture sound" menu item turns it off.
enum Sound {
    private static let key = "playCaptureSound"
    private static let shutter: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Grab")
    }()

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func playShutter() {
        guard isOn, let shutter else { return }
        shutter.stop()
        shutter.play()
    }
}
