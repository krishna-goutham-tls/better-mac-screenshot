import AppKit
import SwiftUI

/// The first-launch window. A menu bar app shows nothing when it opens, so this window says it is
/// running, gets the Screen Recording permission, and asks for one practice shot. It opens on every
/// launch until that first shot lands, and again whenever a capture fails for lack of permission.
final class Setup: NSObject, ObservableObject, NSWindowDelegate {
    private static let doneKey = "setupDone"
    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    @Published var permitted = CGPreflightScreenCaptureAccess()
    /// The user clicked Allow in this launch. macOS often applies a new grant only after a relaunch,
    /// so from then on the window offers "Quit and reopen".
    @Published var asked = false
    @Published var shotTaken = false

    private var window: NSWindow?
    private var timer: Timer?

    func show() {
        permitted = CGPreflightScreenCaptureAccess()
        if window == nil {
            let host = NSHostingController(rootView: SetupView(model: self))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CGPreflightScreenCaptureAccess()
            if now != self.permitted { self.permitted = now }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Called after a shot reaches the clipboard.
    func shotDone() {
        Setup.isDone = true
        shotTaken = true
        permitted = true
    }

    func allow() {
        asked = true
        // The first call shows macOS's own prompt; later calls do nothing, so open the pane too.
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this copy to exit, so the single-instance check does not stop the new one.
        task.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

private struct SetupView: View {
    @ObservedObject var model: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.shotTaken ? "You are all set" : "Better Mac Screenshot is running")
                        .font(.system(size: 20, weight: .semibold))
                    Text(model.shotTaken ? "Every shot is on your clipboard, ready to paste." : "Two steps and it is ready.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 24)

            StepRow(number: 1, done: model.permitted, title: "Allow Screen Recording",
                    detail: model.permitted ? "Done." : (model.asked ? "Turn on Better Mac Screenshot in the list, then reopen the app." : "macOS asks for this before any app can take a screenshot.")) {
                if !model.permitted {
                    if model.asked {
                        Button("Quit and reopen") { model.relaunch() }
                    } else {
                        Button("Allow") { model.allow() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            Divider().padding(.vertical, 14)
            StepRow(number: 2, done: model.shotTaken, title: "Take your first shot",
                    detail: model.shotTaken ? "Done. It is also in Screenshots on your Desktop." : "Press the keys, then drag over any part of the screen.") {
                if !model.shotTaken { KeyCaps() }
            }
            .opacity(model.permitted ? 1 : 0.45)

            HStack {
                Label("It lives in your menu bar", systemImage: "arrow.up.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.shotTaken {
                    Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(width: 460)
    }
}

private struct StepRow<Action: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.primary.opacity(0.08))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
    }
}

private struct KeyCaps: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(["⌘", "⇧", "2"], id: \.self) { key in
                Text(key)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .frame(minWidth: 26, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            }
        }
        .accessibilityLabel("Command Shift 2")
    }
}
