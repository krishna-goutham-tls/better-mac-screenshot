import Carbon
import Foundation

/// A global shortcut through the Carbon hotkey API. macOS tells the app only about this one key
/// combination, so the app needs no Accessibility permission.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    /// Returns nil when another app already holds the combination.
    init?(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Hotkey.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5353_4F54), id: id)  // "SSOT"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            Log.write("hotkey \(id) not registered, status \(status)")
            return nil
        }
        Hotkey.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { Hotkey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
