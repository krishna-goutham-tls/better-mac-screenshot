import Foundation
import ServiceManagement

/// "Open at login" through macOS's own login items list (System Settings > General > Login Items).
/// Turned on once, at the first launch. After that only the user's choice counts.
enum LoginItem {
    private static let didSetDefaultKey = "loginItemDefaultSet"

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func setDefaultOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSetDefaultKey) else { return }
        defaults.set(true, forKey: didSetDefaultKey)
        set(true)
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("open at login \(on ? "on" : "off"), status \(SMAppService.mainApp.status.rawValue)")
        } catch {
            Log.write("open at login \(on ? "on" : "off") failed: \(error.localizedDescription)")
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
