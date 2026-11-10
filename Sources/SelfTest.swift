import AppKit

/// `ScreenshotTool --selftest [--out report.txt]`
/// Runs the pipeline without the mouse: Post look and auto-blur checks, then frozen frame, crop,
/// blur, Post, PNG, clipboard, file. Files go to a temp folder. The clipboard is restored at the end.
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

        // 2. Post look and auto-blur, each module's own checks.
        for row in PostStyle.selfCheck() + Redact.selfCheck() { check(row.name, row.ok, row.detail) }

        // 3. The capture pipeline on a 1600x1000 shot, warm: detect, blur, Post, PNG.
        pipelineCheck()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("screenshottool-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 4. File names: 10 shots in the same second get 10 different names.
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

        // 5. Real capture, 10 in a row, timed. Needs Screen Recording permission.
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
        var stageLines: [String] = []
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
            guard let shot = frame.cropping(to: crop) else { continue }
            let td = Date()
            let hits = Redact.detect(in: shot)
            let detectMs = Int(Date().timeIntervalSince(td) * 1000)
            guard let done = Output.finish(shot, hits: hits, scale: screen.backingScaleFactor, background: .dusk) else { continue }
            let png = done.png
            stageLines.append("\(shot.width)x\(shot.height) \(hits.count) hits: detect \(detectMs), blur \(done.stages.blur), post \(done.stages.post), png \(done.stages.png)")
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
        say("crop + detect + blur + Post + PNG + clipboard + file ms: \(outputMs.map(String.init).joined(separator: " "))")
        if let first = stageLines.first, let last = stageLines.last { say("stages ms, first and last capture: \(first) | \(last)") }
        return finish(reportPath)
    }

    private static func pipelineCheck() {
        let sample = Redact.terminalSample()
        let shot = sample.image
        var runs: [(total: Double, detect: Double, rest: Double, hits: [Redact.Hit], out: (image: CGImage, png: Data, stages: Output.Stages)?)] = []
        for _ in 0..<3 {
            let t0 = Date()
            let hits = Redact.detect(in: shot)
            let t1 = Date()
            let out = Output.finish(shot, hits: hits, scale: 2, background: .dusk)
            let t2 = Date()
            runs.append((t2.timeIntervalSince(t0) * 1000, t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, hits, out))
        }
        let median = runs.sorted { $0.total < $1.total }[1]
        guard let out = median.out else { return check("pipeline 1600x1000 returns a PNG", false) }
        let s = out.stages
        check("pipeline 1600x1000 detect + blur + Post + PNG under 400 ms warm", median.total < 400 && !s.covered,
              String(format: "median of 3: %.0f ms total, detect %.0f, blur %d, post %d, png %d, %d hits, %@ -> %dx%d, %d KB",
                     median.total, median.detect, s.blur, s.post, s.png, median.hits.count, "\(shot.width)x\(shot.height)",
                     out.image.width, out.image.height, out.png.count / 1024))

        // The editor maps each hit into the Post canvas. The blurred pixel at a hit's centre must show up
        // at the mapped point in the Post image, which catches a flipped y-axis or a shifted layout.
        if let blurred = Redact.apply(median.hits, to: shot), let post = PostStyle.render(blurred, scale: 2, background: .dusk) {
            let a = topLeftPixels(blurred), b = topLeftPixels(post)
            var matched = 0
            for hit in median.hits {
                let c = EditableShot.canvasRect(for: hit.rect, shotWidth: shot.width, shotHeight: shot.height, scale: 2)
                let sx = Int(hit.rect.midX), sy = Int(hit.rect.midY)
                // Canvas rects are bottom-left; the byte rows run top-down.
                let px = Int(c.midX), py = post.height - 1 - Int(c.midY)
                if let a, let b, a.pixel(sx, sy) == b.pixel(px, py) { matched += 1 }
            }
            check("editor puts each blur on the right spot in the Post image", matched == median.hits.count && matched > 0,
                  "\(matched)/\(median.hits.count) hits")
        } else {
            check("editor puts each blur on the right spot in the Post image", false, "render failed")
        }

        // A failed blur never lets the text through: the fallback covers each hit with an opaque box.
        if let hit = median.hits.first, let covered = Output.cover(median.hits, on: shot), let px = topLeftPixels(covered) {
            let p = px.pixel(Int(hit.rect.midX), Int(hit.rect.midY))
            check("blur fallback covers a hit with a solid box", p.0 == p.1 && abs(Int(p.0) - 140) < 4, "centre pixel \(p)")
        } else {
            check("blur fallback covers a hit with a solid box", false)
        }
    }

    /// RGBA bytes, rows top-down.
    private static func topLeftPixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8))? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let copy = bytes
        return (copy, w, { x, y in let i = (y * w + x) * 4; return (copy[i], copy[i + 1], copy[i + 2]) })
    }

    /// `ScreenshotTool --editor-test shot.png [--out post.png] [--click N] [--hover N] [--background night]`
    /// Runs detect on an image and opens the editor, so the editor can be checked without the mouse.
    /// Leaves the clipboard alone. `--out` gets the Post PNG, and each change overwrites it.
    static func editor(image path: String, out: String?, click: Int?, hover: Int?, background: PostStyle.Background?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil), let screen = NSScreen.main else {
            print("cannot read \(path)")
            exit(1)
        }
        let t0 = Date()
        let hits = Redact.detect(in: raw)
        let detectMs = Int(Date().timeIntervalSince(t0) * 1000)
        let url = out.map { URL(fileURLWithPath: $0) }
        let shot = EditableShot(raw: raw, hits: hits, scale: 2, background: background ?? .dusk, url: url)
        guard let done = Output.finish(raw, hits: hits, scale: 2, background: shot.background) else {
            print("pipeline failed")
            exit(1)
        }
        if let url { try? done.png.write(to: url, options: .atomic) }
        print("\(raw.width)x\(raw.height), \(hits.count) hits, detect \(detectMs) ms, blur \(done.stages.blur), post \(done.stages.post), png \(done.stages.png) ms")
        for (i, hit) in hits.enumerated() {
            let c = EditableShot.canvasRect(for: hit.rect, shotWidth: raw.width, shotHeight: raw.height, scale: 2)
            print("  \(i) \(hit.kind.rawValue) shot \(hit.rect) canvas \(c)")
        }
        fflush(stdout)
        let editor = Editor(shot: shot, image: done.image, png: done.png, queue: DispatchQueue(label: "output"), screen: screen)
        editor.copies = false
        editor.onClose = { exit(0) }
        editor.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let click { editor.toggle(click) }
            if let hover { editor.hover(hover) }
        }
        withExtendedLifetime(editor) { app.run() }
        exit(0)
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
