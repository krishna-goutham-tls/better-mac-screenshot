import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// `BetterMacScreenshot --redact-bench [--out report.txt] [--dump dir]`
/// Judges auto-blur from the outside. Draws realistic scenes in code (a terminal, an IDE window, a .env file
/// in an editor, a team chat), so the pixel box of every secret character comes from CoreText, not from OCR.
/// Then it calls only `Redact.detect` and `Redact.apply` and measures what a person could still read.
/// Fixed seeds, so two runs on the same detector print the same table.
enum RedactBench {
    static func run(reportPath: String?, dumpDir: String?) -> Int32 {
        var report: [String] = []
        func say(_ s: String) { report.append(s); print(s); fflush(stdout) }
        if let dumpDir { try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true) }

        say("Redact bench")
        say("fonts: " + ["Menlo", "SF Mono", "Monaco", "SF Pro", "Helvetica"]
            .map { "\($0) -> \(CTFontCopyPostScriptName(makeFont($0, 13)) as String)" }.joined(separator: ", "))

        // Vision loads its models on the first call. Every timed case after this one is warm.
        autoreleasepool {
            if let page = build(Case(scene: .terminal, w: 1600, h: 1000, font: "Menlo", px: 26, dark: true), seed: 1),
               let image = page.ctx.makeImage() {
                _ = Redact.apply(Redact.detect(in: image), to: image)
            }
        }

        let started = Date()
        var outcomes: [Outcome] = []
        var pruned = 0
        for (i, c) in cases().enumerated() {
            autoreleasepool {
                guard let page = build(c, seed: UInt64(i + 1) &* 0x9E37_79B9), let image = page.ctx.makeImage() else {
                    pruned += 1
                    return
                }
                let t0 = Date()
                let hits = Redact.detect(in: image)
                let blurred = Redact.apply(hits, to: image) ?? image
                let ms = Date().timeIntervalSince(t0) * 1000
                let o = evaluate(c, page: page, hits: hits, input: image, output: blurred, ms: ms)
                if o.failed, let dumpDir {
                    let name = (o.tiny ? "tiny-" : "") + c.name.replacingOccurrences(of: " ", with: "-") + ".png"
                    dump(blurred, page: page, hits: hits, px: c.px, to: (dumpDir as NSString).appendingPathComponent(name))
                }
                outcomes.append(o)
            }
        }
        let total = Date().timeIntervalSince(started)

        // Table per scene and canvas size. Tiny cases are counted apart and never fail the run.
        say("")
        say(pad("scene", 9) + pad("size", 11) + lpad("cases", 6) + lpad("tiny", 5) + lpad("failed", 7)
            + lpad("missed", 7) + lpad("leaked", 7) + lpad("over", 5) + lpad("ms", 7))
        for scene in Scene.allCases {
            for (w, h) in sizes {
                let group = outcomes.filter { $0.c.scene == scene && $0.c.w == w }
                guard !group.isEmpty else { continue }
                let real = group.filter { !$0.tiny }
                say(pad(scene.rawValue, 9) + pad("\(w)x\(h)", 11) + lpad("\(real.count)", 6) + lpad("\(group.count - real.count)", 5)
                    + lpad("\(real.filter(\.failed).count)", 7) + lpad("\(real.map(\.missed.count).reduce(0, +))", 7)
                    + lpad("\(real.map(\.leaked.count).reduce(0, +))", 7) + lpad("\(real.filter { !$0.over.isEmpty }.count)", 5)
                    + lpad("\(median(group.map(\.ms)))", 7))
            }
        }
        say("missed and leaked count secrets, over counts cases, ms is the median detect + apply of the group, warm")

        let tiny = outcomes.filter(\.tiny)
        say("")
        say("tiny group (x-height under \(Int(tinyXHeight)) px, reported only): \(tiny.count) cases, \(tiny.filter(\.failed).count) failed, "
            + "\(tiny.map(\.missed.count).reduce(0, +)) secrets missed, \(tiny.map(\.leaked.count).reduce(0, +)) leaked")
        say("time per canvas size, detect + apply, warm, median of every case: "
            + sizes.map { s in "\(s.0)x\(s.1) \(median(outcomes.filter { $0.c.w == s.0 }.map(\.ms))) ms" }.joined(separator: ", "))

        let failing = outcomes.filter { $0.failed && !$0.tiny }
        if !failing.isEmpty { say("") }
        for o in failing { say("FAIL  \(o.c.name)  " + o.details) }
        let tinyFailing = tiny.filter(\.failed)
        if !tinyFailing.isEmpty { say("") }
        for o in tinyFailing { say("tiny  \(o.c.name)  " + o.details) }

