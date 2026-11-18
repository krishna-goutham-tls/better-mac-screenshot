import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var postHotkey: Hotkey?
    private var overlay: SelectionOverlay?
    /// One overlay per display, reused for every shot. Rebuilt when displays change.
    private var overlays: [CGDirectDisplayID: SelectionOverlay] = [:]
    private var previousApp: NSRunningApplication?
    private let preview = Preview()
    private let setup = Setup()
    /// Blur, Post look, encode, clipboard and file run here one shot at a time, so fast shots land in order.
    private let output = DispatchQueue(label: "output")
    /// The most recent shot, for the editor. Older shots are not kept.
    private var last: (shot: EditableShot, image: CGImage, png: Data)?
    private var editor: Editor?
    private var hotkeyItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!
    private var soundMenuItem: NSMenuItem!
    private var blurMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = menuBarIcon()
        }

        postHotkey = Hotkey(id: 2, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.startCapture()
        }
        LoginItem.setDefaultOnFirstLaunch()
        buildMenu()
        preview.onClick = { [weak self] screen in self?.openEditor(on: screen) }
        warmUp()

        // The setup window asks for Screen Recording; it shows until the first shot lands.
        if !Setup.isDone || !CGPreflightScreenCaptureAccess() {
            setup.show()
        }
        Capture.prepare()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlays.removeAll()
                Capture.prepare()
            }
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
        blurMenuItem = NSMenuItem(title: "Blur sensitive text", action: #selector(toggleBlur), keyEquivalent: "")
        blurMenuItem.target = self
        menu.addItem(blurMenuItem)
        soundMenuItem = NSMenuItem(title: "Play capture sound", action: #selector(toggleSound), keyEquivalent: "")
        soundMenuItem.target = self
        menu.addItem(soundMenuItem)
        loginMenuItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        menu.delegate = self

        menu.addItem(.separator())
        MainActor.assumeIsolated { menu.addItem(Updater.shared.menuItem) }
        let quit = NSMenuItem(title: "Quit Better Mac Screenshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        MainActor.assumeIsolated { Updater.shared.start() }
    }

    @objc private func captureFromMenu() {
        // Let the menu close first, so it is not in the frozen frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.startCapture() }
    }

    @objc private func toggleBlur() {
        Redact.isOn.toggle()
    }

    @objc private func toggleSound() {
        Sound.isOn.toggle()
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
        guard overlay == nil, let screen = screenUnderMouse(), let id = Capture.displayID(of: screen) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front
        let started = Date()

        // The dim layer goes up first, so the shortcut answers at once; the frame follows under it.
        let overlay = overlays[id] ?? SelectionOverlay(screen: screen)
        overlays[id] = overlay
        var frame: CGImage?
        var pending: (rect: NSRect, size: NSSize)?
        overlay.onDone = { [weak self] rect, size in
            guard let self else { return }
            guard let rect else { return self.finishSelection(nil, viewSize: size, image: nil, screen: screen) }
            // A drag that ends before the frame lands (rare: the frame takes about 20 ms) waits for it.
            if let frame { self.finishSelection(rect, viewSize: size, image: frame, screen: screen) } else { pending = (rect, size) }
        }
        self.overlay = overlay
        overlay.begin()

        Capture.frozenFrame(of: screen) { [weak self] result in
            guard let self, self.overlay === overlay else { return }
            switch result {
            case .failure(let error):
                Log.write("capture failed: \(error)")
                self.finishSelection(nil, viewSize: .zero, image: nil, screen: screen)
                self.showPermissionHelp()
            case .success(let image):
                Log.write("frozen frame \(image.width)x\(image.height) in \(Int(Date().timeIntervalSince(started) * 1000)) ms, dim layer was up at once")
                frame = image
                overlay.setFrame(image)
                if let pending { self.finishSelection(pending.rect, viewSize: pending.size, image: image, screen: screen) }
            }
        }
    }

    private func finishSelection(_ rect: NSRect?, viewSize: NSSize, image: CGImage?, screen: NSScreen) {
        overlay?.close()
        overlay = nil
        // Nil when the editor was in front: a cancel then leaves the focus on the editor.
        var back = previousApp
        previousApp = nil
        if rect != nil, let editor {
            // A new shot replaces the one in the editor; focus goes where the editor would have sent it.
            back = back ?? editor.previousApp
            editor.close(restoreFocus: false)
        }
        back?.activate()
        guard let rect, let image else { return }
        preview.hideNow()
        Sound.playShutter()

        let t0 = Date()
        let crop = Capture.pixelRect(for: rect, viewSize: viewSize, imageWidth: image.width, imageHeight: image.height)
        guard let shot = image.cropping(to: crop) else { return Log.write("crop failed for \(crop)") }
        let cropMs = Int(Date().timeIntervalSince(t0) * 1000)
        let scale = screen.backingScaleFactor
        let blur = Redact.isOn
        let background = PostStyle.savedBackground
        output.async { [weak self] in
            var t = Date()
            func lap() -> Int {
                let now = Date()
                defer { t = now }
                return Int((now.timeIntervalSince(t) * 1000).rounded())
            }
            // Detect and blur before anything reaches the clipboard or the disk.
            let hits = blur ? Redact.detect(in: shot) : []
            let detectMs = lap()
            guard let done = Output.finish(shot, hits: hits, scale: scale, background: background) else {
                Log.write("shot \(shot.width)x\(shot.height) not delivered: blur or Post render failed with \(hits.count) hits, nothing copied or saved")
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            if done.stages.covered { Log.write("blur failed, \(hits.count) hits covered with solid boxes instead") }
            t = Date()
            DispatchQueue.main.sync { _ = Output.copy(done.png) }
            let copyMs = lap()
            let url = Output.fileURL(in: Output.saveFolder())
            var saved: URL?
            do {
                try done.png.write(to: url, options: .atomic)
                saved = url
            } catch {
                Log.write("save failed: \(error.localizedDescription)")
            }
            let saveMs = lap()
            let s = done.stages
            Log.write("shot \(shot.width)x\(shot.height) -> \(done.image.width)x\(done.image.height), \(blur ? "\(hits.count) blurs" : "blur off"), \(background.rawValue), saved \(saved?.lastPathComponent ?? "nothing"): crop \(cropMs), detect \(detectMs), blur \(s.blur), post \(s.post), png \(s.png), copy \(copyMs), save \(saveMs), total \(cropMs + detectMs + s.blur + s.post + s.png + copyMs + saveMs) ms")
            let editable = EditableShot(raw: shot, hits: hits, scale: scale, background: background, url: saved)
            DispatchQueue.main.async {
                self?.last = (editable, done.image, done.png)
                self?.preview.show(done.image, on: screen)
                self?.setup.shotDone()
            }
        }
    }

    private func openEditor(on screen: NSScreen) {
        guard let last else { return }
        let old = editor
        old?.close(restoreFocus: false)
        let editor = Editor(shot: last.shot, image: last.image, png: last.png, queue: output, screen: screen)
        editor.onClose = { [weak self, weak editor] in
            if let self, self.editor === editor { self.editor = nil }
        }
        // Only while this shot is still the last one: a newer shot must not be replaced by an older edit.
        let opened = last.shot.raw
        editor.onRendered = { [weak self] shot, image, png in
            guard let self, self.last?.shot.raw === opened else { return }
            self.last = (shot, image, png)
        }
        self.editor = editor
        editor.show(returningTo: old?.previousApp)
    }

    /// Vision loads its models on the first read, which costs a few hundred ms. One throwaway read
    /// on a small image right after launch moves that cost off the first real shot.
    private func warmUp() {
        output.async {
            let t0 = Date()
            guard let sample = Redact.renderSample(["warm up 0123"], width: 480, height: 80) else { return }
            let hits = Redact.detect(in: sample.image)
            _ = Output.finish(sample.image, hits: hits, scale: 2, background: PostStyle.savedBackground)
            Log.write("warm-up in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }

    private func showPermissionHelp() {
        setup.show()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginMenuItem.state = LoginItem.isOn ? .on : .off
        soundMenuItem.state = Sound.isOn ? .on : .off
        blurMenuItem.state = Redact.isOn ? .on : .off
    }
}
