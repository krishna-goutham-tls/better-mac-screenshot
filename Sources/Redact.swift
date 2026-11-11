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

    // MARK: - Detect

    /// Reads the text with Vision and returns the sensitive regions, already checked: each hit was blurred,
    /// read again, and widened until no piece of the secret could be read. Synchronous, safe on a background
    /// queue. The blurred image is kept, so `apply` with the same image and hits returns it without work.
    static func detect(in image: CGImage) -> [Hit] {
        verified(locate(in: image), in: image)
    }

    /// One piece of text Vision found, with its box in top-left pixels of the shot.
    struct Line {
        let text: String
        let rect: CGRect
        let candidate: VNRecognizedText
        /// The tile it was read from, in shot pixels. Vision's boxes are relative to it.
        let tile: CGRect
        let shot: CGSize
        /// Starts or ends at a tile edge inside the shot, so the text may go on in the next tile.
        let cutLeft: Bool, cutRight: Bool

        init(text: String, rect: CGRect, candidate: VNRecognizedText, tile: CGRect, shot: CGSize,
             cutLeft: Bool? = nil, cutRight: Bool? = nil) {
            self.text = text; self.rect = rect; self.candidate = candidate; self.tile = tile; self.shot = shot
            self.cutLeft = cutLeft ?? (tile.minX > 0 && rect.minX < tile.minX + rect.height * 0.6)
            self.cutRight = cutRight ?? (tile.maxX < shot.width && rect.maxX > tile.maxX - rect.height * 0.6)
        }

        /// Accurate mode boxes whole words only: a range inside "KEY=sk-..." gets the box of the whole word.
        func box(_ range: Range<String.Index>) -> CGRect? {
            guard let b = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
            return CGRect(x: tile.minX + b.minX * tile.width, y: tile.minY + (1 - b.maxY) * tile.height,
                          width: b.width * tile.width, height: b.height * tile.height)
        }

        /// The whitespace-delimited token whose box spans x.
        func token(atX x: CGFloat) -> Range<String.Index>? {
            var i = text.startIndex
            while i < text.endIndex {
                if text[i].isWhitespace { i = text.index(after: i); continue }
                var j = i
                while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
                if let b = box(i..<j), x >= b.minX - rect.height * 0.3, x <= b.maxX + rect.height * 0.3 { return i..<j }
                i = j
            }
            return nil
        }

        /// The range grown to whitespace on both sides.
        func token(around range: Range<String.Index>) -> Range<String.Index> {
            var lo = range.lowerBound, hi = range.upperBound
            while lo > text.startIndex, !text[text.index(before: lo)].isWhitespace { lo = text.index(before: lo) }
            while hi < text.endIndex, !text[hi].isWhitespace { hi = text.index(after: hi) }
            return lo..<hi
        }
    }

    /// A sensitive region on its way to becoming a hit.
    struct Found {
        /// The padded blur rect.
        var rect: CGRect
        var kind: Kind
        /// The text Vision read under the hit, to look for again after the blur.
        var secrets: [String]
        /// The text around it on the same line, which may be read after the blur without being a leak.
        var context: [String]
        /// The whole token and the whole line, padded: the fallbacks when a narrow blur still leaks.
        var token: CGRect
        var line: CGRect
    }

    /// Vision settings. Measured 2026-11-11 on an M3: whole shots wider than about 130 times the text height
    /// lose lines (a 5107x2866 shot with 26 px text read 25 of 44 lines and "sk-" as "sK-"), so shots are read
    /// in tiles no wider than about 100 times the text height. Accurate, because fast misreads keys.
    static let level: VNRequestTextRecognitionLevel = .accurate
    /// Tile sides. Below 900 tiles only cost more; above 2400 a misjudged estimate costs lines.
    private static let minTile: CGFloat = 900
    private static let maxTile: CGFloat = 2400
    /// Tile side over text height. Above about 130 Vision starts to drop lines.
    private static let tileRatio: CGFloat = 100

    private static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel = level) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        // Language correction "fixes" keys into words and drops characters.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        // Default skips text under 1/32 of the image height, which is a whole terminal line on a small crop.
        request.minimumTextHeight = Float(min(1, 6 / CGFloat(max(image.height, 1))))
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return request.results ?? []
    }

    /// Reads one image whole. Used by the self check on small samples.
    static func read(_ image: CGImage, level: VNRequestTextRecognitionLevel = level) -> [Line] {
        read(image, tile: CGRect(x: 0, y: 0, width: image.width, height: image.height), level: level)
    }

    /// `strip` reads one row cut out by its ink: no edge filter, and small text drawn twice as large.
    private static func read(_ image: CGImage, tile: CGRect, strip: Bool = false,
                             level: VNRequestTextRecognitionLevel = level) -> [Line] {
        let shot = CGSize(width: image.width, height: image.height)
        guard var crop = tile.size == shot ? image : image.cropping(to: tile) else { return [] }
        if strip, crop.height < 40 {
            // Normalised boxes stay the same at any scale, so the mapping back is unchanged.
            let w = crop.width * 2, h = crop.height * 2
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
            ctx.interpolationQuality = .high
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let big = ctx.makeImage() else { return [] }
            crop = big
        }
        return recognize(crop, level: level).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            let rect = CGRect(x: tile.minX + b.minX * tile.width, y: tile.minY + (1 - b.maxY) * tile.height,
                              width: b.width * tile.width, height: b.height * tile.height)
            // A line cut by the top or bottom of a tile is read badly. The overlap gives it whole to the next tile.
            let edge = max(2, rect.height * 0.1)
            if !strip && tile.minY > 0 && rect.minY < tile.minY + edge { return nil }
            if !strip && tile.maxY < shot.height && rect.maxY > tile.maxY - edge { return nil }
            return Line(text: top.string, rect: rect, candidate: top, tile: tile, shot: shot)
        }
    }

    /// Overlapping square tiles of about `side` pixels. Overlap keeps every line whole in some tile
    /// vertically, and every key prefix plus the name before it whole in some tile horizontally.
    static func tiles(for size: CGSize, side: CGFloat, overlap: CGSize) -> [CGRect] {
        func spans(_ total: CGFloat, _ ov: CGFloat) -> [(CGFloat, CGFloat)] {
            if total <= side * 1.15 { return [(0, total)] }
            let n = Int(((total - side) / (side - ov)).rounded(.up)) + 1
            let step = ((total - side) / CGFloat(n - 1)).rounded(.down)
            return (0..<n).map { i in
                let a = CGFloat(i) * step
                return (a, i == n - 1 ? total - a : side)
            }
        }
        var out: [CGRect] = []
        for (y, h) in spans(size.height, overlap.height) {
            for (x, w) in spans(size.width, overlap.width) {
                out.append(CGRect(x: x, y: y, width: w, height: h).integral)
            }
        }
        return out
    }

    private static func readTiles(_ image: CGImage, _ tiles: [CGRect], level: VNRequestTextRecognitionLevel) -> [Line] {
        if tiles.count == 1 { return read(image, tile: tiles[0], level: level) }
        var out = [[Line]](repeating: [], count: tiles.count)
        let lock = NSLock()
        // Vision runs these mostly one at a time on the Neural Engine; the overlap in CPU work still saves a little.
        DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
            let lines = read(image, tile: tiles[i], level: level)
            lock.lock(); out[i] = lines; lock.unlock()
        }
        return out.flatMap { $0 }
    }

    /// The text height in the shot, from Vision's text rectangle detector: the 10th percentile, so small
    /// text counts. About 5 ms at 1600x1000 and 30 ms at 5107x2866. Nil when it finds no text, which
    /// happens for text under about 12 px.
    static func estimateTextHeight(_ image: CGImage) -> CGFloat? {
        let request = VNDetectTextRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        let heights = (request.results ?? []).map { $0.boundingBox.height * CGFloat(image.height) }.sorted()
        return heights.isEmpty ? nil : heights[heights.count / 10]
    }

    /// Every line in the shot. Tiles sized from the estimated text height; when the read shows smaller
    /// text than the tiles suit, a second pass with tiles sized for the smallest text it saw.
    /// Vision's time goes by the number of lines it reads, about 5 ms a line in accurate mode (measured
    /// 2026-11-11, M3). Fast mode is about three times quicker but misreads keys, so it is not used.
    static func readAll(_ image: CGImage) -> [Line] {
        let size = CGSize(width: image.width, height: image.height)
        let long = max(size.width, size.height)
        let est = estimateTextHeight(image)
        // No estimate: small text or none. 900 px tiles still read 9 px text.
        let side = est.map { min(maxTile, max(minTile, $0 * tileRatio)) } ?? minTile
        let h = est ?? 9
        let first = tiles(for: size, side: side, overlap: CGSize(width: max(200, h * 16), height: max(64, h * 4)))
        var lines = readTiles(image, first, level: level)
        let used = first.map { max($0.width, $0.height) }.max() ?? long
        let heights = lines.filter { $0.text.count >= 4 }.map(\.rect.height).sorted()
        let small = heights.isEmpty ? 9 : heights[heights.count / 10]
        // Recognised line boxes run about 0.8 of the font size, so 130 here is about 105 in font pixels.
        if used / small > tileRatio * 1.3, used > minTile * 1.2 {
            let side = max(minTile, min(used / 1.4, small * tileRatio))
            let more = tiles(for: size, side: side, overlap: CGSize(width: max(200, small * 16), height: max(64, small * 4)))
            lines += readTiles(image, more, level: level)
        }
        return splitMerged(dedupe(lines), in: image)
    }

    /// Tight, small lines sometimes come back as one box over two or three rows, read as nonsense.
    /// Such a box is cut into rows by its ink and each row is read on its own.
    private static func splitMerged(_ lines: [Line], in image: CGImage) -> [Line] {
        let heights = lines.filter { $0.text.count >= 4 }.map(\.rect.height).sorted()
        guard !heights.isEmpty else { return lines }
        let textH = heights[heights.count / 2]
        var out: [Line] = []
        var strips: [CGRect] = []
        for line in lines {
            guard line.rect.height > textH * 1.7,
                  let rows = inkRows(in: line.rect.insetBy(dx: -textH * 2, dy: -textH * 0.3), textH: textH, of: image),
                  rows.count >= 2 else { out.append(line); continue }
            strips += rows
        }
        guard !strips.isEmpty else { return lines }
        var read = [[Line]](repeating: [], count: strips.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: strips.count) { i in
            let r = self.read(image, tile: strips[i], strip: true)
            lock.lock(); read[i] = r; lock.unlock()
        }
        return dedupe(out + read.flatMap { $0 })
    }

    /// The rows of text inside a region, each as a rect with a little margin, found by empty pixel rows.
    private static func inkRows(in region: CGRect, textH: CGFloat, of image: CGImage) -> [CGRect]? {
        guard let g = gray(image, region) else { return nil }
        let (bg, thr) = inkLevel(g)
        let rows = (0..<g.h).map { y in (0..<g.w).contains { abs(Int(g.px[y * g.w + $0]) - bg) > thr } }
        var out: [CGRect] = []
        var y = 0
        while y < g.h {
            while y < g.h && !rows[y] { y += 1 }
            let a = y
            while y < g.h && rows[y] { y += 1 }
            let hgt = CGFloat(y - a)
            if hgt > textH * 0.4 && hgt < textH * 2 {
                let m = max(3, textH * 0.25)
                out.append(CGRect(x: g.origin.x, y: g.origin.y + CGFloat(a) - m, width: CGFloat(g.w), height: hgt + m * 2)
                    .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
            }
        }
        return out
    }

    /// Overlapping tiles read the same line twice. A line whose span sits inside another line's span on the
    /// same row is dropped; the longer read wins.
    private static func dedupe(_ lines: [Line]) -> [Line] {
        let sorted = lines.sorted { $0.rect.width > $1.rect.width }
        var kept: [Line] = []
        for line in sorted {
            let h = line.rect.height
            let inside = kept.contains { k in
                let v = min(line.rect.maxY, k.rect.maxY) - max(line.rect.minY, k.rect.minY)
                return v > min(h, k.rect.height) * 0.6
                    && line.rect.minX >= k.rect.minX - h * 0.5 && line.rect.maxX <= k.rect.maxX + h * 0.5
            }
            if !inside { kept.append(line) }
        }
        return kept.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    /// Reads the shot and finds the sensitive regions, placed on the pixels. Not yet checked after a blur.
    static func locate(in image: CGImage) -> [Found] {
        let size = CGSize(width: image.width, height: image.height)
        let lines = readAll(image)
        guard !lines.isEmpty else { return [] }
        // Vision's line boxes are sometimes much taller than the text. The usual height keeps the rows apart.
        let heights = lines.filter { $0.text.count >= 4 }.map(\.rect.height).sorted()
        let textH = heights.isEmpty ? lines[0].rect.height : heights[heights.count / 2]
        let spans = lines.indices.map { rowSpan($0, lines) }

        var found: [Found] = []
        // Lines whose last value may go on in the next piece, with the x where the value starts.
        var open: [(Int, Kind, CGFloat)] = []
        // "Bearer" or "API_KEY=" ends a piece and Vision did not read the value right of it: blur that ink.
        func inkAfter(_ i: Int, _ kind: Kind) {
            let line = lines[i]
            guard !lines.contains(where: { abs($0.rect.midY - line.rect.midY) < line.rect.height * 0.5
                && $0.rect.minX > line.rect.maxX - line.rect.height * 0.5 && $0.rect.minX < line.rect.maxX + line.rect.height * 1.5 }),
                let r = inkRun(rightOf: line.rect, textH: textH, in: image) else { return }
            let p = pad(r, h: r.height, in: size)
            found.append(Found(rect: p, kind: kind, secrets: [], context: [], token: p, line: p))
        }
        for (i, line) in lines.enumerated() {
            var ranges = sensitiveRanges(in: line.text)
            // A key cut off at the end of this piece: Vision split it, the terminal wrapped it, or a tile cut it.
            if let tail = match(trailingPrefix, in: line.text), !ranges.contains(where: { $0.range.overlaps(tail) }) {
                ranges.append((tail, .key))
            }
            // "API_KEY=" or "Bearer" with nothing after it in this piece: the value is in the next piece, on the
            // next row, or not read at all.
            let assign = matchGroup(trailingAssign, in: line.text), bearer = matchGroup(trailingBearer, in: line.text)
            if assign?.isEmpty == true { open.append((i, .secret, line.rect.maxX)); inkAfter(i, .secret) }
            if bearer?.isEmpty == true { open.append((i, .token, line.rect.maxX)); inkAfter(i, .token) }
            // "API_KEY=sk-pr" or "jane@exam" with the rest cut by a tile edge or a wrap: it goes on in the next piece.
            if line.cutRight || reachesColumnEnd(i, lines, spans) || line.rect.maxX > size.width - line.rect.height * 2 {
                if let m = assign, !m.isEmpty, !ranges.contains(where: { $0.range.overlaps(m) }) { ranges.append((m, .secret)) }
                // "dev@mac" cut by a tile edge is a shell prompt; the other tile reads a real address whole.
                if let m = match(trailingEmail, in: line.text), !ranges.contains(where: { $0.range.overlaps(m) }),
                   line.text[m].contains("."), !line.cutRight || line.text[m].split(separator: "@").last?.contains(".") == true {
                    ranges.append((m, .email))
                }
                // "+1 (415) 555-01" with the last digits on the next row.
                if let m = match(trailingPhone, in: line.text), line.text[m].filter(\.isNumber).count >= 7,
                   !ranges.contains(where: { $0.range.overlaps(m) }) {
                    ranges.append((m, .phone))
                }
                if let m = bearer, !m.isEmpty, !ranges.contains(where: { $0.range.overlaps(m) }) { ranges.append((m, .token)) }
            }
            for (found0, kind) in ranges {
                // A secret runs on to the end of its token: a misread character in the middle of a key
                // ends the regex match, not the key.
                var range = found0
                if isSecret(kind) {
                    var hi = range.upperBound
                    while hi < line.text.endIndex, !line.text[hi].isWhitespace, !"\"'`,;)]}>".contains(line.text[hi]) {
                        hi = line.text.index(after: hi)
                    }
                    range = range.lowerBound..<hi
                }
                guard let f = place(line, range, kind: kind, textH: textH, in: image) else { continue }
                found.append(f)
                if line.text[range.upperBound...].allSatisfy(\.isWhitespace) { open.append((i, kind, f.rect.minX)) }
            }
        }

        var wrapped = Set<Int>()
        // A phone or card number split over two pieces: "+44 20" at the end of a row and "7946 0123" at the
        // start of the next. Neither half matches alone; together they do.
        for (i, line) in lines.enumerated() {
            guard let m = match(trailingDigits, in: line.text) else { continue }
            for (j, _) in continuations(of: i, in: lines, spans, anyEnd: true) {
                let next = lines[j]
                guard let lead = match(leadingDigits, in: next.text) else { continue }
                let left = String(line.text[m]), right = String(next.text[lead])
                let joined = left + " " + right
                guard let hit = sensitiveRanges(in: joined).first(where: { ($0.kind == .phone || $0.kind == .card)
                    && joined.distance(from: joined.startIndex, to: $0.range.lowerBound) < left.count
                    && joined.distance(from: joined.startIndex, to: $0.range.upperBound) > left.count + 1 }) else { continue }
                let a = joined.distance(from: joined.startIndex, to: hit.range.lowerBound)
                let b = joined.distance(from: joined.startIndex, to: hit.range.upperBound) - left.count - 1
                let r1 = line.text.index(m.lowerBound, offsetBy: a)..<m.upperBound
                let r2 = lead.lowerBound..<next.text.index(lead.lowerBound, offsetBy: min(b, right.count))
                for (l, r) in [(line, r1), (next, r2)] {
                    if let f = place(l, r, kind: hit.kind, textH: textH, in: image) { found.append(f) }
                }
                wrapped.insert(i)
            }
        }

        // The rest of a split value: in the next tile, in the next piece on the same row, or on the next row.
        // Numbers were joined above.
        var done = Set<Int>()
        var queue = open.filter { $0.1 != .phone && $0.1 != .card }
        while let (i, kind, start) = queue.popLast() {
            guard done.insert(i).inserted else { continue }
            let first = lines[i]
            for (j, how) in continuations(of: i, in: lines, spans) {
                let next = lines[j]
                var word: Range<String.Index>
                if how == .tile {
                    // Tiles overlap, so the next tile's piece holds the same token where this one was cut.
                    guard let w = next.token(atX: first.rect.maxX - first.rect.height * 0.5) else { continue }
                    word = w
                    // From where the value starts, so "API_KEY=" before it in the same token stays readable.
                    let n = next.text.distance(from: w.lowerBound, to: w.upperBound)
                    if let box = next.box(w), n > 1, start > box.minX {
                        let a = min(n - 1, max(0, Int(((start - box.minX) / (box.width / CGFloat(n))).rounded(.down)) - 1))
                        word = next.text.index(w.lowerBound, offsetBy: a)..<w.upperBound
                    }
                } else {
                    // Alone on its row, as the tail of a wrapped key is. A line number in an editor's gutter
                    // has the code right of it.
                    let h = next.rect.height
                    let alone = how == .wrap && !lines.contains { abs($0.rect.midY - next.rect.midY) < h * 0.5
                        && $0.rect.minX > next.rect.minX + h && $0.rect.minX < next.rect.maxX + h * 4 }
                    guard let w = leadingToken(next.text),
                          continues(kind, normalized(String(next.text[w])),
                                    alone: alone && next.text[w.upperBound...].allSatisfy(\.isWhitespace))
                    else { continue }
                    word = w
                    if how == .wrap { wrapped.insert(i) }
                }
                guard let f = place(next, word, kind: kind, textH: textH, in: image) else { continue }
                found.append(f)
                // A value longer than one tile or one row goes on again.
                if next.text[word.upperBound...].allSatisfy(\.isWhitespace) { queue.append((j, kind, f.rect.minX)) }
            }
        }
        // A wrapped value whose next row Vision did not read at all: blur the first token there by its ink.
        for (i, kind, _) in open where !wrapped.contains(i) {
            let first = lines[i]
            // Stronger evidence than for a read row: two more rows end at the same place, as wrapped rows do.
            let h = first.rect.height
            let (rowStart, rowEnd) = spans[i]
            let edge = lines.indices.filter { $0 != i && abs(lines[$0].rect.minY - first.rect.minY) > h * 0.5
                && abs(spans[$0].minX - rowStart) < h * 2 && abs(spans[$0].maxX - rowEnd) < h * 0.6
                && abs(lines[$0].rect.midY - first.rect.midY) < h * 30 }.count >= 2
            let row = CGRect(x: rowStart, y: first.rect.minY, width: first.rect.maxX - rowStart, height: first.rect.height)
            guard edge || reachesColumnEnd(i, lines, spans) || first.rect.maxX >= size.width - h * 2,
                  let tail = pixelTail(below: row, textH: textH, in: image),
                  // Vision read that row and the word there was not the value's tail. A line from far left
                  // crossed into this pane, so it says nothing about the tail.
                  !lines.contains(where: { $0.rect.minX > tail.minX - h * 3
                      && $0.rect.intersection(tail.insetBy(dx: -h, dy: 0)).height > tail.height * 0.5 })
            else { continue }
            let r = pad(tail, h: tail.height, in: size)
            found.append(Found(rect: r, kind: kind, secrets: [], context: [], token: r, line: r))
        }
        return merge(found)
    }

    /// The first word of a piece.
    private static func leadingToken(_ text: String) -> Range<String.Index>? {
        guard let a = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        var b = a
        while b < text.endIndex, !text[b].isWhitespace { b = text.index(after: b) }
        return a..<b
    }

    /// The ink of the first token on the row below `line`, when that row starts where the line starts.
    static func pixelTail(below line: CGRect, textH h: CGFloat, in image: CGImage) -> CGRect? {
        // From the middle of the line, so its own lower half is the first ink run whatever Vision's box says.
        guard let g = gray(image, CGRect(x: line.minX - h, y: line.midY, width: line.width + h, height: h * 2)) else { return nil }
        let (bg, thr) = inkLevel(g)
        func ink(_ x: Int, _ y: Int) -> Bool { abs(Int(g.px[y * g.w + x]) - bg) > thr }
        let rows = (0..<g.h).map { y in (0..<g.w).contains { ink($0, y) } }
        // Skip this line's own lower half, then take the next run of ink rows as tall as a line. A shorter
        // run is still this line: an underscore or a descender below a one-row gap.
        var y = 0, ra = 0, rb = 0
        while y < g.h {
            while y < g.h && rows[y] { y += 1 }
            while y < g.h && !rows[y] { y += 1 }
            ra = y
            while y < g.h && rows[y] && CGFloat(y - ra) < h * 1.3 { y += 1 }
            rb = y
            if CGFloat(rb - ra) > h * 0.3 { break }
        }
        guard CGFloat(rb - ra) > h * 0.3 else { return nil }
        let col = (0..<g.w).map { x in (ra..<rb).contains { ink(x, $0) } }
        // Near the row start, which may be an editor's line number a few characters left of the text.
        guard let lo = col.firstIndex(of: true), CGFloat(lo) < h * 5 else { return nil }
        var hi = lo, gap = 0
        let gapMax = Int(h * 0.45)
        for x in lo..<g.w {
            if col[x] { hi = x; gap = 0 } else { gap += 1; if gap > gapMax { break } }
        }
        return CGRect(x: g.origin.x + CGFloat(lo), y: g.origin.y + CGFloat(ra), width: CGFloat(hi + 1 - lo), height: CGFloat(rb - ra))
    }

    /// The run of ink that starts right after `line` on the same row and goes on with gaps under a space.
    static func inkRun(rightOf line: CGRect, textH h: CGFloat, in image: CGImage) -> CGRect? {
        guard let g = gray(image, CGRect(x: line.maxX, y: line.midY - h * 0.6, width: h * 60, height: h * 1.2)) else { return nil }
        let (bg, thr) = inkLevel(g)
        let col = (0..<g.w).map { x in (0..<g.h).contains { abs(Int(g.px[$0 * g.w + x]) - bg) > thr } }
        guard let lo = col.firstIndex(of: true), CGFloat(lo) < h * 1.2 else { return nil }
        var hi = lo, gap = 0
        let gapMax = Int(h * 0.45)
        for x in lo..<g.w {
            if col[x] { hi = x; gap = 0 } else { gap += 1; if gap > gapMax { break } }
        }
        let rows = (0..<g.h).filter { y in (lo...hi).contains { abs(Int(g.px[y * g.w + $0]) - bg) > thr } }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        return CGRect(x: g.origin.x + CGFloat(lo), y: g.origin.y + CGFloat(top), width: CGFloat(hi + 1 - lo), height: CGFloat(bottom + 1 - top))
    }

    /// Background grey (the most common) and the distance from it that counts as ink.
    private static func inkLevel(_ g: Gray) -> (bg: Int, thr: Int) {
        var hist = [Int](repeating: 0, count: 256)
        for p in g.px { hist[Int(p)] += 1 }
        let bg = hist.indices.max { hist[$0] < hist[$1] } ?? 0
        var devHist = [Int](repeating: 0, count: 256)
        for p in g.px { devHist[abs(Int(p) - bg)] += 1 }
        var top = 255, seen = 0
        let cut = max(1, g.px.count / 100)
        while top > 0 { seen += devHist[top]; if seen >= cut { break }; top -= 1 }
        return (bg, max(18, top * 35 / 100))
    }

    /// Whether the first word of the next row or piece is the rest of a value of this kind. Key pieces have
    /// no = or : inside, so "GITHUB_TOKEN=ghp_..." on the row after a key is a new line, not the key's tail.
    /// A misread glyph at either end, and about one in eight inside, is allowed.
    /// `alone` is true when the word is all there is on its row, as the tail of a wrapped key is.
    private static func continues(_ kind: Kind, _ raw: String, alone: Bool) -> Bool {
        let body = raw.hasSuffix("=") ? String(raw.reversed().drop { $0 == "=" }.reversed()) : raw
        if body.contains("=") || body.contains(":") { return false }
        let allowed: (Character) -> Bool
        switch kind {
        case .email: allowed = { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
        case .phone, .card: allowed = { $0.isNumber || "-)".contains($0) }
        default: allowed = { $0.isASCII && ($0.isLetter || $0.isNumber || "_-+/.".contains($0)) }
        }
        var word = Substring(body)
        if let f = word.first, !allowed(f) { word = word.dropFirst() }
        if let l = word.last, !allowed(l) { word = word.dropLast() }
        // One misread glyph in eight: blurry small text reads "_" as "×" and "l" as "]".
        guard !word.isEmpty, word.filter({ !allowed($0) }).count <= max(1, word.count / 8) else { return false }
        // A short number with more text after it on the row is a line number or a count, not a key's tail.
        if word.allSatisfy(\.isNumber), word.count <= 4, !alone { return false }
        switch kind {
        case .email: return word.count >= 2
        case .phone, .card: return true
        // A long plain word with more text after it ("AWS_ACCESS_KEY" then "_ID=") starts a new line.
        default: return looksLikeKeyPiece(word) || alone
        }
    }

    /// True when the line runs to the right edge of its column: about as far right as the longest line
    /// that starts where it starts. A terminal wraps such a line onto the next row.
    private static func reachesColumnEnd(_ i: Int, _ lines: [Line], _ spans: [(minX: CGFloat, maxX: CGFloat)]) -> Bool {
        let line = lines[i]
        let h = line.rect.height
        // Rows, not pieces: Vision splits a row into pieces at wide spaces.
        guard line.rect.maxX >= spans[i].maxX - 1 else { return false }
        let column = lines.indices.filter { abs(spans[$0].minX - spans[i].minX) < h * 2 && abs(lines[$0].rect.midY - line.rect.midY) < h * 30 }
        // Not the very longest: Vision sometimes joins a line with the next column's text.
        let ends = Set(column.map { spans[$0].maxX }).sorted()
        guard ends.count >= 2 else { return false }
        let right = ends.count >= 4 ? ends[ends.count * 3 / 4] : ends[ends.count - 1]
        return spans[i].maxX >= right - h * 1.5
    }

    /// Where the row of a piece starts and ends: the pieces beside it on the same row, with gaps up to about
    /// one space. An editor's line numbers sit further off.
    private static func rowSpan(_ i: Int, _ lines: [Line]) -> (minX: CGFloat, maxX: CGFloat) {
        let line = lines[i]
        let h = line.rect.height
        let row = lines.filter { abs($0.rect.midY - line.rect.midY) < h * 0.5 }
        var lo = line.rect.minX, hi = line.rect.maxX
        var moved = true
        while moved {
            moved = false
            for r in row {
                if r.rect.minX < lo && r.rect.maxX > lo - h * 0.9 { lo = r.rect.minX; moved = true }
                if r.rect.maxX > hi && r.rect.minX < hi + h * 0.9 { hi = r.rect.maxX; moved = true }
            }
        }
        return (lo, hi)
    }

    private enum Join { case tile, gap, wrap }

    /// `anyEnd` takes the next row even when this one stops short of the column end, as word wrap does.
    private static func continuations(of i: Int, in lines: [Line], _ spans: [(minX: CGFloat, maxX: CGFloat)],
                                      anyEnd: Bool = false) -> [(Int, Join)] {
        let first = lines[i]
        let h = first.rect.height
        let wraps = anyEnd ? first.rect.maxX >= spans[i].maxX - 1
            : reachesColumnEnd(i, lines, spans) || first.rect.maxX >= first.shot.width - h * 2
        let rowStart = spans[i].minX
        let joins: [(Int, Join)] = lines.indices.compactMap { j in
            guard j != i else { return nil }
            let next = lines[j]
            let sameRow = abs(next.rect.midY - first.rect.midY) < h * 0.5
            // Cut by a tile edge: the next tile's piece starts inside this one's span.
            if first.cutRight && next.cutLeft && next.tile != first.tile && sameRow
                && next.rect.minX > first.rect.minX && next.rect.minX < first.rect.maxX { return (j, .tile) }
            // Split by Vision: a small gap on the same row. A wider gap is the next column.
            if sameRow && next.rect.minX >= first.rect.maxX - h * 0.5 && next.rect.minX - first.rect.maxX < h * 1.5 { return (j, .gap) }
            // Wrapped: the first piece ran to the end of its column and the next row starts at its left,
            // or just right of an editor's line number.
            if wraps && !next.cutLeft && next.rect.minY > first.rect.minY + h * 0.5 && next.rect.minY < first.rect.maxY + h * 0.7
                && next.rect.minX < rowStart + h * 3 && next.rect.minX > rowStart - h * 1.5 { return (j, .wrap) }
            return nil
        }
        // A wrap goes on the very next row only.
        let nearest = joins.filter { $0.1 == .wrap }.map { lines[$0.0].rect.minY }.min() ?? 0
        return joins.filter { $0.1 != .wrap || lines[$0.0].rect.minY < nearest + h * 0.3 }
    }

    /// Hits on the same row that touch or overlap become one, so the editor removes a key with one click
    /// and overlapping tiles leave no duplicate.
    private static func merge(_ found: [Found]) -> [Found] {
        var items = found
        var changed = true
        while changed {
            changed = false
            outer: for a in items.indices {
                for b in items.indices where b > a {
                    let p = items[a].rect, q = items[b].rect
                    let v = min(p.maxY, q.maxY) - max(p.minY, q.minY)
                    let hmin = min(p.height, q.height)
                    let gapX = max(p.minX, q.minX) - min(p.maxX, q.maxX)
                    guard v > hmin * 0.5, gapX < hmin * 0.3 else { continue }
                    var m = items[a]
                    m.rect = p.union(q)
                    m.token = m.token.union(items[b].token)
                    m.line = m.line.union(items[b].line)
                    m.secrets += items[b].secrets
                    m.context += items[b].context
                    if rank(items[b].kind) > rank(m.kind) { m.kind = items[b].kind }
                    items[a] = m
                    items.remove(at: b)
                    changed = true
                    break outer
                }
            }
        }
        return items
    }

    private static func rank(_ kind: Kind) -> Int {
        switch kind {
        case .key, .privateKey: return 3
        case .token, .secret: return 2
        case .card: return 1
        case .email, .phone: return 0
        }
    }

    // MARK: - Placement

    /// Places a range of a line on the pixels. Vision gives the box of the whole token around the range;
    /// the ink inside and next to that box says where the token really starts and ends and where the
    /// glyphs sit. Each uncertain edge leans outward: a secret that runs to the end of its token blurs to
    /// the token's last ink, and an edge inside a token eats one more character.
    static func place(_ line: Line, _ range: Range<String.Index>, kind: Kind, textH: CGFloat, in image: CGImage) -> Found? {
        let size = CGSize(width: image.width, height: image.height)
        let tok = line.token(around: range)
        guard let word = line.box(tok), word.width > 0, word.height > 0 else { return nil }
        let text = line.text
        let n = text.distance(from: tok.lowerBound, to: tok.upperBound)
        let a = text.distance(from: tok.lowerBound, to: range.lowerBound)
        let b = text.distance(from: tok.lowerBound, to: range.upperBound)
        let snapped = snap(word: word, n: n, a: a, b: b, textH: min(word.height, textH * 1.3),
                           spaced: text[tok].contains(where: \.isWhitespace), in: image)
        let h = snapped.rect.height
        let context = String(text[..<range.lowerBound]) + " " + String(text[range.upperBound...])
        // An edge inside the token already took in one spare character ("=" before a key). The pad on that
        // side stops short of the next character's ink, so the label ("API_KEY") stays sharp.
        let rect = trim(pad(snapped.rect, h: h, in: size), ink: snapped.rect, left: a > 0, right: b < n, in: image)
        return Found(rect: rect, kind: kind, secrets: [String(text[range])],
                     context: [context], token: pad(snapped.token, h: h, in: size),
                     line: pad(line.rect.union(snapped.token), h: h, in: size))
    }

    /// Grey pixels of a part of the shot, top row first.
    struct Gray {
        let origin: CGPoint
        let w: Int, h: Int
        let px: [UInt8]
    }

    static func gray(_ image: CGImage, _ rect: CGRect) -> Gray? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isEmpty, let crop = image.cropping(to: r) else { return nil }
        let w = crop.width, h = crop.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Gray(origin: r.origin, w: w, h: h, px: px) : nil
    }

    /// The range's ink rect and the whole token's ink rect, both unpadded, in shot pixels.
    /// `word` is Vision's box of the token, `n` its characters, `a..<b` the range inside it.
    /// `textH` is the text height to expect, which Vision's box may overstate.
    static func snap(word: CGRect, n: Int, a: Int, b: Int, textH: CGFloat, spaced: Bool = false,
                     in image: CGImage) -> (rect: CGRect, token: CGRect) {
        let h = word.height
        let cw = word.width / CGFloat(max(n, 1))
        // Without pixels: cut by character position, with a character to spare on each cut side.
        let ratio: CGRect = {
            let x0 = a > 0 ? word.minX + cw * (CGFloat(a) - 1) : word.minX
            let x1 = b < n ? word.minX + cw * (CGFloat(b) + 1) : word.maxX
            return CGRect(x: x0, y: word.minY, width: x1 - x0, height: word.height)
        }()
        let reach = cw * 3 + h
        guard let g = gray(image, CGRect(x: word.minX - reach, y: word.minY - h * 0.7,
                                         width: word.width + reach * 2, height: h * 2.4)) else { return (ratio, word) }
        let ox = g.origin.x, oy = g.origin.y

        // Background is the most common grey; ink is what stands well apart from it.
        let (bg, thr) = inkLevel(g)
        func ink(_ x: Int, _ y: Int) -> Bool { abs(Int(g.px[y * g.w + x]) - bg) > thr }

        // Columns with ink in the line, short of the neighbours' ascenders and descenders. Wide enough
        // for a dot or an underscore, so "example.com" stays one run.
        let cy = word.midY - oy
        let y0 = max(0, Int((cy - textH * 0.25).rounded())), y1 = min(g.h - 1, Int((cy + textH * 0.25).rounded()))
        guard y0 < y1 else { return (ratio, word) }
        let f0 = max(0, Int((cy - textH * 0.45).rounded())), f1 = min(g.h - 1, Int((cy + textH * 0.45).rounded()))
        var col = [Int](repeating: 0, count: g.w)
        for x in 0..<g.w {
            var c = 0
            for y in f0...f1 where ink(x, y) { c += 1 }
            col[x] = c
        }
        let wx0 = max(0, Int(word.minX - ox)), wx1 = min(g.w - 1, Int(word.maxX - ox))
        guard wx0 < wx1, var lo = (wx0...wx1).first(where: { col[$0] > 0 }),
              var hi = (wx0...wx1).last(where: { col[$0] > 0 }) else { return (ratio, word) }
        // The characters Vision read sit inside its box. Ink followed past the box belongs to the token,
        // but is not counted in `n` ("JWT_T" left of a piece "OKEN=..." that a tile edge cut).
        let lo0 = lo, hi0 = hi
        // Vision's box can stop short of the token's last glyphs or start after its first: follow the ink
        // while the gaps stay narrower than a space. The widest gap inside the box is a gap between letters
        // of this font; a space is wider. Proportional text has spaces narrower than an average letter.
        // With spaces inside the range ("+1 415 555 0123") the widest gap is a space: stay under it.
        var inner = 0, run = 0
        for x in lo...hi { if col[x] > 0 { inner = max(inner, run); run = 0 } else { run += 1 } }
        let gapMax = max(2, min(Int(cw * 0.75), spaced ? inner * 3 / 5 : max(inner + 1 + inner / 5, Int(cw * 0.5))))
        let far = Int(reach)
        var gapRun = 0
        var x = hi + 1
        while x < g.w && x <= wx1 + far {
            if col[x] > 0 { hi = x; gapRun = 0 } else { gapRun += 1; if gapRun > gapMax { break } }
            x += 1
        }
        gapRun = 0
        x = lo - 1
        while x >= 0 && x >= wx0 - far {
            if col[x] > 0 { lo = x; gapRun = 0 } else { gapRun += 1; if gapRun > gapMax { break } }
            x -= 1
        }
        // Glyph pitch from the ink of the characters Vision read. Exact for monospaced text.
        let pitch = CGFloat(hi0 - lo0 + 1) / max(1, CGFloat(n) - 0.15)
        var x0 = CGFloat(lo), x1 = CGFloat(hi + 1)
        if a > 0 {
            var t = Int((CGFloat(lo0) + pitch * (CGFloat(a) - 0.8)).rounded(.down))
            let stop = t - Int(pitch * 0.6)
            while t > max(0, stop) && col[t] > 0 { t -= 1 }
            x0 = CGFloat(max(lo, t))
        }
        if b < n {
            var t = Int((CGFloat(lo0) + pitch * (CGFloat(b) + 0.7)).rounded(.up))
            let stop = t + Int(pitch * 0.6)
            while t < min(g.w - 1, stop) && col[t] > 0 { t += 1 }
            x1 = CGFloat(min(hi + 1, t))
        }
        // Rows: full ascenders and descenders of this line, up to the empty rows between lines.
        let cx0 = Int(x0), cx1 = max(Int(x0) + 1, Int(x1))
        func rowInk(_ y: Int) -> Bool {
            var x = cx0
            while x < min(cx1, g.w) { if ink(x, y) { return true }; x += 1 }
            return false
        }
        var r0 = y0, r1 = y1
        let limitUp = max(0, Int(cy - textH * 0.85)), limitDown = min(g.h - 1, Int(cy + textH * 0.85))
        // A gap of a row or two inside a line is the dot of an i or j, or an accent.
        let skip = max(1, Int(textH * 0.15))
        func up() -> Bool { (1...skip).first { r0 - $0 >= limitUp && rowInk(r0 - $0) }.map { r0 -= $0; return true } ?? false }
        func down() -> Bool { (1...skip).first { r1 + $0 <= limitDown && rowInk(r1 + $0) }.map { r1 += $0; return true } ?? false }
        while up() {}
        while down() {}
        let top0 = CGFloat(r0) + oy, bottom = CGFloat(r1 + 1) + oy
        let rect = CGRect(x: x0 + ox, y: top0, width: x1 - x0, height: bottom - top0)
        let token = CGRect(x: CGFloat(lo) + ox, y: top0, width: CGFloat(hi + 1 - lo), height: bottom - top0)
        return (rect, token)
    }

    /// Vision boxes are normalised with the origin bottom left. Hits are pixels with the origin top left.
    static func pixelRect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }

    /// `h` is the text height. The blur fades in over its outer few pixels and has rounded corners,
    /// so the pad keeps the glyphs clear of both.
    private static func pad(_ rect: CGRect, h: CGFloat, in size: CGSize) -> CGRect {
        var rect = rect
        // Text cut by the edge of the shot: Vision boxes only the glyphs it could read, so run to the edge.
        if rect.maxX > size.width - h * 1.5 { rect.size.width = size.width - rect.minX }
        if rect.minX < h * 1.5 { rect.size.width += rect.minX; rect.origin.x = 0 }
        // Measured: at 4 px a glyph corner at the end of a 1x line still showed past the rounded corner.
        return rect.insetBy(dx: -max(6, h * 0.35), dy: -max(4, h * 0.2)).integral
            .intersection(CGRect(origin: .zero, size: size))
    }

    /// Pulls a padded side back to 2 px clear of the first ink outside `ink`, on the rows of `ink`.
    /// Only for sides whose ink rect already ends on a spare character, so the blur's soft edge falls on it.
    static func trim(_ padded: CGRect, ink: CGRect, left: Bool, right: Bool, in image: CGImage) -> CGRect {
        guard left || right, let g = gray(image, padded) else { return padded }
        let (bg, thr) = inkLevel(g)
        let y0 = max(0, Int(ink.minY - g.origin.y)), y1 = min(g.h - 1, Int(ink.maxY - g.origin.y) - 1)
        guard y0 <= y1 else { return padded }
        func inkColumn(_ x: Int) -> Bool { (y0...y1).contains { abs(Int(g.px[$0 * g.w + x]) - bg) > thr } }
        var r = padded
        if left {
            var x = Int(ink.minX - g.origin.x) - 1
            while x >= 0 && !inkColumn(x) { x -= 1 }
            if x >= 0 {
                let edge = min(ink.minX, g.origin.x + CGFloat(x) + 3)
                r = CGRect(x: edge, y: r.minY, width: r.maxX - edge, height: r.height)
            }
        }
        if right {
            var x = Int(ink.maxX - g.origin.x)
            while x < g.w && !inkColumn(x) { x += 1 }
            if x < g.w {
                let edge = max(ink.maxX, g.origin.x + CGFloat(x) - 2)
                r.size.width = edge - r.minX
            }
        }
        return r
    }

    private static func isSecret(_ kind: Kind) -> Bool {
        kind == .key || kind == .token || kind == .secret
    }

    // MARK: - Verify

    /// Blurs, reads the blurred strips again, and widens any hit where a sensitive pattern or a piece of
    /// 5+ characters of what it hid can still be read: first to what was read, then to the whole token,
    /// then to the whole line. Keeps the final blur for `apply`.
    static func verified(_ found: [Found], in image: CGImage) -> [Hit] {
        var items = found
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        func hits() -> [Hit] {
            items.map { Hit(rect: $0.rect.integral.intersection(bounds), kind: $0.kind) }
        }
        guard !items.isEmpty else { return [] }
        var check = Array(items.indices)
        for round in 0..<3 {
            guard let blurred = render(hits(), to: image) else { return hits() }
            let leaks = self.leaks(of: check, items, in: blurred)
            if leaks.isEmpty { remember(image, hits(), blurred); return hits() }
            for (i, boxes) in leaks {
                switch round {
                case 0: for box in boxes { items[i].rect = items[i].rect.union(box) }
                case 1: items[i].rect = items[i].rect.union(items[i].token)
                default: items[i].rect = items[i].rect.union(items[i].line)
                }
            }
            check = leaks.map(\.0)
        }
        let final = hits()
        if let blurred = render(final, to: image) { remember(image, final, blurred) }
        return final
    }

    /// For each checked hit, the boxes (shot pixels, padded) where something readable is left.
    private static func leaks(of indices: [Int], _ items: [Found], in blurred: CGImage) -> [(Int, [CGRect])] {
        let size = CGSize(width: blurred.width, height: blurred.height)
        // One strip per hit: the hit and a little around it. Small text is scaled up for the read.
        struct Strip { let item: Int; let region: CGRect; let scale: CGFloat }
        var strips: [Strip] = []
        for i in indices {
            let r = items[i].rect
            let h = items[i].token.height
            let region = r.insetBy(dx: -h, dy: 0).integral.intersection(CGRect(origin: .zero, size: size))
            guard !region.isEmpty else { continue }
            let scale: CGFloat = h < 24 ? 2 : 1
            // Wide strips go in pieces: Vision drops text on very wide images.
            let maxW = 1400 / scale
            var x = region.minX
            while true {
                let w = min(maxW, region.maxX - x)
                strips.append(Strip(item: i, region: CGRect(x: x, y: region.minY, width: w, height: region.height), scale: scale))
                if x + w >= region.maxX { break }
                x += maxW - 300 / scale
            }
        }
        guard !strips.isEmpty else { return [] }

        // Stack the strips into a few sheets and read each sheet once.
        var sheets: [[(Strip, CGFloat)]] = [[]]
        var y: CGFloat = 0
        for s in strips {
            let hs = s.region.height * s.scale
            if y + hs > 1000, !(sheets.last?.isEmpty ?? true) { sheets.append([]); y = 0 }
            sheets[sheets.count - 1].append((s, y))
            y += hs + max(24, hs * 0.6)
        }
        var reads = [[(Strip, String, CGRect, VNRecognizedText)]](repeating: [], count: sheets.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sheets.count) { k in
            let sheet = sheets[k]
            let width = Int(sheet.map { $0.0.region.width * $0.0.scale }.max() ?? 1) + 32
            let height = Int(sheet.map { $0.1 + $0.0.region.height * $0.0.scale }.max() ?? 1) + 16
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            for (s, top) in sheet {
                guard let crop = blurred.cropping(to: s.region) else { continue }
                let w = s.region.width * s.scale, h = s.region.height * s.scale
                ctx.draw(crop, in: CGRect(x: 16, y: CGFloat(height) - 8 - top - h, width: w, height: h))
            }
            guard let img = ctx.makeImage() else { return }
            var out: [(Strip, String, CGRect, VNRecognizedText)] = []
            for obs in recognize(img) {
                guard let cand = obs.topCandidates(1).first else { continue }
                let b = pixelRect(obs.boundingBox, in: CGSize(width: width, height: height))
                // Which strip it sits in, and back to shot pixels.
                guard let (s, top) = sheet.first(where: { b.midY - 8 >= $0.1 && b.midY - 8 <= $0.1 + $0.0.region.height * $0.0.scale })
                else { continue }
                let shotRect = CGRect(x: s.region.minX + (b.minX - 16) / s.scale, y: s.region.minY + (b.minY - 8 - top) / s.scale,
                                      width: b.width / s.scale, height: b.height / s.scale)
                out.append((s, cand.string, shotRect, cand))
            }
            lock.lock(); reads[k] = out; lock.unlock()
        }

        var result: [Int: [CGRect]] = [:]
        for (s, text, rect, cand) in reads.flatMap({ $0 }) {
            let item = items[s.item]
            let h = item.token.height
            // Where a part of the read sits: Vision's box of that part, mapped like the whole line.
            // Accurate mode boxes whole words, so a part inside a word is cut by its share of the characters,
            // with one to spare on each cut side: "TOKEN=" before a read value is not part of the leak.
            func partBox(_ r0: Range<String.Index>) -> CGRect {
                var lo = r0.lowerBound, hi = r0.upperBound
                while lo > text.startIndex, !text[text.index(before: lo)].isWhitespace { lo = text.index(before: lo) }
                while hi < text.endIndex, !text[hi].isWhitespace { hi = text.index(after: hi) }
                let whole = word(lo..<hi)
                let n = CGFloat(text.distance(from: lo, to: hi))
                guard n > 0, whole.width > 0 else { return whole }
                let a = CGFloat(text.distance(from: lo, to: r0.lowerBound)), b = CGFloat(text.distance(from: lo, to: r0.upperBound))
                let cw = whole.width / n
                let x0 = a > 0 ? whole.minX + cw * (a - 1) : whole.minX
                let x1 = b < n ? whole.minX + cw * (b + 1) : whole.maxX
                return CGRect(x: x0, y: whole.minY, width: x1 - x0, height: whole.height)
            }
            func word(_ r: Range<String.Index>) -> CGRect {
                guard let bb = try? cand.boundingBox(for: r)?.boundingBox, rect.width > 0 else { return rect }
                // bb is relative to the sheet; the line's own box maps it back. Use the x share inside the line.
                let full = (try? cand.boundingBox(for: text.startIndex..<text.endIndex)?.boundingBox) ?? bb
                guard full.width > 0 else { return rect }
                let fx0 = (bb.minX - full.minX) / full.width, fx1 = (bb.maxX - full.minX) / full.width
                return CGRect(x: rect.minX + rect.width * fx0, y: rect.minY, width: rect.width * (fx1 - fx0), height: rect.height)
            }
            var boxes: [CGRect] = []
            // A pattern still readable on top of the hit.
            // Only on the hit's own row: a neighbour line cut by the strip is not this hit's leak.
            let row = item.token
            func onRow(_ box: CGRect) -> Bool { abs(box.midY - row.midY) < row.height * 0.5 }
            for (r, _) in sensitiveRanges(in: text) {
                let box = partBox(r)
                if box.intersects(item.rect) && onRow(box) { boxes.append(box) }
            }
            // A piece of 5+ characters of what the hit covers.
            let norm = normalized(text)
            for word in norm.split(whereSeparator: \.isWhitespace) where word.count >= 5 {
                if hasFragment(String(word), of: item.secrets, notIn: item.context) {
                    let lo = norm.distance(from: norm.startIndex, to: word.startIndex)
                    let a = text.index(text.startIndex, offsetBy: lo)
                    let b = text.index(a, offsetBy: word.count)
                    let box = partBox(a..<b)
                    if onRow(box) { boxes.append(box) }
                }
            }
            if !boxes.isEmpty {
                let padded = boxes.map { $0.insetBy(dx: -max(4, h * 0.6), dy: -max(4, h * 0.2)).integral.intersection(CGRect(origin: .zero, size: size)) }
                result[s.item, default: []] += padded
            }
        }
        return result.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// True when `word` holds 5 characters in a row of one of the secrets, which the line's other text
    /// does not also hold.
    private static func hasFragment(_ word: String, of secrets: [String], notIn context: [String]) -> Bool {
        let w = Array(word)
        let ctx = context.map(normalized)
        for secret in secrets {
            let s = Array(normalized(secret).filter { !$0.isWhitespace })
            guard s.count >= 5, w.count >= 5 else { continue }
            for i in 0...(w.count - 5) {
                let piece = String(w[i..<(i + 5)])
                if piece.allSatisfy({ !$0.isLetter && !$0.isNumber }) { continue }
                guard String(s).contains(piece) else { continue }
                if ctx.contains(where: { $0.contains(piece) }) { continue }
                return true
            }
        }
        return false
    }

    // The last blur detect made, so `apply` with the same image and hits costs nothing.
    private static let cacheLock = NSLock()
    private static var cache: (image: CGImage, hits: [Hit], out: CGImage)?

    private static func remember(_ image: CGImage, _ hits: [Hit], _ out: CGImage) {
        cacheLock.lock(); cache = (image, hits, out); cacheLock.unlock()
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
        cacheLock.lock()
        let kept = cache
        cacheLock.unlock()
        if let kept, kept.image === image, kept.hits == hits { return kept.out }
        return render(hits, to: image)
    }

    private static func render(_ hits: [Hit], to image: CGImage) -> CGImage? {
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

    /// OCR can split one key into chunks with a space between them. A chunk only joins when it has a digit
    /// or a capital right after a small letter, so a key followed by an ordinary word does not swallow the word.
    private static let chunks = #"(?: (?=[A-Za-z0-9_\-]*(?:\d|(?-i:[a-z][A-Z][A-Za-z])))[A-Za-z0-9_\-]{3,})*"#
    /// Secret names, with the digits OCR reads for O and E ("T0KEN", "K3Y"). Case-insensitive rules only.
    private static let names = #"(?:k[e3]y|s[e3]cr[e3]t|t[o0]k[e3]n|passw(?:[o0]r)?d|passphrase|pwd|cr[e3]d[e3]ntials?)"#
    /// No letter or digit right before the match.
    private static let start = "(?<![A-Za-z0-9])"

    private static let rules: [Rule] = [
        // -----BEGIN RSA PRIVATE KEY----- and friends. The base64 lines under it fall to the long-token rule.
        Rule(kind: .privateKey, regex: rx(#"-*\s*BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY\s*-*"#), group: 0, check: nil),
        // OpenAI and Anthropic: sk-..., sk-proj-..., sk-ant-api03-... OCR reads "sk" as "sK" on poor reads.
        Rule(kind: .key, regex: rx(start + #"[sS][kK]-(?:ant-|proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{16,}"# + chunks), group: 0, check: nil),
        // GitHub tokens.
        Rule(kind: .key, regex: rx(start + #"(?:[gG][hH][pousr]_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{20,})"# + chunks), group: 0, check: nil),
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
        Rule(kind: .token, regex: rx(#"\b(?:bearer|basic)\s+([A-Za-z0-9_\-.=+/~]{12,}"# + chunks + ")", .caseInsensitive), group: 1, check: nil),
        Rule(kind: .token, regex: rx(#"authorization["']?\s*[:=]\s*["']?(?:bearer\s+|basic\s+|token\s+)?([^\s"']{12,}"# + chunks + ")", .caseInsensitive), group: 1, check: nil),
        // API_KEY=..., client_secret: "...", DB_PASSWORD=... The value side only, 12+ characters, not a path or URL.
        Rule(kind: .secret, regex: rx(
            #"[A-Za-z0-9_.\-]*"# + names + #"[A-Za-z0-9_.\-]*["']?\s*(?::=|=>|=|:)\s*["']?([^\s"'`,;]{12,}"# + chunks + ")",
            .caseInsensitive), group: 1, check: { !looksLikePathOrURL($0) }),
        // Fail toward blur: an env-style name (OPENAI_API_KEY=, DB_PASSWORD=) with a value too short or too
        // badly read for the rules above. The value must look random (a digit or both cases) or be long.
        Rule(kind: .secret, regex: rx(
            #"(?<![A-Za-z0-9_])[A-Z0-9_]*(?:K[E3]Y|S[E3]CR[E3]T|T[O0]K[E3]N|PASSW[O0]RD|PASSWD|PWD|CR[E3]D[E3]NTIALS?)[A-Z0-9_]*\s*=\s*["']?([^\s"'`,;]{3,}"# + chunks + ")"),
            group: 1, check: { v in
                // 3 is enough for the first piece when OCR split the value ("8Gr! OCZEN8CjFODvdH").
                v.count >= 6 && !looksLikePathOrURL(v) && (v.count >= 12 || v.contains(where: \.isNumber)
                    || (v.contains(where: \.isUppercase) && v.contains(where: \.isLowercase)))
            }),
        // Any env-style name whose value looks random: digits, capitals and small letters, 12 or more.
        // Catches a secret name OCR misread past recognition ("DASEASWRD=r0ub4dor-P2L5Hz0gs").
        Rule(kind: .secret, regex: rx(#"(?<![A-Za-z0-9_])[A-Z][A-Z0-9_]{2,}\s*=\s*["']?([^\s"'`,;]{12,})"#),
             group: 1, check: { v in
                 // Or capitals and digits only, 16 or more, like an AWS key id read badly. Not a git hash
                 // with a misread character or two ("b0796d5ba9...e2eaf" read with a Z).
                 !looksLikePathOrURL(v) && v.contains(where: \.isNumber) && v.contains(where: \.isUppercase)
                     && (v.contains(where: \.isLowercase) || v.count >= 16)
                     && v.filter({ !"0123456789abcdef".contains($0) }).count > 2
             }),
        // Card numbers: 13 to 19 digits, spaces or dashes allowed, Luhn valid, a real card prefix.
        Rule(kind: .card, regex: rx(#"(?<![\d.])(?:\d[ \-]?){12,18}\d(?![\d.])"#), group: 0, check: isCard),
        // Random tokens without a known prefix, and base64 lines of a private key. 20 characters is enough when
        // digits, capitals and small letters switch about every other character: a password next to a
        // name OCR could not read.
        Rule(kind: .token, regex: rx(#"(?<![A-Za-z0-9+/_\-])[A-Za-z0-9+/_\-]{20,}={0,2}(?![A-Za-z0-9+/=_\-])"#), group: 0, check: looksRandom),
    ]

    /// A known key prefix at the very end of a piece, too short for the full rule. Used only by detect.
    private static let trailingPrefix = rx(
        start + #"(?:[sS][kK]-(?:ant-|proj-)?|[gG][hH][pousr]_|github_pat_|A[KS][I1l|]A|A[I1l|]za|xox[abposre]-|(?:sk|rk)_live_|eyJ)[A-Za-z0-9_\-]*$"#)
    /// A secret name and = at the very end of a piece, with the value cut off by a tile edge or a wrap.
    /// Group 1 is the part of the value in this piece, maybe empty. Used only by detect, only at a cut.
    private static let trailingAssign = rx(
        #"[A-Za-z0-9_.\-]*"# + names + #"[A-Za-z0-9_.\-]*["']?\s*(?::=|=>|=|:)\s*["']?((?:[^\s"'`,;$/{~.%][^\s"'`,;]*)?)$"#,
        .caseInsensitive)
    /// "Bearer abc" with the token cut off at the very end of a piece. Used only by detect, only at a cut.
    private static let trailingBearer = rx(#"\b(?:(?:bearer|basic)\b\s*|token\s+)([A-Za-z0-9_\-.=+/~]*)$"#, .caseInsensitive)
    /// A phone number cut off at the very end of a piece. Used only by detect, only at a cut.
    private static let trailingPhone = rx(#"(?:^|(?<=[\s(]))\+?\d[\d ().\-]{6,}$"#)
    /// Digits at the end of a piece and at the start of the next, which may be one number split in two.
    private static let trailingDigits = rx(#"(?:^|(?<=[\s(:]))\+?\(?\d[\d ().\-]*$"#)
    private static let leadingDigits = rx(#"^\s*\(?\d[\d ().\-]*\d"#)
    /// An email cut after the @ at the very end of a piece. Used only by detect, only at a cut.
    private static let trailingEmail = rx(#"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]*$"#)

    /// The rest of a key has a digit or a capital after a small letter, so "done", "ls" or "Release"
    /// after a key stays readable.
    private static func looksLikeKeyPiece(_ s: Substring) -> Bool {
        s.count >= 2 && (s.contains(where: \.isNumber) || zip(s, s.dropFirst()).contains { $0.isLowercase && $1.isUppercase })
    }

    /// Group 1 of the first match, which may be empty (then an empty range at its place).
    private static func matchGroup(_ regex: NSRegularExpression, in text: String) -> Range<String.Index>? {
        let ns = normalized(text)
        guard let m = regex.firstMatch(in: ns, range: NSRange(location: 0, length: (ns as NSString).length)),
              m.range(at: 1).location != NSNotFound else { return nil }
        return Range(m.range(at: 1), in: text)
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
                // Checks see the normalised text: "Ø" read for 0 is not a capital letter.
                if let check = rule.check, !check((norm as NSString).substring(with: r)) { continue }
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
            ("ΑΒΕΗΙΚΜΝΟΡΤΧΥΖ", "ABEHIKMNOPTXYZ"), ("οιυνκτρα", "oiuvktpa"), ("Øø", "0o"),
            // More Cyrillic shapes and accents OCR puts into keys ("З" for 3, "í" for i).
            ("ЗзбЬькмнтпгӏ", "336bbkmhtnrl"), ("íìîïáàâäéèêëóòôöúùûüñç", "iiiiaaaaeeeeoooouuuunc"),
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
        // A git hash with a character or two misread as a capital.
        if s.filter({ !"0123456789abcdef".contains($0) }).count <= 2 { return false }
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
        check("detect + apply under 400 ms when warm", warmMs < 400,
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
