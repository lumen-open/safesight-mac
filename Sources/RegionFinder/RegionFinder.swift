// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Made cheaper for SafeSight Mac (docs/ENERGY.md) with the same output byte for byte: the vendored code is kept in
// the tests as the reference (FinderEquivalenceTests).
// Picture finder: proposes photo-like regions so that text and interface never reach the
// heavy models. It leans toward finding: anything unsure counts as a picture. It can be
// widened by the cell network (CellNet), which may only add cells, never remove them.
import Foundation
import Preprocess

public struct Region: Hashable, Sendable {
    public var rect: PixelRect
    public var source: Source
    public enum Source: String, Sendable { case colourStats, cellNet, both }
}

public struct Grid: Sendable {
    /// Members in reading order; all of near-equal size on a regular pitch.
    public var members: [PixelRect]
    public var cellSize: (w: Int, h: Int)
    public var bounds: PixelRect
}

public struct FinderConfig: Sendable {
    /// 8x8 windows on a 4 px step; a window is photo-like when it has at least `minDistinct`
    /// distinct 12-bit colours, its commonest colour covers at most `maxDominant` of it, and it is
    /// not a smooth ramp (mean absolute second difference at least `minTexture`).
    public var minDistinct = 10
    public var maxDominant = 0.40
    public var minTexture = 1.0
    /// Gutter test: a line is uniform if every channel varies by at most this along it.
    public var gutterTolerance = 2
    /// Regions with a shorter side are dropped (pictures under 16 px are out of scope by sight).
    public var minRegionSide = 10
    /// A marked cell crossed by a plain line at least this long is a gutter cell.
    public var gutterRun = 16
    /// Gutter lines must be nearly exact (screen gutters are drawn flat; photo areas rarely are).
    public var gutterRunTolerance = 2
    /// Regions may grow this far past their marked cells (smooth parts of a photo are often unmarked).
    public var growBeyondMarked = 32
    public var useCellNet = true
    public init() {}
}

public final class RegionFinder {
    public let config: FinderConfig
    public let cellNet: CellNet?
    public init(config: FinderConfig = FinderConfig(), cellNet: CellNet? = CellNet.bundled) {
        self.config = config
        self.cellNet = config.useCellNet ? cellNet : nil
    }

    public struct Output: Sendable {
        public var regions: [Region]
        public var grids: [Grid]
        /// Photo-like 4 px cells (for diagnostics and the bench).
        public var cellsMarked: Int
        public var cellsTotal: Int
    }

