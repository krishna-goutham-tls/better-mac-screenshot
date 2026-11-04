import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var postHotkey: Hotkey?
    private var overlay: SelectionOverlay?
    private var previousApp: NSRunningApplication?
    private let preview = Preview()
    /// Encode, clipboard and file run here one shot at a time, so fast shots land in order.
    private let output = DispatchQueue(label: "output")
    private var hotkeyItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot Tool")
            button.image?.isTemplate = true
        }

        postHotkey = Hotkey(id: 2, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.startCapture()
        }
        LoginItem.setDefaultOnFirstLaunch()
        buildMenu()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        Log.write("launched, hotkey Cmd+Shift+2 \(postHotkey == nil ? "NOT registered" : "registered"), save folder \(Output.saveFolder().path)")
    }

    private func buildMenu() {
        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture a region", action: #selector(captureFromMenu), keyEquivalent: "2")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)

        hotkeyItem = NSMenuItem(title: "Cmd+Shift+2 is taken by another app", action: nil, keyEquivalent: "")
        hotkeyItem.isHidden = postHotkey != nil
        menu.addItem(hotkeyItem)

        let folder = NSMenuItem(title: "Open screenshots folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())
        loginMenuItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        menu.delegate = self

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Screenshot Tool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func captureFromMenu() {
        // Let the menu close first, so it is not in the frozen frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.startCapture() }
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.isOn)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Output.saveFolder())
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    func startCapture() {
        guard overlay == nil, let screen = screenUnderMouse() else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front
        let started = Date()

        Capture.frozenFrame(of: screen) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Log.write("capture failed: \(error)")
                self.showPermissionHelp()
            case .success(let image):
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.write("frozen frame \(image.width)x\(image.height) in \(ms) ms")
                let overlay = SelectionOverlay(screen: screen, image: image) { [weak self] rect, viewSize in
                    self?.finishSelection(rect, viewSize: viewSize, image: image, screen: screen)
                }
                self.overlay = overlay
                overlay.show()
            }
        }
    }

    private func finishSelection(_ rect: NSRect?, viewSize: NSSize, image: CGImage, screen: NSScreen) {
        overlay?.close()
        overlay = nil
        previousApp?.activate()
        previousApp = nil
        guard let rect else { return }

        let crop = Capture.pixelRect(for: rect, viewSize: viewSize, imageWidth: image.width, imageHeight: image.height)
        guard let shot = image.cropping(to: crop) else { return Log.write("crop failed for \(crop)") }
        let scale = screen.backingScaleFactor
        output.async { [weak self] in
            guard let png = Output.png(shot, scale: scale) else { return Log.write("PNG encode failed") }
            DispatchQueue.main.sync { _ = Output.copy(png) }
            let url = Output.fileURL(in: Output.saveFolder())
            do {
                try png.write(to: url, options: .atomic)
                Log.write("saved \(url.lastPathComponent) \(shot.width)x\(shot.height)")
            } catch {
                Log.write("save failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { self?.preview.show(shot, on: screen) }
        }
    }

    private func showPermissionHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screenshot Tool needs Screen Recording permission"
        alert.informativeText = "Turn on Screenshot Tool in System Settings > Privacy & Security > Screen & System Audio Recording. Then quit and open Screenshot Tool again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginMenuItem.state = LoginItem.isOn ? .on : .off
    }
}
