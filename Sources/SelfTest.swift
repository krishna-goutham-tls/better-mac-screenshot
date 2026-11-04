import AppKit

/// `ScreenshotTool --selftest [--out report.txt]`
/// Runs the Day 1 pipeline without the mouse: frozen frame, crop, PNG, clipboard, file.
/// Files go to a temp folder. The clipboard is restored at the end.
enum SelfTest {
    private static var lines: [String] = []
    private static var failures = 0

    private static func say(_ s: String) { lines.append(s); print(s) }
    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        say("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failures += 1 }
    }

    static func run(reportPath: String?) -> Int32 {
        say("Screenshot Tool selftest")
        say("save folder: \(Output.saveFolder().path)")

        // 1. Crop math: a 100x50 pt drag at (10, 20) on a 1000x500 pt screen with a 2x frame.
        let r = Capture.pixelRect(for: NSRect(x: 10, y: 20, width: 100, height: 50),
                                  viewSize: NSSize(width: 1000, height: 500), imageWidth: 2000, imageHeight: 1000)
        check("crop maps points to pixels, top-left origin", r == CGRect(x: 20, y: 860, width: 200, height: 100), "\(r)")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("screenshottool-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 2. File names: 10 shots in the same second get 10 different names.
        let now = Date()
        var names = Set<String>()
        for _ in 0..<10 {
            let url = Output.fileURL(in: tmp, date: now)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            names.insert(url.lastPathComponent)
        }
        check("10 names in one second are all different", names.count == 10)
        for name in names { try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name)) }

        let saved = saveClipboard()
        defer { restoreClipboard(saved) }

        // 3. Real capture, 10 in a row, timed. Needs Screen Recording permission.
        guard CGPreflightScreenCaptureAccess() else {
            say("SKIP  real capture: Screen Recording permission is not granted to this app")
            return finish(reportPath)
        }
        guard let screen = NSScreen.main else {
            check("a screen is available", false)
            return finish(reportPath)
        }
        var captureMs: [Int] = []
        var outputMs: [Int] = []
        var clipboardOK = 0
        let pb = NSPasteboard.general
        let start = Date()
        for i in 0..<10 {
            let t0 = Date()
            let sem = DispatchSemaphore(value: 0)
            var frame: CGImage?
            Capture.frozenFrame(of: screen) { result in
                if case .success(let img) = result { frame = img }
                if case .failure(let e) = result { say("      capture \(i + 1) error: \(e)") }
                sem.signal()
            }
            // The callback hops to the main queue, so spin the run loop while we wait.
            while sem.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            captureMs.append(Int(Date().timeIntervalSince(t0) * 1000))
            guard let frame else { continue }

            let t1 = Date()
            let viewSize = screen.frame.size
            let sel = NSRect(x: viewSize.width * 0.25, y: viewSize.height * 0.25,
                             width: viewSize.width * 0.5, height: viewSize.height * 0.5)
            let crop = Capture.pixelRect(for: sel, viewSize: viewSize, imageWidth: frame.width, imageHeight: frame.height)
            guard let shot = frame.cropping(to: crop), let png = Output.png(shot, scale: screen.backingScaleFactor) else { continue }
            let before = pb.changeCount
            Output.copy(png)
            if pb.changeCount != before, pb.data(forType: .png) == png { clipboardOK += 1 }
            let url = Output.fileURL(in: tmp)
            try? png.write(to: url, options: .atomic)
            outputMs.append(Int(Date().timeIntervalSince(t1) * 1000))
        }
        let total = Date().timeIntervalSince(start)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".png") }.count) ?? 0

        check("10 captures made 10 files", files == 10, "\(files) files")
        check("each capture reached the clipboard", clipboardOK == 10, "\(clipboardOK)/10")
        check("10 captures took under 10 seconds", total < 10, String(format: "%.2f s", total))
        say("frozen frame ms: \(captureMs.map(String.init).joined(separator: " "))")
        say("crop + PNG + clipboard + file ms: \(outputMs.map(String.init).joined(separator: " "))")
        return finish(reportPath)
    }

    private static func finish(_ reportPath: String?) -> Int32 {
        say(failures == 0 ? "RESULT  all passed" : "RESULT  \(failures) failed")
        if let reportPath {
            try? lines.joined(separator: "\n").appending("\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        }
        return failures == 0 ? 0 : 1
    }

    private static func saveClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        }
    }

    private static func restoreClipboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