        say("")
        say("\(outcomes.count) cases run, \(pruned) pruned (text does not fit the canvas, or a pane under 50 columns), "
            + String(format: "%.0f s", total))
        say(failing.isEmpty ? "BENCH  all passed" : "BENCH  \(failing.count) failed")
        if let reportPath {
            try? report.joined(separator: "\n").appending("\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        }
        return failing.isEmpty ? 0 : 1
    }

    /// Four cases from the matrix for the selftest, one per scene, judged the same way as in `run`.
    static func selfCheck() -> [(name: String, ok: Bool, detail: String)] {
        let picks = ["terminal 1600x1000 Menlo 16px dark", "editor 1280x720 SF Mono 16px light",
                     "chat 1600x1000 SF Pro 18px light", "window 5107x2866 Menlo 16px dark"]
        return cases().enumerated().filter { picks.contains($0.element.name) }.map { i, c in
            autoreleasepool {
                guard let page = build(c, seed: UInt64(i + 1) &* 0x9E37_79B9), let image = page.ctx.makeImage() else {
                    return ("bench case " + c.name, false, "does not fit the canvas")
                }
                let t0 = Date()
                let hits = Redact.detect(in: image)
                let blurred = Redact.apply(hits, to: image) ?? image
                let ms = Date().timeIntervalSince(t0) * 1000
                let o = evaluate(c, page: page, hits: hits, input: image, output: blurred, ms: ms)
                return ("bench case " + c.name, !o.failed, "\(Int(ms)) ms" + (o.failed ? ", " + o.details : ""))
            }
        }
    }

    // MARK: - Matrix

    private enum Scene: String, CaseIterable { case terminal, window, editor, chat }

    private struct Case {
        let scene: Scene
        let w: Int, h: Int
        let font: String
        let px: CGFloat
        let dark: Bool
        var name: String { "\(scene.rawValue) \(w)x\(h) \(font) \(Int(px))px \(dark ? "dark" : "light")" }
    }

    private static let sizes = [(1280, 720), (1600, 1000), (2902, 1842), (3840, 2160), (5107, 2866)]
    /// 9, 11, 13 and 16 pt at 1x and at 2x.
    private static let pixelSizes: [CGFloat] = [9, 11, 13, 16, 18, 22, 26, 32]
    /// Under this x-height a person cannot read the text either. Such cases are reported, never failed.
    private static let tinyXHeight: CGFloat = 7

    /// Font and theme pairs per scene. Not the full cross: each font meets each size, and each scene gets
    /// both themes, but not every font in every theme. Combinations that do not fit the canvas drop out in build.
    private static func cases() -> [Case] {
        let combos: [Scene: [(String, Bool)]] = [
            .terminal: [("Menlo", true), ("SF Mono", false), ("Monaco", true)],
            .window: [("Menlo", true), ("SF Mono", false)],
            .editor: [("SF Mono", false), ("Monaco", false), ("Menlo", true)],
            .chat: [("SF Pro", false), ("Helvetica", true)],
        ]
        var out: [Case] = []
        for scene in Scene.allCases {
            for (w, h) in sizes {
                for px in pixelSizes {
                    for (font, dark) in combos[scene]! { out.append(Case(scene: scene, w: w, h: h, font: font, px: px, dark: dark)) }
                }
            }
        }
        return out
    }

    // MARK: - Secrets and harmless text

    /// Seeded generator, so every run draws the same keys.
    private struct Rand {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func chars(_ n: Int, _ set: String) -> String {
            let a = Array(set)
            return String((0..<n).map { _ in a[Int(next() % UInt64(a.count))] })
        }
    }

    private static let base62 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    /// Built from pieces plus seeded characters, so no string in this file looks like a real key to a scanner.
    private struct Secrets {
        let openai, anthropic, github, aws, stripe, jwt, password, bearer, email, phoneUS, phoneUK, card, hash: String

        init(seed: UInt64) {
            var r = Rand(s: seed)
            openai = "sk-" + "proj-" + r.chars(48, base62)
            anthropic = "sk-" + "ant-" + "api03-" + r.chars(93, base62 + "-_")
            github = "gh" + "p_" + r.chars(36, base62)
            aws = "AK" + "IA" + r.chars(16, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
            stripe = "sk" + "_live_" + r.chars(24, base62)
            func b64(_ s: String) -> String {
                Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            }
            jwt = b64("{\"alg\":\"HS256\",\"typ\":\"JWT\"}") + "." + b64("{\"sub\":\"\(4000 + r.next() % 999)\",\"iat\":1731234567}")
                + "." + r.chars(43, base62 + "-_")
            password = r.chars(1, base62) + r.chars(17, base62 + "!#*-")
            bearer = r.chars(40, base62 + "-._")
            let names = ["jane.doe", "ravi.k", "ops-team", "maya.lin", "billing"]
            email = names[Int(r.next() % 5)] + "@example.com"
            phoneUS = "+1 415 555 01" + r.chars(2, "0123456789")
            phoneUK = "+44 20 7946 0" + r.chars(3, "0123456789")
            card = ["4242 4242 4242 4242", "4111 1111 1111 1111", "5555 5555 5555 4444"][Int(r.next() % 3)]
            hash = r.chars(40, "0123456789abcdef")
        }
    }

    private enum Ink { case text, dim, prompt, path, name, string }

    private enum Piece {
        case plain(String, Ink)
        case secret(String, String, Ink)
    }

    private struct Line {
        var pieces: [Piece]
        var harmless: Bool { !pieces.contains { if case .secret = $0 { return true } else { return false } } }
    }

    private static func line(_ pieces: Piece...) -> Line { Line(pieces: pieces) }
    private static func plain(_ s: String, _ ink: Ink = .text) -> Line { Line(pieces: [.plain(s, ink)]) }

    private static let prompt: [Piece] = [.plain("dev@mac", .prompt), .plain(" ~/code/app", .path), .plain(" (main) $ ", .dim)]

    /// The terminal from the real failure, plus more key types. Secrets sit at line start, after
    /// `export NAME=`, mid-line, at the end of long lines, and the Anthropic key is long enough to wrap.
    private static func terminalLines(_ k: Secrets) -> [Line] {
        [
            Line(pieces: prompt + [.plain("cat .env.local", .text)]),
            line(.plain("export OPENAI_API_KEY=", .text), .secret("openai", k.openai, .text)),
            line(.plain("GITHUB_TOKEN=", .text), .secret("github", k.github, .text)),
            line(.plain("ANTHROPIC_API_KEY=", .text), .secret("anthropic", k.anthropic, .text)),
            line(.plain("PASSWORD=", .text), .secret("password", k.password, .text)),
            line(.plain("CONTACT_EMAIL=", .text), .secret("email", k.email, .text)),
            Line(pieces: prompt + [.plain("cat ~/keys/deploy.csv", .text)]),
            line(.secret("aws", k.aws, .text), .plain(",us-east-1,deploy-bot,2026-11-10", .text)),
            Line(pieces: prompt + [.plain("curl -s https://api.example.com/v1/orders?limit=20 -H \"Authorization: Bearer ", .text),
                                   .secret("bearer", k.bearer, .text), .plain("\"", .text)]),
            line(.plain("Support line: ", .text), .secret("phone", k.phoneUS, .text), .plain(" (weekdays)", .text)),
            Line(pieces: prompt + [.plain("git log -1", .text)]),
            plain("commit " + k.hash, .string),
            plain("Date:   Tue Nov 10 14:32:05 2026 +0530"),
            plain("    Bump version to 14.2.1 (build 23C71)"),
            line(.plain("[2026-11-10 14:32:07] billing: charging customer 4821 with ", .text), .secret("stripe", k.stripe, .text)),
            line(.plain("session ok, token=", .text), .secret("jwt", k.jwt, .text)),
            Line(pieces: prompt + [.plain("ping -c 1 192.168.1.20", .text)]),
            plain("64 bytes from 192.168.1.20: icmp_seq=0 ttl=64 time=3.412 ms"),
            plain("request-id 123e4567-e89b-12d3-a456-426614174000"),
            plain("open https://github.com/apple/swift/blob/main/README.md"),
            plain("/Users/dev/Projects/app/Sources/Redact.swift  512 MB  42 files"),
            Line(pieces: prompt),
        ]
    }

    /// The right-hand pane of the 5107 px shot: the five secrets of the real report, then harmless output.
    private static func windowTerminalLines(_ k: Secrets) -> [Line] {
        [
            Line(pieces: prompt + [.plain("cat .env.local", .text)]),
            line(.plain("export OPENAI_API_KEY=", .text), .secret("openai", k.openai, .text)),
            line(.plain("GITHUB_TOKEN=", .text), .secret("github", k.github, .text)),
            line(.plain("AWS_ACCESS_KEY_ID=", .text), .secret("aws", k.aws, .text)),
            line(.plain("CONTACT_EMAIL=", .text), .secret("email", k.email, .text)),
            line(.plain("SUPPORT_PHONE=", .text), .secret("phone", k.phoneUS, .text)),
            Line(pieces: prompt + [.plain("git log -1", .text)]),
            plain("commit " + k.hash, .string),
            plain("Date:   Tue Nov 10 14:32:05 2026 +0530"),
            plain("    Bump version to 14.2.1 (build 23C71)"),
            Line(pieces: prompt + [.plain("ping -c 1 192.168.1.20", .text)]),
            plain("64 bytes from 192.168.1.20: icmp_seq=0 ttl=64 time=3.412 ms"),
            plain("request-id 123e4567-e89b-12d3-a456-426614174000"),
            Line(pieces: prompt),
        ]
    }

    private static func envLines(_ k: Secrets) -> [Line] {
        func kv(_ name: String, _ value: String, _ label: String?, quoted: Bool = false) -> Line {
            var p: [Piece] = [.plain(name, .name), .plain(quoted ? "=\"" : "=", .text)]
            p.append(label.map { .secret($0, value, .string) } ?? .plain(value, .string))
            if quoted { p.append(.plain("\"", .text)) }
            return Line(pieces: p)
        }
        return [
            plain("# Local development settings, do not commit", .dim),
            kv("NODE_ENV", "development", nil),
            kv("APP_URL", "https://staging.example.com/app", nil),
            kv("OPENAI_API_KEY", k.openai, "openai", quoted: true),
            kv("STRIPE_SECRET_KEY", k.stripe, "stripe"),
            kv("AWS_ACCESS_KEY_ID", k.aws, "aws"),
            kv("AWS_REGION", "us-east-1", nil),
            kv("DATABASE_PASSWORD", k.password, "password"),
            kv("GITHUB_TOKEN", k.github, "github"),
            kv("KEY_PATH", "/Users/dev/.ssh/id_ed25519", nil),
            kv("JWT_TOKEN", k.jwt, "jwt"),
            kv("ADMIN_EMAIL", k.email, "email"),
            kv("SUPPORT_PHONE", k.phoneUK, "phone", quoted: true),
            kv("BUILD_SHA", k.hash, nil),
            kv("RELEASE", "v14.2.1", nil),
            kv("LOG_PATH", "/var/log/app/server.log", nil),
            kv("DB_HOST", "10.0.4.17", nil),
            kv("SESSION_ID", "123e4567-e89b-12d3-a456-426614174000", nil),
            plain(""),
            plain("# Updated 2026-11-10 14:32 by the deploy script", .dim),
        ]
    }

    /// (sender, body) pairs. Email, phone, card and keys sit inside sentences.
    private static func chatMessages(_ k: Secrets) -> [(String, Line)] {
        [
            ("Maya  10:42", plain("Morning! Staging is green again. Version 14.2.1 went out at 10:30 and https://status.example.com shows no errors since then.")),
            ("Ravi  10:44", line(.plain("Thanks. If anyone needs access today, write to ", .text), .secret("email", k.email, .text),
                                 .plain(" or call me on ", .text), .secret("phone", k.phoneUK, .text), .plain(" after lunch.", .text))),
            ("Maya  10:47", line(.plain("For the billing test I used the card ", .text), .secret("card", k.card, .text),
                                 .plain(" with any future expiry date, and this key: ", .text), .secret("openai", k.openai, .text),
                                 .plain(" which I will rotate tonight.", .text))),
            ("Ravi  10:49", plain("The meeting moved to Thursday 14 November at 3:30 pm. Notes are in /Users/dev/Documents/notes/pilot.md as usual.")),
            ("Maya  10:52", line(.plain("The US number for the pilot is ", .text), .secret("phoneUS", k.phoneUS, .text),
                                 .plain(". The deploy bot still sends Authorization: Bearer ", .text), .secret("bearer", k.bearer, .text),
                                 .plain(" on every call, so please swap it.", .text))),
            ("Ravi  10:55", plain("Done. Build 23C71 is on 10.0.4.17 now, commit " + String(k.hash.prefix(12)) + ", and the old box is off.")),
        ]
    }

    private static let chatParagraphs = [
        "Can you check why the deploy failed on staging last night? The log is in /var/log/app/deploy.log and the run started at 23:14.",
        "The build for version 14.2.1 failed at the test step. Commit 3f9a1c2 changed the date parser, and two tests in DateTests.swift expect the old format.",
        "I reverted that change on a branch called fix/date-parser and pushed it. The pipeline at https://ci.example.com/runs/4821 is green now.",
        "Next I will rerun the migration on 10.0.4.17 and watch the response times for an hour, then post the numbers here.",
    ]

    // MARK: - Drawing

    private struct Theme {
        let dark: Bool
        func rgb(_ d: (CGFloat, CGFloat, CGFloat), _ l: (CGFloat, CGFloat, CGFloat)) -> CGColor {
            let c = dark ? d : l
            return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        var desktop: CGColor { rgb((0.16, 0.18, 0.24), (0.78, 0.82, 0.88)) }
        var pane: CGColor { rgb((0.11, 0.12, 0.14), (0.99, 0.99, 0.98)) }
        var bar: CGColor { rgb((0.19, 0.20, 0.23), (0.91, 0.91, 0.92)) }
        var side: CGColor { rgb((0.15, 0.16, 0.19), (0.95, 0.95, 0.96)) }
        var chat: CGColor { rgb((0.13, 0.14, 0.17), (1, 1, 1)) }
        var line: CGColor { rgb((0.25, 0.26, 0.30), (0.84, 0.84, 0.86)) }
        func ink(_ i: Ink) -> CGColor {
            switch i {
            case .text: return rgb((0.85, 0.87, 0.84), (0.13, 0.14, 0.16))
            case .dim: return rgb((0.52, 0.55, 0.60), (0.50, 0.52, 0.56))
            case .prompt: return rgb((0.45, 0.80, 0.50), (0.10, 0.50, 0.20))
            case .path: return rgb((0.45, 0.65, 0.95), (0.10, 0.35, 0.75))
            case .name: return rgb((0.80, 0.60, 0.95), (0.55, 0.20, 0.60))
            case .string: return rgb((0.90, 0.75, 0.50), (0.60, 0.35, 0.05))
            }
        }
    }

    /// One drawn row of text. Indices are UTF-16 offsets into the logical line it came from.
    private struct Row {
        let text: String
        let range: NSRange
        /// Ink box of each glyph, top-left pixels, by string index. Spaces have none.
        let ink: [Int: CGRect]
        let harmless: Bool
    }

    private struct Truth {
        let label: String
        /// Row index and the string range of the secret value on that row.
        var segments: [(row: Int, range: NSRange)]
    }

    private final class Page {
        let w: Int, h: Int
        let ctx: CGContext
        let theme: Theme
        var rows: [Row] = []
        var truths: [Truth] = []

        init?(w: Int, h: Int, theme: Theme) {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            self.w = w; self.h = h; self.ctx = ctx; self.theme = theme
            // Screen text: antialiased and smoothed, on an opaque background.
            ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(true); ctx.setShouldSmoothFonts(true)
            ctx.setAllowsFontSubpixelPositioning(true); ctx.setShouldSubpixelPositionFonts(true)
            ctx.textMatrix = .identity
        }

        /// `r` is top-left pixels.
        func fill(_ r: CGRect, _ color: CGColor, radius: CGFloat = 0) {
            let f = CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height)
            ctx.setFillColor(color)
            if radius > 0 {
                ctx.addPath(CGPath(roundedRect: f, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            } else {
                ctx.fill(f)
            }
        }

        func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor) {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: x - r, y: CGFloat(h) - y - r, width: r * 2, height: r * 2))
        }

        /// Draws one logical line from `y` down, wrapped to `width`: by character for monospaced text, as a
        /// terminal does, by word otherwise. Returns false, without drawing that row, when a row would cross `bottom`.
        func text(_ line: Line, font: CTFont, x: CGFloat, y: inout CGFloat, width: CGFloat, lineHeight: CGFloat,
                  bottom: CGFloat, mono: Bool) -> Bool {
            let s = NSMutableAttributedString()
            var secrets: [(String, NSRange)] = []
            for piece in line.pieces {
                let str: String, ink: Ink, label: String?
                switch piece {
                case let .plain(a, i): (str, ink, label) = (a, i, nil)
                case let .secret(l, a, i): (str, ink, label) = (a, i, l)
                }
                let start = s.length
                s.append(NSAttributedString(string: str, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): theme.ink(ink),
                    NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
                ]))
                if let label { secrets.append((label, NSRange(location: start, length: s.length - start))) }
            }
            guard s.length > 0 else {
                y += lineHeight
                return y <= bottom
            }
            let full = s.string as NSString
            let ts = CTTypesetterCreateWithAttributedString(s)
            let cols = max(1, Int(width / RedactBench.advance(font)))
            var slices: [NSRange] = []
            var start = 0
            while start < s.length {
                let n = mono ? min(cols, s.length - start) : max(1, CTTypesetterSuggestLineBreak(ts, start, Double(width)))
                slices.append(NSRange(location: start, length: n))
                start += n
            }
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            let first = rows.count
            for slice in slices {
                guard y + lineHeight <= bottom else { return false }
                let ctLine = CTTypesetterCreateLine(ts, CFRange(location: slice.location, length: slice.length))
                let baseline = (y + (lineHeight - ascent - descent) / 2 + ascent).rounded()
                ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - baseline)
                CTLineDraw(ctLine, ctx)

                var ink: [Int: CGRect] = [:]
                for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
                    let n = CTRunGetGlyphCount(run)
                    guard n > 0 else { continue }
                    var glyphs = [CGGlyph](repeating: 0, count: n)
                    var pos = [CGPoint](repeating: .zero, count: n)
                    var idx = [CFIndex](repeating: 0, count: n)
                    var boxes = [CGRect](repeating: .zero, count: n)
                    CTRunGetGlyphs(run, CFRange(), &glyphs)
                    CTRunGetPositions(run, CFRange(), &pos)
                    CTRunGetStringIndices(run, CFRange(), &idx)
                    let attrs = CTRunGetAttributes(run) as NSDictionary
                    let runFont = attrs[kCTFontAttributeName as String] as! CTFont
                    CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, glyphs, &boxes, n)
                    for g in 0..<n where boxes[g].width > 0 && boxes[g].height > 0 {
                        let b = boxes[g]
                        let r = CGRect(x: x + pos[g].x + b.minX, y: baseline - pos[g].y - b.maxY, width: b.width, height: b.height)
                        ink[idx[g]] = ink[idx[g]].map { $0.union(r) } ?? r
                    }
                }
                rows.append(Row(text: full.substring(with: slice), range: slice, ink: ink, harmless: line.harmless))
                y += lineHeight
            }
            for (label, range) in secrets {
                var t = Truth(label: label, segments: [])
                for i in first..<rows.count {
                    let cut = NSIntersectionRange(rows[i].range, range)
                    if cut.length > 0 { t.segments.append((i, cut)) }
                }
                truths.append(t)
            }
            return true
        }
    }

    private static func makeFont(_ name: String, _ px: CGFloat) -> CTFont {
        switch name {
        case "SF Mono": return NSFont.monospacedSystemFont(ofSize: px, weight: .regular) as CTFont
        case "SF Pro": return NSFont.systemFont(ofSize: px) as CTFont
        default: return CTFontCreateWithName(name as CFString, px, nil)
        }
    }

    private static func advance(_ font: CTFont) -> CGFloat {
        var ch: [UniChar] = Array("0".utf16)
        var g: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(font, &ch, &g, 1)
        return CGFloat(CTFontGetAdvancesForGlyphs(font, .horizontal, &g, nil, 1))
    }

    // MARK: - Scenes

    /// Nil when the scene does not fit the canvas at this text size.
    private static func build(_ c: Case, seed: UInt64) -> Page? {
        let theme = Theme(dark: c.dark)
        guard let page = Page(w: c.w, h: c.h, theme: theme) else { return nil }
        let W = CGFloat(c.w), H = CGFloat(c.h)
        let s = c.px / 13 // window chrome scales with the text, as it does on a Retina screen
        let k = Secrets(seed: seed)
        let font = makeFont(c.font, c.px)
        let ui = makeFont("SF Pro", c.px)
        let adv = advance(font)
        let pad = (10 * s).rounded()
        var harmlessY: CGFloat = 0
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ ink: Ink = .dim) {
            harmlessY = y
            _ = page.text(plain(text, ink), font: ui, x: x, y: &harmlessY, width: 10000, lineHeight: (c.px * 1.4).rounded(),
                          bottom: H, mono: false)
        }
        func lights(_ x: CGFloat, _ y: CGFloat) {
            for (i, col) in [(0.99, 0.37, 0.34), (0.99, 0.74, 0.18), (0.16, 0.78, 0.25)].enumerated() {
                page.dot(x + CGFloat(i) * 20 * s, y, 6 * s, CGColor(srgbRed: col.0, green: col.1, blue: col.2, alpha: 1))
            }
        }

        switch c.scene {
        case .terminal:
            let m = (24 * s).rounded(), bar = (28 * s).rounded(), lh = (c.px * 1.3).rounded()
            let cols = min(Int((W - 2 * m - 2 * pad) / adv), 110)
            guard cols >= 50 else { return nil }
            let win = CGRect(x: m, y: m, width: CGFloat(cols) * adv + 2 * pad, height: H - 2 * m)
            page.fill(CGRect(x: 0, y: 0, width: W, height: H), theme.desktop)
            page.fill(win, theme.pane, radius: 10 * s)
            page.fill(CGRect(x: win.minX, y: win.minY, width: win.width, height: bar), theme.bar)
            lights(win.minX + 16 * s, win.minY + bar / 2)
            label("dev - zsh - \(cols)x40", win.midX - 60 * s, win.minY + (bar - c.px * 1.4) / 2)
            var y = win.minY + bar + pad
            for l in terminalLines(k) {
                guard page.text(l, font: font, x: win.minX + pad, y: &y, width: CGFloat(cols) * adv + adv / 2, lineHeight: lh,
                                bottom: win.maxY - pad, mono: true) else { return nil }
            }

        case .window:
            // An IDE or agent app filling the screen: sidebar, chat column, terminal on the right.
            let bar = (30 * s).rounded(), lh = (c.px * 1.3).rounded()
            let side = max(W * 0.14, 170 * s)
            let paneW = min(max(100 * adv + 2 * pad, W / 3), W * 0.55)
            let cols = Int((paneW - 2 * pad) / adv)
            let chatW = W - side - paneW
            guard cols >= 50, chatW >= 280 * s else { return nil }
            page.fill(CGRect(x: 0, y: 0, width: W, height: H), theme.chat)
            page.fill(CGRect(x: 0, y: 0, width: W, height: bar), theme.bar)
            page.fill(CGRect(x: 0, y: bar, width: side, height: H - bar), theme.side)
            page.fill(CGRect(x: W - paneW, y: bar, width: paneW, height: H - bar), theme.pane)
            page.fill(CGRect(x: W - paneW - 1, y: bar, width: 1, height: H - bar), theme.line)
            lights(16 * s, bar / 2)
            label("app - Fix the deploy", W / 2 - 80 * s, (bar - c.px * 1.4) / 2)
            var y = bar + 14 * s
            for t in ["Chats", "Today", "Fix the deploy", "Date parser tests", "Yesterday", "Release notes 14.2", "Landing page copy", "Settings"] {
                label(t, 16 * s, y, t == "Today" || t == "Yesterday" ? .dim : .text)
                y += (c.px * 1.9).rounded()
            }
            y = bar + 20 * s
            let chatFont = makeFont("SF Pro", c.px * 1.05)
            var n = 0
            fill: while true {
                let who = n % 2 == 0 ? "You" : "Assistant"
                guard page.text(plain(who, .name), font: ui, x: side + 24 * s, y: &y, width: chatW - 48 * s,
                                lineHeight: (c.px * 1.5).rounded(), bottom: H - 16 * s, mono: false) else { break fill }
                guard page.text(plain(chatParagraphs[n % chatParagraphs.count]), font: chatFont, x: side + 24 * s, y: &y,
                                width: chatW - 48 * s, lineHeight: (c.px * 1.55).rounded(), bottom: H - 16 * s,
                                mono: false) else { break fill }
                y += c.px
                n += 1
            }
            y = bar + pad
            for l in windowTerminalLines(k) {
                guard page.text(l, font: font, x: W - paneW + pad, y: &y, width: CGFloat(cols) * adv + adv / 2, lineHeight: lh,
                                bottom: H - pad, mono: true) else { return nil }
            }

        case .editor:
            let bar = (34 * s).rounded(), lh = (c.px * 1.45).rounded()
            let tree = max(W * 0.15, 190 * s)
            let gutter = adv * 5
            let codeX = tree + gutter + pad
            let cols = min(Int((W - codeX - pad) / adv), 120)
            guard cols >= 50 else { return nil }
            page.fill(CGRect(x: 0, y: 0, width: W, height: H), theme.pane)
            page.fill(CGRect(x: 0, y: 0, width: tree, height: H), theme.side)
            page.fill(CGRect(x: tree, y: 0, width: W - tree, height: bar), theme.bar)
            page.fill(CGRect(x: tree, y: 0, width: 120 * s, height: bar), theme.pane)
            label(".env", tree + 16 * s, (bar - c.px * 1.4) / 2, .text)
            var y = 14 * s
            for t in ["APP", ".env", "Package.swift", "README.md", "Sources", "  Redact.swift", "  main.swift", "build.sh"] {
                label(t, 14 * s, y, t == "APP" ? .dim : .text)
                y += (c.px * 1.8).rounded()
            }
            y = bar + pad
            for (i, l) in envLines(k).enumerated() {
                var ny = y
                guard page.text(plain(String(format: "%3d", i + 1), .dim), font: font, x: tree + pad, y: &ny, width: gutter,
                                lineHeight: lh, bottom: H - pad, mono: true),
                      page.text(l, font: font, x: codeX, y: &y, width: CGFloat(cols) * adv + adv / 2, lineHeight: lh,
                                bottom: H - pad, mono: true) else { return nil }
            }

        case .chat:
            let bar = (44 * s).rounded(), lh = (c.px * 1.45).rounded()
            let side = max(W * 0.16, 180 * s)
            let x = side + 28 * s
            let colW = min(W - x - 28 * s, c.px * 40)
            guard colW >= 300 * s else { return nil }
            page.fill(CGRect(x: 0, y: 0, width: W, height: H), theme.chat)
            page.fill(CGRect(x: 0, y: 0, width: side, height: H), theme.side)
            page.fill(CGRect(x: side, y: bar - 1, width: W - side, height: 1), theme.line)
            label("# release", x, (bar - c.px * 1.4) / 2, .text)
            var y = 16 * s
            for t in ["Channels", "# general", "# release", "# billing", "# random", "Direct", "Maya", "Ravi"] {
                label(t, 16 * s, y, t == "Channels" || t == "Direct" ? .dim : .text)
                y += (c.px * 1.9).rounded()
            }
            y = bar + 16 * s
            for (who, body) in chatMessages(k) {
                guard page.text(plain(who, .name), font: font, x: x, y: &y, width: colW, lineHeight: lh, bottom: H - 16 * s,
                                mono: false),
                      page.text(body, font: font, x: x, y: &y, width: colW, lineHeight: lh, bottom: H - 16 * s,
                                mono: false) else { return nil }
                y += (c.px * 0.8).rounded()
            }
        }
        return page
    }

    // MARK: - Scoring

    private struct Outcome {
        let c: Case
        let tiny: Bool
        let ms: Double
        var missed: [String] = []
        var leaked: [String] = []
        var over: [String] = []
        var notes: [String] = []
        var failed: Bool { !missed.isEmpty || !leaked.isEmpty || !over.isEmpty }
        var details: String {
            (missed.map { "\($0) MISSED" } + leaked + over + notes).joined(separator: " | ")
        }
    }

    /// Thresholds. A character leaks when any pixel of its ink box sits outside every hit rect, or when the
    /// pixel check finds more than 30% of the glyph's edge energy still in the output.
    private static let edgeShare = 0.3
    /// A harmless row fails when more than half its characters are blurred. A secret fails when more than
    /// this many characters left of its value are blurred.
    private static let maxLeftOver = 6

    private static func evaluate(_ c: Case, page: Page, hits: [Redact.Hit], input: CGImage, output: CGImage, ms: Double) -> Outcome {
        let xh = CTFontGetXHeight(makeFont(c.font, c.px))
        var o = Outcome(c: c, tiny: xh < tinyXHeight, ms: ms)
        let rects = hits.map(\.rect)
        let w = page.w, h = page.h
        guard let a = rgba(input), let b = rgba(output) else {
            o.leaked.append("could not read pixels")
            return o
        }
        var valueChars = Set<Int>() // row << 20 | index
        for t in page.truths { for seg in t.segments { for i in seg.range.location..<NSMaxRange(seg.range) { valueChars.insert(seg.row << 20 | i) } } }

        for t in page.truths {
            let chars: [(row: Int, i: Int, box: CGRect)] = t.segments.flatMap { seg in
                (seg.range.location..<NSMaxRange(seg.range)).compactMap { i in page.rows[seg.row].ink[i].map { (seg.row, i, $0) } }
            }
            guard !chars.isEmpty else { continue }
            if !chars.contains(where: { ch in rects.contains { $0.intersects(ch.box) } }) {
                o.missed.append(t.label)
                continue
            }
            var flags: [Bool] = []
            var byRect = 0, byPixel = 0
            for ch in chars {
                let (cov, tot) = coverage(ch.box, rects)
                let rectBad = cov < tot
                let pixBad = pixelLeak(ch.box, a: a, b: b, w: w, h: h)
                if rectBad { byRect += 1 }
                if pixBad { byPixel += 1 }
                flags.append(rectBad || pixBad)
            }
            // Area of the value, row by row, that no hit covers.
            var open = 0, area = 0
            for seg in t.segments {
                let boxes = (seg.range.location..<NSMaxRange(seg.range)).compactMap { page.rows[seg.row].ink[$0] }
                guard let first = boxes.first else { continue }
                let (cov, tot) = coverage(boxes.dropFirst().reduce(first) { $0.union($1) }, rects)
                open += tot - cov; area += tot
            }
            let bad = flags.filter { $0 }.count
            if bad > 0 {
                let lead = flags.prefix { $0 }.count, tail = flags.reversed().prefix { $0 }.count
                o.leaked.append("\(t.label) \(bad)/\(flags.count) chars visible (first \(lead), last \(tail); "
                    + "rect \(byRect), pixel \(byPixel)), \(area > 0 ? open * 100 / area : 0)% of area open")
            }
            // Characters around the value that a hit also blurs.
            func overCover(_ seg: (row: Int, range: NSRange), left: Bool) -> Int {
                let row = page.rows[seg.row]
                let span = left ? row.range.location..<seg.range.location : NSMaxRange(seg.range)..<NSMaxRange(row.range)
                return span.filter { i in
                    guard !valueChars.contains(seg.row << 20 | i), let box = row.ink[i] else { return false }
                    let (cov, tot) = coverage(box, rects)
                    return cov * 2 >= tot
                }.count
            }
            let left = overCover(t.segments.first!, left: true), right = overCover(t.segments.last!, left: false)
            if left > maxLeftOver { o.over.append("\(t.label) blurs \(left) chars left of the value") }
            if left > 0 || right > 0 { o.notes.append("\(t.label) extra \(left) left, \(right) right") }
        }

        for row in page.rows where row.harmless {
            let boxes = row.ink.values
            guard !boxes.isEmpty else { continue }
            let blurred = boxes.filter { let (cov, tot) = coverage($0, rects); return cov * 2 >= tot }.count
            guard blurred > 0 else { continue }
            let shown = row.text.count > 40 ? String(row.text.prefix(40)) + "..." : row.text
            let msg = "harmless \"\(shown.trimmingCharacters(in: .whitespaces))\" \(blurred * 100 / boxes.count)% blurred"
            if blurred * 2 > boxes.count { o.over.append(msg) } else { o.notes.append(msg) }
        }
        return o
    }

    /// Pixels of `r` (rounded out to whole pixels) whose centre lies in a hit rect, and the pixel total.
    private static func coverage(_ r: CGRect, _ rects: [CGRect]) -> (Int, Int) {
        let x0 = Int(floor(r.minX)), x1 = Int(ceil(r.maxX)), y0 = Int(floor(r.minY)), y1 = Int(ceil(r.maxY))
        let near = rects.filter { $0.intersects(r) }
        var cov = 0
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if near.contains(where: { $0.contains(p) }) { cov += 1 }
            }
        }
        return (cov, max(0, x1 - x0) * max(0, y1 - y0))
    }

    /// Independent of the hit rects: does the glyph's shape survive in the output pixels? Measures the edge
    /// energy (sum of neighbour differences) inside the ink box, output against input. A blurred glyph keeps
    /// almost none; a glyph under the soft fade at a blur's edge keeps it in proportion to how visible it is.
    /// Comparing raw pixel values instead flags glyphs that are blurred fine, because a dense run of light
    /// glyphs blurs into a light patch and a stem pixel can keep nearly its old value.
    private static func pixelLeak(_ r: CGRect, a: [UInt8], b: [UInt8], w: Int, h: Int) -> Bool {
        let x0 = max(0, Int(floor(r.minX)) - 1), x1 = min(w - 1, Int(ceil(r.maxX)) + 1)
        let y0 = max(0, Int(floor(r.minY)) - 1), y1 = min(h - 1, Int(ceil(r.maxY)) + 1)
        guard x1 > x0, y1 > y0 else { return false }
        func lum(_ p: [UInt8], _ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return Double(Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])) / 3
        }
        var ea = 0.0, eb = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                ea += abs(lum(a, x + 1, y) - lum(a, x, y)) + abs(lum(a, x, y + 1) - lum(a, x, y))
                eb += abs(lum(b, x + 1, y) - lum(b, x, y)) + abs(lum(b, x, y + 1) - lum(b, x, y))
            }
        }
        guard ea > 0 else { return false }
        return eb > edgeShare * ea
    }

    /// RGBA bytes in sRGB, rows top-down.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
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
        return ok ? bytes : nil
    }

    /// The blurred image with the secret values outlined in green and the hit rects in red.
    private static func dump(_ image: CGImage, page: Page, hits: [Redact.Hit], px: CGFloat, to path: String) {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func stroke(_ r: CGRect, _ color: CGColor) {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(max(1.5, px / 12))
            ctx.stroke(CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height))
        }
        for t in page.truths {
            for seg in t.segments {
                let boxes = (seg.range.location..<NSMaxRange(seg.range)).compactMap { page.rows[seg.row].ink[$0] }
                guard let first = boxes.first else { continue }
                stroke(boxes.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -1, dy: -1),
                       CGColor(srgbRed: 0.1, green: 0.9, blue: 0.2, alpha: 1))
            }
        }
        for hit in hits { stroke(hit.rect, CGColor(srgbRed: 1, green: 0.15, blue: 0.15, alpha: 1)) }
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Formatting

    private static func median(_ xs: [Double]) -> Int {
        guard !xs.isEmpty else { return 0 }
        return Int(xs.sorted()[xs.count / 2].rounded())
    }

    private static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }
    private static func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? " " + s : String(repeating: " ", count: n - s.count) + s }
}
