import AppKit
import CoreImage
import CoreText
import Vision

/// Auto-blur. Finds sensitive text in a shot and blurs it before the shot reaches the clipboard.
/// Everything runs on this Mac: Vision reads the text, regexes decide, Core Image blurs. No network.
enum Redact {
    enum Kind: String {
        case email, phone, key, token, secret, privateKey, card
    }

    struct Hit: Equatable {
        /// Pixels in the image, origin top left, already padded a little.
        let rect: CGRect
        let kind: Kind
    }

    /// Vision mode. Measured 2026-11-10 on Apple silicon, 1600x1000 dark terminal at 26 px text, warm:
    /// fast reads in about 15 ms, accurate in about 95 ms. Fast boxes each character tightly, but it misreads
    /// text ("example" as "exarnple. com", "555-0137" as "555_0137"), so it missed the email and the phone.
    /// Accurate reads all three and boxes whole words only, which `Line.rect(for:)` cuts down by character
    /// position. Accurate fits the 300 ms budget, so a correct read wins over speed.
    static let level: VNRequestTextRecognitionLevel = .accurate

    // MARK: - Detect

    /// Reads the text with Vision and returns the sensitive regions. Synchronous, safe on a background queue.
    static func detect(in image: CGImage) -> [Hit] {
        detect(in: image, level: level)
    }

    static func detect(in image: CGImage, level: VNRequestTextRecognitionLevel) -> [Hit] {
        let size = CGSize(width: image.width, height: image.height)
        let lines = read(image, level: level)
        guard !lines.isEmpty else { return [] }
        let rightEdge = lines.map(\.rect.maxX).max() ?? size.width

        var hits: [Hit] = []
        var open: [Line] = []
        for line in lines {
            var ranges = sensitiveRanges(in: line.text)
            // A key cut off at the end of this piece: Vision split it, or the terminal wrapped it.
            if let tail = match(trailingPrefix, in: line.text), !ranges.contains(where: { $0.range.overlaps(tail) }) {
                ranges.append((tail, .key))
            }
            for (range, kind) in ranges {
                guard let rect = line.rect(for: range, in: size) else { continue }
                hits.append(Hit(rect: pad(rect, in: size), kind: kind))
                if isSecret(kind), range.upperBound == line.text.endIndex || line.text[range.upperBound...].allSatisfy(\.isWhitespace) {
                    open.append(line)
                }
            }
        }

        // The second piece of a split key: the first word of the piece right after it on the same row,
        // or of the next row when the first piece ran to the right edge (a wrap).
        for first in open {
            let h = first.rect.height
            for next in lines where next.text != first.text || next.rect != first.rect {
                let sameRow = abs(next.rect.midY - first.rect.midY) < h * 0.5
                    && next.rect.minX >= first.rect.maxX - h * 0.5 && next.rect.minX - first.rect.maxX < h * 4
                let wrapped = first.rect.maxX >= rightEdge - h * 2
                    && next.rect.minY > first.rect.minY + h * 0.5 && next.rect.minY < first.rect.maxY + h * 1.2
                    && next.rect.minX < first.rect.minX + h * 2
                guard sameRow || wrapped, let word = match(leadingWord, in: next.text),
                      looksLikeKeyPiece(next.text[word]), let rect = next.rect(for: word, in: size) else { continue }
                hits.append(Hit(rect: pad(rect, in: size), kind: .key))
            }
        }
        return hits
    }

    /// One piece of text Vision found, with its box in top-left pixels.
    struct Line {
        let text: String
        let rect: CGRect
        let candidate: VNRecognizedText