    public func find(_ img: RGBAImage, within area: PixelRect? = nil) -> Output {
        let W = img.width, H = img.height
        let A = area?.clamped(width: W, height: H) ?? PixelRect(x: 0, y: 0, w: W, h: H)
        let cw = (A.w + 3) / 4, ch = (A.h + 3) / 4
        var mark = [UInt8](repeating: 0, count: cw * ch)  // bit 0 colour stats, bit 1 cell net
        markCells(img, A, cw: cw, ch: ch, into: &mark)
        // Gutter cells: marked cells crossed by a plain straight line at least `gutterRun` px long.
        // They are cleared so that tiles separated by thin gutters fall into separate groups.
        var core = mark
        for cy in 0..<ch {
            for cx in 0..<cw where mark[cy * cw + cx] != 0 {
                let x0 = A.x + cx * 4, y0 = A.y + cy * 4
                let x1 = min(x0 + 4, A.maxX), y1 = min(y0 + 4, A.maxY)
                var gutter = false
                for x in x0..<x1 where !gutter { gutter = verticalRun(img, x: x, y0: y0, y1: y1) >= config.gutterRun }
                for y in y0..<y1 where !gutter { gutter = horizontalRun(img, y: y, x0: x0, x1: x1) >= config.gutterRun }
                if gutter { core[cy * cw + cx] = 0 }
            }
        }
        let outer = components(mark, cw, ch)
        let inner = components(core, cw, ch)
        var innerByOuter: [Int32: [PixelRect]] = [:]
        for c in inner.boxes.indices {
            let any = inner.firstCell[c]
            innerByOuter[outer.label[any], default: []].append(inner.boxes[c])
        }
        var seeds: [(PixelRect, UInt8)] = []
        for o in outer.boxes.indices {
            let src = outer.sources[o]
            let pieces = innerByOuter[Int32(o)] ?? [outer.boxes[o]]
            for b in pieces { seeds.append((cellRect(b, A, W, H), src)) }
        }
        // Grow each seed to its picture's edges, then merge overlapping results.
        let outerRects = outer.boxes.map { cellRect($0, A, W, H) }
        var grown: [(PixelRect, UInt8)] = seeds.map { (grow(img, $0.0, limit: outerLimit(seedIn: $0.0, outer: outerRects)), $0.1) }
        Self.mergeOverlapping(&grown)
        if ProcessInfo.processInfo.environment["FINDER_DEBUG"] != nil {
            print("outer", outer.boxes.count, "inner", inner.boxes.count, "seeds", seeds.count, "grown", grown.count, "cleared", zip(mark, core).filter { $0.0 != 0 && $0.1 == 0 }.count)
            if let e = ProcessInfo.processInfo.environment["FINDER_DEBUG_BOX"]?.split(separator: ",").compactMap({ Int($0) }), e.count == 4 {
                let b = PixelRect(x: e[0], y: e[1], w: e[2], h: e[3])
                for sd in seeds where sd.0.intersects(b) { print("  seed", sd.0) }
                for g in grown where g.0.intersects(b) { print("  grown", g.0) }
                let cx = (b.x + b.w / 2 - A.x) / 4, cy = (b.y + b.h / 2 - A.y) / 4
                print("  centre cell mark", mark[cy * cw + cx], "core", core[cy * cw + cx])
            }
        }
        // Lean toward finding: where growth absorbed much more than the photo-like core it started
        // from (a picture touching text or other content), the core is proposed as well.
        var cores: [(PixelRect, UInt8)] = []
        for (seed, src) in seeds where seed.shortSide >= config.minRegionSide {
            if let g = grown.first(where: { $0.0.intersection(seed).map { $0.area * 10 >= seed.area * 9 } ?? false }), g.0.area >= 2 * seed.area,
               let t = trim(img, seed) {
                cores.append((t, src))
            }
        }
        var regions: [Region] = []
        var seenRects = Set<PixelRect>()
        for (c, src) in cores where c.shortSide >= config.minRegionSide && !seenRects.contains(c) {
            seenRects.insert(c)
            regions.append(Region(rect: c, source: src == 2 ? .cellNet : .colourStats))
        }
        for (box, src) in grown {
            for leaf in xyCut(img, box, depth: 0) where leaf.shortSide >= config.minRegionSide && !seenRects.contains(leaf) {
                seenRects.insert(leaf)
                let s: Region.Source = src == 3 ? .both : (src == 2 ? .cellNet : .colourStats)
                regions.append(Region(rect: leaf, source: s))
            }
        }
        return Output(regions: regions, grids: Self.detectGrids(regions.map(\.rect)), cellsMarked: mark.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }, cellsTotal: cw * ch)
    }

    /// Merges grown regions that overlap by at least half of their union, as the vendored finder did: again and again, the
    /// first such pair in order (lowest first index, then lowest second) is merged into the first and the second removed,
    /// until none is left. It never starts over from the top: before row `i` no pair can merge, and a merge into row `t`
    /// can only make a pair with `t` itself out of the rows before it (the others are unchanged), so only those are looked
    /// at again before row `t` is read again from its start. The merges, and their order, are the same.
    static func mergeOverlapping(_ grown: inout [(PixelRect, UInt8)]) {
        @inline(__always) func mergeable(_ a: PixelRect, _ b: PixelRect) -> Bool {
            guard let inter = a.intersection(b) else { return false }
            return inter.area * 2 >= a.union(b).area
        }
        var i = 0
        while i < grown.count {
            var j = i + 1
            while j < grown.count {
                guard mergeable(grown[i].0, grown[j].0) else { j += 1; continue }
                grown[i] = (grown[i].0.union(grown[j].0), grown[i].1 | grown[j].1)
                grown.remove(at: j)
                // The first pair now is with the merged row, from a row before it, if any.
                var t = i
                while let k = (0..<t).first(where: { mergeable(grown[$0].0, grown[t].0) }) {
                    grown[k] = (grown[k].0.union(grown[t].0), grown[k].1 | grown[t].1)
                    grown.remove(at: t)
                    t = k
                }
                i = t
                j = i + 1
            }
            i += 1
        }
    }

    /// Marks the photo-like 4 px cells of `A` (bit 0 colour stats, bit 1 the cell net): an 8x8 window on a 4 px step is
    /// photo-like as `FinderConfig` says, and marks the four cells under it. Every pixel lies in up to four windows, so its
    /// 12-bit colour and its green second difference are worked out once, and the windows read them through raw pointers.
    /// The marks are exactly those of judging each window on its own pixels (`FinderEquivalenceTests`).
    func markCells(_ img: RGBAImage, _ A: PixelRect, cw: Int, ch: Int, into mark: inout [UInt8]) {
        let W = img.width, aw = A.w, ah = A.h
        var codes = [UInt16](repeating: 0, count: aw * ah)
        // |g(x) - 2 g(x-1) + g(x-2)| on the green channel, from the third column of A on (a window counts it from its own
        // third column on, so it never reaches left of the window).
        var second = [UInt16](repeating: 0, count: aw * ah)
        var seen = [UInt32](repeating: 0, count: 4096)
        var count = [UInt8](repeating: 0, count: 4096)
        var feat = [Float](repeating: 0, count: CellNet.inputCount)
        let minDistinct = config.minDistinct, maxDominant = config.maxDominant, minTexture = config.minTexture
        img.pixels.withUnsafeBufferPointer { px in
            codes.withUnsafeMutableBufferPointer { cp in
                second.withUnsafeMutableBufferPointer { sp in
                    for ly in 0..<ah {
                        var p = ((A.y + ly) * W + A.x) * 4
                        let o = ly * aw
                        var g1 = 0, g2 = 0
                        for lx in 0..<aw {
                            let r = Int(px[p]), g = Int(px[p + 1]), b = Int(px[p + 2])
                            cp[o + lx] = UInt16(((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4))
                            if lx >= 2 { sp[o + lx] = UInt16(abs(g - 2 * g1 + g2)) }
                            g2 = g1; g1 = g; p += 4
                        }
                    }
                }
            }
            codes.withUnsafeBufferPointer { cp in
            second.withUnsafeBufferPointer { sp in
            seen.withUnsafeMutableBufferPointer { sn in
            count.withUnsafeMutableBufferPointer { ct in
            mark.withUnsafeMutableBufferPointer { mk in
                var stamp: UInt32 = 0
                for wy in 0..<max(1, ch - 1) {
                    for wx in 0..<max(1, cw - 1) {
                        let lx0 = wx * 4, ly0 = wy * 4
                        let lx1 = min(lx0 + 8, aw), ly1 = min(ly0 + 8, ah)
                        if lx1 - lx0 < 4 || ly1 - ly0 < 4 { continue }
                        stamp &+= 1
                        var distinct = 0, dominant = 0, texture = 0
                        for ly in ly0..<ly1 {
                            let o = ly * aw
                            for lx in lx0..<lx1 {
                                let code = Int(cp[o + lx])
                                if sn[code] != stamp { sn[code] = stamp; ct[code] = 0; distinct += 1 }
                                ct[code] &+= 1
                                let c = Int(ct[code])
                                if c > dominant { dominant = c }
                            }
                            for lx in (lx0 + 2)..<lx1 { texture += Int(sp[o + lx]) }
                        }
                        let n = (lx1 - lx0) * (ly1 - ly0)
                        let tcount = (lx1 - lx0 - 2) * (ly1 - ly0)
                        let dom = Double(dominant) / Double(n)
                        let tex = tcount > 0 ? Double(texture) / Double(tcount) : 0
                        var bits: UInt8 = 0
                        if distinct >= minDistinct && dom <= maxDominant && tex >= minTexture { bits |= 1 }
                        if bits == 0, let net = cellNet, distinct >= 4, dom < 0.9 {
                            var lo = (255, 255, 255), hi = (0, 0, 0)
                            for y in (A.y + ly0)..<(A.y + ly1) {
                                for x in (A.x + lx0)..<(A.x + lx1) {
                                    let p = (y * W + x) * 4
                                    let r = Int(px[p]), g = Int(px[p + 1]), b = Int(px[p + 2])
                                    lo = (min(lo.0, r), min(lo.1, g), min(lo.2, b)); hi = (max(hi.0, r), max(hi.1, g), max(hi.2, b))
                                }
                            }
                            feat[0] = Float(distinct) / 64; feat[1] = Float(dom); feat[2] = Float(min(tex, 32) / 32)
                            feat[3] = Float(hi.0 - lo.0) / 255; feat[4] = Float(hi.1 - lo.1) / 255; feat[5] = Float(hi.2 - lo.2) / 255
                            if net.isPhoto(feat) { bits |= 2 }
                        }
                        if bits != 0 {
                            for dy in 0..<2 { for dx in 0..<2 where wx + dx < cw && wy + dy < ch { mk[(wy + dy) * cw + wx + dx] |= bits } }
                        }
                    }
                }
            }}}}}
        }
    }

    struct Components { var label: [Int32]; var boxes: [PixelRect]; var sources: [UInt8]; var firstCell: [Int] }

    /// 8-connected components over non-zero cells; boxes are in cell units.
    func components(_ m: [UInt8], _ cw: Int, _ ch: Int) -> Components {
        var label = [Int32](repeating: -1, count: cw * ch)
        var boxes: [PixelRect] = [], sources: [UInt8] = [], first: [Int] = []
        var stack: [Int] = []
        for i in 0..<(cw * ch) where m[i] != 0 && label[i] < 0 {
            let id = Int32(boxes.count)
            var minx = Int.max, miny = Int.max, maxx = 0, maxy = 0
            var src: UInt8 = 0
            stack.append(i); label[i] = id
            while let j = stack.popLast() {
                let x = j % cw, y = j / cw
                src |= m[j]
                minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < cw, ny < ch { let k = ny * cw + nx; if m[k] != 0 && label[k] < 0 { label[k] = id; stack.append(k) } }
                } }
            }
            boxes.append(PixelRect(x: minx, y: miny, w: maxx - minx + 1, h: maxy - miny + 1)); sources.append(src); first.append(i)
        }
        return Components(label: label, boxes: boxes, sources: sources, firstCell: first)
    }

    func cellRect(_ c: PixelRect, _ A: PixelRect, _ W: Int, _ H: Int) -> PixelRect {
        let r = PixelRect(x: A.x + c.x * 4, y: A.y + c.y * 4, w: c.w * 4, h: c.h * 4)
        return r.clamped(width: W, height: H) ?? r
    }

    func outerLimit(seedIn r: PixelRect, outer: [PixelRect]) -> PixelRect {
        outer.first { $0.intersection(r) != nil } ?? r
    }

    /// Extends each edge outward one line at a time while the next line (over the current span) is
    /// not plain, never beyond `limit` widened by 4 px; then trims plain edges.
    func grow(_ img: RGBAImage, _ r: PixelRect, limit: PixelRect) -> PixelRect {
        let m = max(config.growBeyondMarked, limit.shortSide / 2)
        let L = PixelRect(x: max(0, limit.x - m), y: max(0, limit.y - m), w: 0, h: 0)
        let LmaxX = min(img.width, limit.maxX + m), LmaxY = min(img.height, limit.maxY + m)
        var x0 = r.x, y0 = r.y, x1 = r.maxX, y1 = r.maxY
        // The page colour: what surrounds the whole marked group (its gutters and margins).
        let bg: (Int, Int, Int)? = nil
        // A side that stops at a plain line is asked again at every round while the other sides grow, over a span that
        // only widens. Each side keeps the colour range of the plain line it last saw, so it is asked again only about the
        // new pixels at the ends of its span: the same answer as reading the whole line (a line is plain when every channel
        // varies by at most `gutterTolerance` along it, whatever the order of its pixels).
        var left = PlainLine(), right = PlainLine(), top = PlainLine(), bottom = PlainLine()
        let tol = config.gutterTolerance, W = img.width
        var changed = true
        img.pixels.withUnsafeBufferPointer { px in
            while changed {
                changed = false
                if x0 > L.x && !left.plain(px, at: x0 - 1, from: y0, to: y1, base: (x0 - 1) * 4, step: W * 4, tol: tol) { x0 -= 1; changed = true }
                if x1 < LmaxX && !right.plain(px, at: x1, from: y0, to: y1, base: x1 * 4, step: W * 4, tol: tol) { x1 += 1; changed = true }
                if y0 > L.y && !top.plain(px, at: y0 - 1, from: x0, to: x1, base: (y0 - 1) * W * 4, step: 4, tol: tol) { y0 -= 1; changed = true }
                if y1 < LmaxY && !bottom.plain(px, at: y1, from: x0, to: x1, base: y1 * W * 4, step: 4, tol: tol) { y1 += 1; changed = true }
            }
        }
        return trim(img, PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0), bg: bg) ?? r
    }

    /// The last line one side of `grow` found plain: which line, the span read so far (`a..<b`), and its colour range.
    struct PlainLine {
        var line = Int.min, a = 0, b = 0
        var lo = (0, 0, 0), hi = (0, 0, 0)

        /// Whether line `line` is plain over `from..<to` (as `columnUniform` or `rowUniform` would say), reading only what
        /// it has not read yet when this is the line it found plain last time and its span has only widened. Pixel `i` of
        /// the line starts at byte `base + i * step`.
        mutating func plain(_ px: UnsafeBufferPointer<UInt8>, at line: Int, from: Int, to: Int, base: Int, step: Int, tol: Int) -> Bool {
            @inline(__always) func add(_ i: Int) -> Bool {
                let p = base + i * step
                let c = (Int(px[p]), Int(px[p + 1]), Int(px[p + 2]))
                lo = (min(lo.0, c.0), min(lo.1, c.1), min(lo.2, c.2)); hi = (max(hi.0, c.0), max(hi.1, c.1), max(hi.2, c.2))
                return hi.0 - lo.0 <= tol && hi.1 - lo.1 <= tol && hi.2 - lo.2 <= tol
            }
            if self.line == line && from <= a && b <= to && a < b {
                for i in from..<a where !add(i) { self.line = .min; return false }
                for i in b..<to where !add(i) { self.line = .min; return false }
            } else {
                // As `columnUniform`: the range starts at the first pixel of the span (read even for an empty span).
                let p0 = base + from * step
                lo = (Int(px[p0]), Int(px[p0 + 1]), Int(px[p0 + 2])); hi = lo
                for i in from..<to where !add(i) { self.line = .min; return false }
            }
            self.line = line; a = from; b = to
            return true
        }
    }

    /// Length of the plain vertical run through column x that contains rows y0..<y1 (0 if those rows are not plain).
    func verticalRun(_ img: RGBAImage, x: Int, y0: Int, y1: Int) -> Int {
        let tol = config.gutterRunTolerance, W = img.width, H = img.height
        return img.pixels.withUnsafeBufferPointer { px in
            let p0 = (y0 * W + x) * 4
            var lo = (Int(px[p0]), Int(px[p0 + 1]), Int(px[p0 + 2])), hi = lo
            func ok(_ y: Int) -> Bool {
                let p = (y * W + x) * 4
                let c = (Int(px[p]), Int(px[p + 1]), Int(px[p + 2]))
                let nlo = (min(lo.0, c.0), min(lo.1, c.1), min(lo.2, c.2)), nhi = (max(hi.0, c.0), max(hi.1, c.1), max(hi.2, c.2))
                if nhi.0 - nlo.0 > tol || nhi.1 - nlo.1 > tol || nhi.2 - nlo.2 > tol { return false }
                lo = nlo; hi = nhi; return true
            }
            for y in y0..<y1 where !ok(y) { return 0 }
            var a = y0, b = y1
            while a > 0 && b - a < 64 && ok(a - 1) { a -= 1 }
            while b < H && b - a < 64 && ok(b) { b += 1 }
            return b - a
        }
    }

    func horizontalRun(_ img: RGBAImage, y: Int, x0: Int, x1: Int) -> Int {
        let tol = config.gutterRunTolerance, W = img.width
        return img.pixels.withUnsafeBufferPointer { px in
            let p0 = (y * W + x0) * 4
            var lo = (Int(px[p0]), Int(px[p0 + 1]), Int(px[p0 + 2])), hi = lo
            func ok(_ x: Int) -> Bool {
                let p = (y * W + x) * 4
                let c = (Int(px[p]), Int(px[p + 1]), Int(px[p + 2]))
                let nlo = (min(lo.0, c.0), min(lo.1, c.1), min(lo.2, c.2)), nhi = (max(hi.0, c.0), max(hi.1, c.1), max(hi.2, c.2))
                if nhi.0 - nlo.0 > tol || nhi.1 - nlo.1 > tol || nhi.2 - nlo.2 > tol { return false }
                lo = nlo; hi = nhi; return true
            }
            for x in x0..<x1 where !ok(x) { return 0 }
            var a = x0, b = x1
            while a > 0 && b - a < 64 && ok(a - 1) { a -= 1 }
            while b < W && b - a < 64 && ok(b) { b += 1 }
            return b - a
        }
    }

    /// The commonest exact colour on the 1 px ring just outside `r` (the page around a picture), if that ring
    /// is mostly one colour (at least 40% of its pixels).
    func ringColour(_ img: RGBAImage, _ r: PixelRect) -> (Int, Int, Int)? {
        var counts: [Int: Int] = [:]
        var n = 0
        func add(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < img.width, y < img.height else { return }
            let p = (y * img.width + x) * 4
            counts[(Int(img.pixels[p]) << 16) | (Int(img.pixels[p + 1]) << 8) | Int(img.pixels[p + 2]), default: 0] += 1
            n += 1
        }
        let step = max(1, (r.w + r.h) / 256)
        for x in stride(from: r.x - 1, through: r.maxX, by: step) { add(x, r.y - 1); add(x, r.maxY) }
        for y in stride(from: r.y, to: r.maxY, by: step) { add(r.x - 1, y); add(r.maxX, y) }
        guard n > 0, let best = counts.max(by: { $0.value < $1.value }), best.value * 10 >= n * 4 else { return nil }
        return ((best.key >> 16) & 255, (best.key >> 8) & 255, best.key & 255)
    }

    /// Recursive XY-cut along lines (rows or columns) of uniform colour, then trimming uniform borders.
    func xyCut(_ img: RGBAImage, _ r: PixelRect, depth: Int, bg inherited: (Int, Int, Int)?? = nil) -> [PixelRect] {
        // Page-colour matching (ringColour) was tried and made real screens worse; plain lines of any colour cut.
        let bg: (Int, Int, Int)? = nil
        guard let t = trim(img, r, bg: bg) else { return [] }
        if depth > 12 || t.w < 2 * config.minRegionSide && t.h < 2 * config.minRegionSide { return [t] }
        for vertical in [true, false] {
            let n = vertical ? t.w : t.h
            var uniform = [Bool](repeating: false, count: n)
            for i in 0..<n { uniform[i] = vertical ? columnUniform(img, x: t.x + i, y0: t.y, y1: t.maxY, bg: bg) : rowUniform(img, y: t.y + i, x0: t.x, x1: t.maxX, bg: bg) }
            var parts: [PixelRect] = []
            var start: Int? = nil
            for i in 0...n {
                let u = i == n ? true : uniform[i]
                if !u && start == nil { start = i }
                if u, let s = start {
                    parts.append(vertical ? PixelRect(x: t.x + s, y: t.y, w: i - s, h: t.h) : PixelRect(x: t.x, y: t.y + s, w: t.w, h: i - s))
                    start = nil
                }
            }
            if parts.count > 1 { return parts.flatMap { xyCut(img, $0, depth: depth + 1, bg: .some(bg)) } }
        }
        return [t]
    }

    func trim(_ img: RGBAImage, _ r: PixelRect, bg: (Int, Int, Int)? = nil) -> PixelRect? {
        var x0 = r.x, x1 = r.maxX, y0 = r.y, y1 = r.maxY
        while x0 < x1 && columnUniform(img, x: x0, y0: y0, y1: y1, bg: bg) { x0 += 1 }
        while x1 > x0 && columnUniform(img, x: x1 - 1, y0: y0, y1: y1, bg: bg) { x1 -= 1 }
        while y0 < y1 && rowUniform(img, y: y0, x0: x0, x1: x1, bg: bg) { y0 += 1 }
        while y1 > y0 && rowUniform(img, y: y1 - 1, x0: x0, x1: x1, bg: bg) { y1 -= 1 }
        return x1 > x0 && y1 > y0 ? PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : nil
    }

    @inline(__always) func columnUniform(_ img: RGBAImage, x: Int, y0: Int, y1: Int, bg: (Int, Int, Int)? = nil) -> Bool {
        let tol = config.gutterTolerance, W = img.width
        return img.pixels.withUnsafeBufferPointer { px in
            let p0 = (y0 * W + x) * 4
            var lo = (Int(px[p0]), Int(px[p0 + 1]), Int(px[p0 + 2])), hi = lo
            if let b = bg, abs(lo.0 - b.0) > tol || abs(lo.1 - b.1) > tol || abs(lo.2 - b.2) > tol { return false }
            for y in y0..<y1 {
                let p = (y * W + x) * 4
                let c = (Int(px[p]), Int(px[p + 1]), Int(px[p + 2]))
                lo = (min(lo.0, c.0), min(lo.1, c.1), min(lo.2, c.2)); hi = (max(hi.0, c.0), max(hi.1, c.1), max(hi.2, c.2))
                if hi.0 - lo.0 > tol || hi.1 - lo.1 > tol || hi.2 - lo.2 > tol { return false }
            }
            return true
        }
    }

    @inline(__always) func rowUniform(_ img: RGBAImage, y: Int, x0: Int, x1: Int, bg: (Int, Int, Int)? = nil) -> Bool {
        let tol = config.gutterTolerance, W = img.width
        return img.pixels.withUnsafeBufferPointer { px in
            let p0 = (y * W + x0) * 4
            var lo = (Int(px[p0]), Int(px[p0 + 1]), Int(px[p0 + 2])), hi = lo
            if let b = bg, abs(lo.0 - b.0) > tol || abs(lo.1 - b.1) > tol || abs(lo.2 - b.2) > tol { return false }
            for x in x0..<x1 {
                let p = (y * W + x) * 4
                let c = (Int(px[p]), Int(px[p + 1]), Int(px[p + 2]))
                lo = (min(lo.0, c.0), min(lo.1, c.1), min(lo.2, c.2)); hi = (max(hi.0, c.0), max(hi.1, c.1), max(hi.2, c.2))
                if hi.0 - lo.0 > tol || hi.1 - lo.1 > tol || hi.2 - lo.2 > tol { return false }
            }
            return true
        }
    }

    /// Grids: at least 3 regions of near-equal size (within 3 px) that line up on rows or columns.
    public static func detectGrids(_ rects: [PixelRect], minMembers: Int = 3) -> [Grid] {
        var buckets: [String: [PixelRect]] = [:]
        for r in rects where r.shortSide >= 10 {
            buckets["\(r.w / 4)x\(r.h / 4)", default: []].append(r)
        }
        var grids: [Grid] = []
        for (_, group) in buckets where group.count >= minMembers {
            // Members must share a row (same y within 3 px) or a column with another member.
            let aligned = group.filter { a in group.contains { b in b != a && (abs(a.y - b.y) <= 3 || abs(a.x - b.x) <= 3) } }
            if aligned.count >= minMembers {
                let sorted = aligned.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
                let bounds = sorted.dropFirst().reduce(sorted[0]) { $0.union($1) }
                grids.append(Grid(members: sorted, cellSize: (sorted[0].w, sorted[0].h), bounds: bounds))
            }
        }
        return grids
    }
}