        /// Accurate mode boxes whole words only: a range inside "KEY=sk-..." gets the box of the whole word.
        /// So this takes the box of the words around the range and cuts it by character position, with half
        /// a character to spare on each cut side. Exact for monospaced text, close for other fonts.
        func rect(for range: Range<String.Index>, in size: CGSize) -> CGRect? {
            var lo = range.lowerBound, hi = range.upperBound
            while lo > text.startIndex, !text[text.index(before: lo)].isWhitespace { lo = text.index(before: lo) }
            while hi < text.endIndex, !text[hi].isWhitespace { hi = text.index(after: hi) }
            guard let box = try? candidate.boundingBox(for: lo..<hi)?.boundingBox else { return nil }
            let word = Redact.pixelRect(box, in: size)
            let n = CGFloat(text.distance(from: lo, to: hi))
            guard n > 0 else { return word }
            let a = CGFloat(text.distance(from: lo, to: range.lowerBound))
            let b = CGFloat(text.distance(from: lo, to: range.upperBound))
            let cw = word.width / n
            let x0 = a > 0 ? word.minX + cw * (a - 0.5) : word.minX
            let x1 = b < n ? word.minX + cw * (b + 0.5) : word.maxX
            return CGRect(x: x0, y: word.minY, width: x1 - x0, height: word.height)
        }
    }

    static func read(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        // Language correction "fixes" keys into words and drops characters.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        // Default skips text under 1/32 of the image height, which is a whole terminal line on a small crop.
        request.minimumTextHeight = Float(min(1, 8 / CGFloat(max(image.height, 1))))
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return Line(text: top.string, rect: pixelRect(obs.boundingBox, in: size), candidate: top)
        }
    }

    /// Vision boxes are normalised with the origin bottom left. Hits are pixels with the origin top left.
    static func pixelRect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }

    private static func pad(_ rect: CGRect, in size: CGSize) -> CGRect {
        let h = rect.height
        var rect = rect
        // Text cut by the edge of the shot: Vision boxes only the glyphs it could read, so run to the edge.
        if rect.maxX > size.width - h * 1.5 { rect.size.width = size.width - rect.minX }
        if rect.minX < h * 1.5 { rect.size.width += rect.minX; rect.origin.x = 0 }
        // Vision's box can sit 1 px above the capitals. The blur fades in over its outer few pixels,
        // so the pad must be wider than that fade. Neighbouring lines may overlap; apply handles that.
        return rect.insetBy(dx: -max(4, h * 0.3), dy: -max(4, h * 0.25)).integral
            .intersection(CGRect(origin: .zero, size: size))
    }

    private static func isSecret(_ kind: Kind) -> Bool {
        kind == .key || kind == .token || kind == .secret
    }

    // MARK: - Blur

    /// Created once. Colour management is off, so pixels go in and out as they are.
    private static let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
    ])

    /// Returns a copy with each hit blurred. Same pixel size as the input. Empty hits returns the input.
    /// Each region is pixelated with cells as tall as the text, then blurred, so no glyph shape survives,
    /// and it fades in with soft rounded edges. Pixels outside the hit rects are not touched.
    /// Output is 8 bits per channel in the input's colour space (sRGB when that is not RGB).
    static func apply(_ hits: [Hit], to image: CGImage) -> CGImage? {
        guard !hits.isEmpty else { return image }
        let w = image.width, h = image.height
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: bounds)

        // Each piece carries its own soft-edged alpha and all pieces stack into one layer over the original.
        // Each hit rect is then cut from that one result, so overlapping hits (neighbouring lines) agree
        // on every pixel and show no seam.
        let source = CIImage(cgImage: image)
        var smear = CIImage.empty()
        var rects: [CGRect] = []
        for hit in hits {
            let rect = hit.rect.integral.intersection(bounds)
            guard !rect.isEmpty else { continue }
            // CGContext and Core Image both put the origin bottom left.
            let r = CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height)
            let cell = max(10, min(rect.height, 80))
            let piece = source.cropped(to: r).clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: cell, kCIInputCenterKey: CIVector(x: r.minX, y: r.minY)])
                .applyingGaussianBlur(sigma: cell * 0.6)
                .cropped(to: r)
            let feather = min(max(rect.height * 0.08, 2), 4)
            let radius = min(r.height, r.width) * 0.3
            // No fade on a side that touches the image edge, so a glyph cut by the edge cannot show.
            var shapeRect = r.insetBy(dx: feather, dy: feather)
            let reach = feather + radius
            if r.minX <= 0 { shapeRect.origin.x -= reach; shapeRect.size.width += reach }
            if r.maxX >= CGFloat(w) { shapeRect.size.width += reach }
            if r.minY <= 0 { shapeRect.origin.y -= reach; shapeRect.size.height += reach }
            if r.maxY >= CGFloat(h) { shapeRect.size.height += reach }
            guard let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: shapeRect),
                "inputRadius": radius,
                "inputColor": CIColor.white,
            ])?.outputImage else { continue }
            let mask = shape.applyingGaussianBlur(sigma: feather / 3).cropped(to: r)
            let soft = piece.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
            ])
            smear = soft.composited(over: smear)
            rects.append(r)
        }
        let out = smear.composited(over: source)
        for r in rects {
            guard let patch = context.createCGImage(out, from: r, format: .RGBA8, colorSpace: space) else { continue }
            ctx.draw(patch, in: r)
        }
        return ctx.makeImage()
    }

    // MARK: - Text rules

    private struct Rule {
        let kind: Kind
        let regex: NSRegularExpression
        /// Capture group that holds the sensitive part. 0 is the whole match.
        let group: Int
        let check: ((String) -> Bool)?
    }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// OCR can split one key into chunks with a space between them. A chunk only joins when it has a digit,
    /// so a key followed by an ordinary word does not swallow the word.
    private static let chunks = #"(?: (?=[A-Za-z_\-]*\d)[A-Za-z0-9_\-]{3,})*"#
    /// No letter or digit right before the match.
    private static let start = "(?<![A-Za-z0-9])"

    private static let rules: [Rule] = [
        // -----BEGIN RSA PRIVATE KEY----- and friends. The base64 lines under it fall to the long-token rule.
        Rule(kind: .privateKey, regex: rx(#"-*\s*BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY\s*-*"#), group: 0, check: nil),
        // OpenAI and Anthropic: sk-..., sk-proj-..., sk-ant-api03-...
        Rule(kind: .key, regex: rx(start + #"sk-(?:ant-|proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{16,}"# + chunks), group: 0, check: nil),
        // GitHub tokens.
        Rule(kind: .key, regex: rx(start + #"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"# + chunks), group: 0, check: nil),
        // AWS access key ids. OCR reads the I as 1, l or |.
        Rule(kind: .key, regex: rx(start + #"(?:A[KS][I1l|]A|ABIA|ACCA)[A-Z0-9]{12,20}(?![A-Z0-9])"#), group: 0, check: nil),
        // Google API keys (AIza, I read as 1 or l).
        Rule(kind: .key, regex: rx(start + #"A[I1l|]za[0-9A-Za-z_\-]{20,}"# + chunks), group: 0, check: nil),
        // Slack tokens.
        Rule(kind: .key, regex: rx(start + #"xox[abposre]-[A-Za-z0-9\-]{10,}"#), group: 0, check: nil),
        // Stripe keys and webhook secrets.
        Rule(kind: .key, regex: rx(start + #"(?:(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}|whsec_[A-Za-z0-9]{20,})"# + chunks), group: 0, check: nil),
        // JWTs. Every JWT header starts with eyJ ({" in base64). OCR sometimes drops the dots, so one part is enough.
        Rule(kind: .token, regex: rx(start + #"eyJ[A-Za-z0-9_\-]{10,}(?:\.[A-Za-z0-9_\-]{2,}){0,2}"#), group: 0, check: nil),
        // Bearer xyz, Basic xyz, Authorization: xyz.
        Rule(kind: .token, regex: rx(#"\b(?:bearer|basic)\s+([A-Za-z0-9_\-.=+/~]{12,})"#, .caseInsensitive), group: 1, check: nil),
        Rule(kind: .token, regex: rx(#"authorization["']?\s*[:=]\s*["']?(?:bearer\s+|basic\s+|token\s+)?([^\s"']{12,})"#, .caseInsensitive), group: 1, check: nil),
        // API_KEY=..., client_secret: "...", DB_PASSWORD=... The value side only, 12+ characters, not a path or URL.
        Rule(kind: .secret, regex: rx(
            #"[A-Za-z0-9_.\-]*(?:key|secret|token|passw(?:or)?d|passphrase|pwd|credentials?)[A-Za-z0-9_.\-]*["']?\s*(?::=|=>|=|:)\s*["']?([^\s"'`,;]{12,})"#,
            .caseInsensitive), group: 1, check: { !looksLikePathOrURL($0) }),
        // Card numbers: 13 to 19 digits, spaces or dashes allowed, Luhn valid, a real card prefix.
        Rule(kind: .card, regex: rx(#"(?<![\d.])(?:\d[ \-]?){12,18}\d(?![\d.])"#), group: 0, check: isCard),
        // Long random tokens without a known prefix, and base64 lines of a private key.
        Rule(kind: .token, regex: rx(#"(?<![A-Za-z0-9+/_\-])[A-Za-z0-9+/_\-]{32,}={0,2}(?![A-Za-z0-9+/=_\-])"#), group: 0, check: looksRandom),
    ]

    /// A known key prefix at the very end of a piece, too short for the full rule. Used only by detect.
    private static let trailingPrefix = rx(
        start + #"(?:sk-(?:ant-|proj-)?|gh[pousr]_|github_pat_|A[KS][I1l|]A|A[I1l|]za|xox[abposre]-|(?:sk|rk)_live_|eyJ)[A-Za-z0-9_\-]*$"#)
    /// The first word of a piece, plus chunks with digits that OCR split off with a space.
    private static let leadingWord = rx(#"^\s*([A-Za-z0-9_\-+/=]+"# + chunks + ")")

    /// The rest of a key has a digit or both cases, so "done" or "ls" after a key stays readable.
    private static func looksLikeKeyPiece(_ s: Substring) -> Bool {
        s.count >= 2 && (s.contains(where: \.isNumber) || (s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase)))
    }

    private static func match(_ regex: NSRegularExpression, in text: String) -> Range<String.Index>? {
        let ns = normalized(text)
        guard let m = regex.firstMatch(in: ns, range: NSRange(location: 0, length: (ns as NSString).length)),
              case let r = m.range(at: m.numberOfRanges - 1), r.length > 0 else { return nil }
        return Range(r, in: text)
    }

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
        | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// Pure text check, no image: which ranges of a string are sensitive. Used by detect and by tests.
    static func sensitiveRanges(in text: String) -> [(range: Range<String.Index>, kind: Kind)] {
        let original = text as NSString
        let norm = normalized(text)
        let all = NSRange(location: 0, length: original.length)
        var found: [(NSRange, Kind)] = []

        for rule in rules {
            for m in rule.regex.matches(in: norm, range: all) {
                let r = m.range(at: rule.group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                if let check = rule.check, !check(original.substring(with: r)) { continue }
                found.append((r, rule.kind))
            }
        }
        for m in detector.matches(in: norm, range: all) {
            if m.resultType == .link, m.url?.scheme == "mailto" {
                // "EMAIL=jane@x.com" comes back whole, since = is legal before the @. Keep the address only.
                let s = original.substring(with: m.range)
                let cut = s.lastIndex(where: { $0 == "=" || $0 == ":" }).map { s.utf16.distance(from: s.startIndex, to: $0) + 1 } ?? 0
                found.append((NSRange(location: m.range.location + cut, length: m.range.length - cut), .email))
            } else if m.resultType == .phoneNumber, isPhone(original.substring(with: m.range)) {
                found.append((m.range, .phone))
            }
        }

        // Merge overlaps. The longest match names the kind.
        found.sort { $0.0.location < $1.0.location }
        var spans: [(NSRange, Kind, Int)] = []
        for (r, kind) in found {
            if let last = spans.last, r.location < NSMaxRange(last.0) {
                let end = max(NSMaxRange(last.0), NSMaxRange(r))
                let k = r.length > last.2 ? kind : last.1
                spans[spans.count - 1] = (NSRange(location: last.0.location, length: end - last.0.location), k, max(last.2, r.length))
            } else {
                spans.append((r, kind, r.length))
            }
        }
        return spans.compactMap { span in
            Range(span.0, in: text).map { ($0, span.1) }
        }
    }

    /// Vision's accurate mode sometimes returns Cyrillic or Greek lookalikes ("sk-prоj" with a Cyrillic o),
    /// Ø for zero, and | or \ for l. Mapped to the ASCII they look like.
    private static let lookalikes: [UInt16: UInt16] = {
        let pairs: [(String, String)] = [
            ("АВЕКМНОРСТХУІЈЅ", "ABEKMHOPCTXYIJS"), ("аеорсухіјѕԁ", "aeopcyxijsd"),
            ("ΑΒΕΗΙΚΜΝΟΡΤΧΥΖ", "ABEHIKMNOPTXYZ"), ("οι", "oi"), ("Øø", "0o"),
            // OCR reads a thin l as | or \, which would cut a key in two.
            ("|\\", "ll"),
        ]
        var map: [UInt16: UInt16] = [:]
        for (from, to) in pairs {
            for (f, t) in zip(from.utf16, to.utf16) { map[f] = t }
        }
        return map
    }()

    /// Same UTF-16 length as the input, so ranges line up. Turns OCR's dashes, curly quotes and lookalike letters into ASCII.
    private static func normalized(_ text: String) -> String {
        let units = text.utf16.map { u -> UInt16 in
            if let ascii = lookalikes[u] { return ascii }
            switch u {
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212: return 0x2D
            case 0x2018, 0x2019: return 0x27
            case 0x201C, 0x201D: return 0x22
            default: return u
            }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func looksLikePathOrURL(_ value: String) -> Bool {
        if value.contains("://") || value.hasPrefix("$") || value.hasPrefix("%") || value.hasPrefix("{") { return true }
        if let c = value.first, "/~.".contains(c) { return true }
        return false
    }

    /// At least three character classes, and they switch often. Random keys switch about every other
    /// character. CamelCase names, words and paths switch rarely. Git hashes have no capitals.
    private static func looksRandom(_ s: String) -> Bool {
        if s.hasPrefix("/") || s.contains("//") { return false }
        func cls(_ c: Character) -> Int {
            if c.isNumber { return 0 }
            if c.isUppercase { return 1 }
            if c.isLowercase { return 2 }
            return 3
        }
        let classes = s.map(cls)
        guard classes.contains(0), classes.contains(1), classes.contains(2) else { return false }
        let switches = zip(classes, classes.dropFirst()).filter { $0 != $1 }.count
        return switches * 3 >= s.count
    }

    private static func isCard(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        let first = digits[0]
        if first == 2 {
            let four = digits[0...3].reduce(0) { $0 * 10 + $1 }
            guard (2221...2720).contains(four) else { return false }
        } else if !(3...6).contains(first) {
            return false
        }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// 10 to 15 digits, so dates, sizes and short numbers stay readable. Times and IP addresses are not phones.
    private static func isPhone(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber).count
        guard (10...15).contains(digits), !s.contains(":") else { return false }
        if s.split(separator: ".").count == 4 { return false }
        return true
    }

    // MARK: - Self check

    /// Checks for the app selftest: renders text into an image in code, runs detect + apply, times it.
    static func selfCheck() -> [(name: String, ok: Bool, detail: String)] {
        var out: [(name: String, ok: Bool, detail: String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { out.append((name, ok, detail)) }

        // 1. Text rules.
        for (text, want) in textCases {
            let got = sensitiveRanges(in: text).map { (String(text[$0.range]), $0.kind) }
            let ok: Bool
            if let want {
                ok = got.contains { $0.1 == want.kind && $0.0.contains(want.part) }
            } else {
                ok = got.isEmpty
            }
            let shown = got.map { "\($0.1.rawValue):\($0.0)" }.joined(separator: ", ")
            check("text \(want == nil ? "clean" : want!.kind.rawValue): \(text)", ok, shown.isEmpty ? "no hit" : shown)
        }

        // 2. A rendered terminal.
        let sample = terminalSample()
        let t0 = Date()
        let hits = detect(in: sample.image)
        let blurred = apply(hits, to: sample.image)
        let coldMs = Int(Date().timeIntervalSince(t0) * 1000)

        for (name, line, part, kind) in sample.sensitive {
            guard let want = sample.rect(line, part) else { check("\(name) is blurred", false, "sample text missing"); continue }
            let best = hits.filter { $0.kind == kind || isSecret($0.kind) == isSecret(kind) }
                .map { coverage(of: want, by: $0.rect) }.max() ?? 0
            check("\(name) is blurred", best >= 0.9, "covers \(Int(best * 100))% of the text")
        }
        for line in sample.harmless {
            let band = sample.lineRect(line)
            let bad = hits.filter { $0.rect.intersection(band).height > band.height * 0.3 }
            check("no blur on: \(sample.lines[line])", bad.isEmpty, bad.map { "\($0.kind.rawValue) at \(Int($0.rect.minX))" }.joined(separator: ", "))
        }

        if let blurred {
            let text = read(blurred, level: .accurate).map(\.text).joined(separator: " ")
            let squeezed = text.replacingOccurrences(of: " ", with: "")
            let body = String(sample.key.dropFirst("sk-proj-".count))
            let leaks = stride(from: 0, to: body.count - 6, by: 3).map { i -> String in
                let a = body.index(body.startIndex, offsetBy: i)
                return String(body[a..<body.index(a, offsetBy: 6)])
            }.filter { squeezed.contains($0) }
            check("the key cannot be read after the blur", leaks.isEmpty && !squeezed.contains("sk-proj"),
                  leaks.isEmpty ? "OCR finds no piece of it" : "OCR still reads \(leaks)")
            check("the email cannot be read after the blur", !text.contains("@example"))
            check("blurred image keeps its size", blurred.width == sample.image.width && blurred.height == sample.image.height)
            let changed = changedPixelsOutside(hits.map(\.rect), a: sample.image, b: blurred)
            check("pixels outside the hits are unchanged", changed == 0, "\(changed) changed")
        } else {
            check("apply returns an image", false)
        }

        var warm: [Int] = []
        for _ in 0..<3 {
            let t = Date()
            _ = apply(detect(in: sample.image), to: sample.image)
            warm.append(Int(Date().timeIntervalSince(t) * 1000))
        }
        let warmMs = warm.sorted()[1]
        check("detect + apply under 300 ms when warm", warmMs < 300,
              "\(sample.image.width)x\(sample.image.height), cold \(coldMs) ms, warm \(warmMs) ms, \(level == .accurate ? "accurate" : "fast")")
        return out
    }

    /// Each string with the part that must be found, or nil when nothing should be found.
    /// Keys are built from pieces, so no string here looks like a real key to a secret scanner.
    private static var textCases: [(String, (kind: Kind, part: String)?)] {
        let r = fakeChars(40, seed: 7)
        return [
            ("export OPENAI_API_KEY=\"sk-" + "proj-\(r)\"", (.key, "sk-proj-")),
            ("key: sk-" + "ant-api03-\(r)", (.key, "sk-ant-api03-")),
            ("sk-" + "proj-" + r.prefix(18) + " " + r.dropFirst(18).prefix(10), (.key, String(r.dropFirst(18).prefix(10)))),
            ("token gh" + "p_\(r.prefix(36))", (.key, "ghp_")),
            ("github_" + "pat_11ABCDE\(r)", (.key, "github_pat_")),
            ("aws_access_key_id = AK" + "IA\(fakeUpper(16))", (.key, "AKIA")),
            ("AK" + "lA\(fakeUpper(16)) misread", (.key, "AKlA")),
            ("maps key AI" + "za\(r.prefix(35))", (.key, "AIza")),
            ("SLACK=xo" + "xb-1234567890-\(r.prefix(24))", (.key, "xoxb-")),
            ("stripe sk_" + "live_\(r.prefix(24))", (.key, "sk_live_")),
            ("pk_" + "live_\(r.prefix(24))", (.key, "pk_live_")),
            ("ey" + "JhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.\(r.prefix(30))", (.token, "eyJhbGciOiJIUzI1NiJ9.")),
            ("curl -H \"Authorization: Bearer \(r.prefix(30))\"", (.token, String(r.prefix(30)))),
            ("-----BEGIN OPENSSH PRIVATE KEY-----", (.privateKey, "PRIVATE KEY")),
            ("-----BEGIN RSA PRIVATE KEY-----", (.privateKey, "PRIVATE KEY")),
            ("DATABASE_PASSWORD=Tr0ub4dor-and-3", (.secret, "Tr0ub4dor-and-3")),
            ("client_secret: \"x7Hk2pQ9mZr4Wv8n\"", (.secret, "x7Hk2pQ9mZr4Wv8n")),
            ("NEXTAUTH_SECRET=plainlongvaluehere", (.secret, "plainlongvaluehere")),
            ("card 4242 4242 4242 4242 exp", (.card, "4242 4242 4242 4242")),
            ("5555-5555-5555-4444", (.card, "5555-5555-5555-4444")),
            ("mail jane.doe@example.com now", (.email, "jane.doe@example.com")),
            ("call +1 (415) 555-0137", (.phone, "555-0137")),
            ("+44 20 7946 0958", (.phone, "7946 0958")),
            ("\(r)\(r.prefix(8))", (.token, String(r.prefix(20)))),
            // Harmless.
            ("https://github.com/apple/swift/blob/main/README.md", nil),
            ("/Users/dev/Projects/screenshot-tool/Sources/Redact.swift", nil),
            ("commit 3f9a1c2e7b4d8f6a0e5c9b1d2a7f4e8c6b3d0a91", nil),
            ("Date: 2026-11-10 14:32:05 +0530", nil),
            ("1731234567890 ms since epoch", nil),
            ("Version 14.2.1 (build 23C71), 512 MB, 42 files", nil),
            ("192.168.100.200 port 8080", nil),
            ("KEY_PATH=/Users/dev/.ssh/id_ed25519", nil),
            ("TOKEN_URL=https://auth.example.com/token", nil),
            ("API_KEY=${OPENAI_API_KEY}", nil),
            ("password: short", nil),
            ("risk-assessment and task-runner notes", nil),
            ("NSAccessibilityPostNotificationWithUserInfo2", nil),
            ("uuid 123e4567-e89b-12d3-a456-426614174000", nil),
            ("order 1234567890123 shipped", nil),
            ("Total: 12,345,678.90 USD", nil),
        ]
    }

    // MARK: - Sample images

    /// Text drawn in code. Lines and substrings can be looked up as top-left pixel rects.
    struct Sample {
        let image: CGImage
        let lines: [String]
        let lineRect: (Int) -> CGRect
        let rect: (Int, String) -> CGRect?
        var key = ""
        var sensitive: [(String, Int, String, Kind)] = []
        var harmless: [Int] = []
    }

    static func renderSample(_ lines: [String], dark: Bool = true, fontSize: CGFloat = 26,
                             width: Int = 1600, height: Int = 1000) -> Sample? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1) : CGColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let ink = dark ? CGColor(srgbRed: 0.85, green: 0.87, blue: 0.84, alpha: 1) : CGColor(srgbRed: 0.15, green: 0.16, blue: 0.18, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let left = fontSize, top = fontSize
        let lineHeight = (fontSize * 1.35).rounded()
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), cap = CTFontGetCapHeight(font)
        let ctLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
        for (i, line) in ctLines.enumerated() {
            let baseline = top + CGFloat(i) * lineHeight + ascent
            ctx.textPosition = CGPoint(x: left, y: CGFloat(height) - baseline)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { return nil }
        let lineRect: (Int) -> CGRect = { i in
            CGRect(x: 0, y: top + CGFloat(i) * lineHeight, width: CGFloat(width), height: lineHeight)
        }
        let rect: (Int, String) -> CGRect? = { i, part in
            guard i < lines.count, let r = lines[i].range(of: part) else { return nil }
            let ns = NSRange(r, in: lines[i])
            let x0 = CTLineGetOffsetForStringIndex(ctLines[i], ns.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(ctLines[i], NSMaxRange(ns), nil)
            let baseline = top + CGFloat(i) * lineHeight + ascent
            return CGRect(x: left + x0, y: baseline - cap, width: x1 - x0, height: cap + descent * 0.6)
        }
        return Sample(image: image, lines: lines, lineRect: lineRect, rect: rect)
    }

    /// A dark terminal, 1600x1000 px, 13 pt Menlo at 2x: a fake key, an email, a phone and harmless lines.
    static func terminalSample(dark: Bool = true, fontSize: CGFloat = 26) -> Sample {
        let key = "sk-" + "proj-" + fakeChars(48, seed: 42)
        let lines = [
            "dev@mac ~/code/app (main) $ cat .env.local",
            "export OPENAI_API_KEY=\"\(key)\"",
            "CONTACT_EMAIL=jane.doe@example.com",
            "Support: +1 (415) 555-0137",
            "dev@mac ~/code/app (main) $ git log -1",
            "commit 3f9a1c2e7b4d8f6a0e5c9b1d2a7f4e8c6b3d0a91",
            "Date:   Tue Nov 10 14:32:05 2026 +0530",
            "    Bump version to 14.2.1 (build 23C71)",
            "dev@mac ~/code/app (main) $ open https://github.com/apple/swift/blob/main/README.md",
            "/Users/dev/Projects/screenshot-tool/Sources/Redact.swift  512 MB  42 files",
        ]
        var sample = renderSample(lines, dark: dark, fontSize: fontSize)!
        sample.key = key
        sample.sensitive = [
            ("the API key", 1, key, .key),
            ("the email", 2, "jane.doe@example.com", .email),
            ("the phone number", 3, "+1 (415) 555-0137", .phone),
        ]
        sample.harmless = [0, 4, 5, 6, 7, 8, 9]
        return sample
    }

    /// Made-up base62 characters from a fixed seed, so runs repeat. Not a real key.
    static func fakeChars(_ n: Int, seed: UInt64) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var x = seed &* 6364136223846793005 &+ 1442695040888963407
        return String((0..<n).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return chars[Int((x >> 33) % UInt64(chars.count))]
        })
    }

    private static func fakeUpper(_ n: Int) -> String {
        String(fakeChars(n * 3, seed: 3).filter { $0.isUppercase || $0.isNumber }.prefix(n))
    }

    private static func coverage(of want: CGRect, by got: CGRect) -> CGFloat {
        let i = want.intersection(got)
        return i.isNull ? 0 : (i.width * i.height) / (want.width * want.height)
    }

    /// Counts pixels that differ between a and b outside the rects.
    static func changedPixelsOutside(_ rects: [CGRect], a: CGImage, b: CGImage) -> Int {
        guard let pa = rgba(a), let pb = rgba(b), pa.count == pb.count else { return -1 }
        let w = a.width
        var changed = 0
        for y in 0..<a.height {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if pa[i] == pb[i] && pa[i + 1] == pb[i + 1] && pa[i + 2] == pb[i + 2] { continue }
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if !rects.contains(where: { $0.contains(p) }) { changed += 1 }
            }
        }
        return changed
    }

    /// Top-left-first RGBA bytes.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? bytes : nil
    }
}
