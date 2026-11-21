// SPDX-License-Identifier: Apache-2.0
// The picture finder was made cheaper for energy (docs/ENERGY.md). What it proposes decides what reaches the models, so it
// must propose exactly what it did before, rectangle for rectangle and in the same order: these tests run the finder and
// the vendored original (`ReferenceFinder`) on many synthetic screens and areas and compare everything they return.
// Synthetic patterns only.
import Foundation
import XCTest
@testable import Preprocess
@testable import RegionFinder

final class FinderEquivalenceTests: XCTestCase {
    /// A synthetic screen: a flat page, text-like bars, photo-like noise patches, smooth ramps, few-colour blocks, a grid of
    /// thumbnails with thin gutters, and near-flat areas (within the gutter tolerance), placed from `seed`.
    static func scene(_ w: Int, _ h: Int, seed: UInt32) -> RGBAImage {
        var g = XorShift32(seed: seed)
        func rnd(_ n: Int) -> Int { n <= 0 ? 0 : Int(g.next() % UInt32(n)) }
        let bg = UInt8(200 + rnd(56))
        var img = RGBAImage(width: w, height: h, pixels: (0..<(w * h * 4)).map { $0 % 4 == 3 ? 255 : bg })
        func put(_ x: Int, _ y: Int, _ r: Int, _ gg: Int, _ b: Int) {
            guard x >= 0, y >= 0, x < w, y < h else { return }
            let p = (y * w + x) * 4
            img.pixels[p] = UInt8(clamping: r); img.pixels[p + 1] = UInt8(clamping: gg); img.pixels[p + 2] = UInt8(clamping: b)
        }
        for _ in 0..<(3 + rnd(10)) {
            let rw = 4 + rnd(w / 2), rh = 4 + rnd(h / 2), rx = rnd(w) - 4, ry = rnd(h) - 4
            switch rnd(7) {
            case 0:  // noise patch (photo-like)
                let base = rnd(120)
                for y in ry..<(ry + rh) { for x in rx..<(rx + rw) { let n = rnd(90); put(x, y, base + n, base + n / 2 + rnd(40), base + rnd(90)) } }
            case 1:  // smooth ramp
                for y in ry..<(ry + rh) { for x in rx..<(rx + rw) { put(x, y, (x - rx) * 255 / max(1, rw), (y - ry) * 255 / max(1, rh), 128) } }
            case 2:  // text-like bars
                var y = ry
                while y < ry + rh { for yy in y..<(y + 2 + rnd(4)) { for x in rx..<(rx + rw) where rnd(5) != 0 { put(x, yy, 40, 40, 50) } }; y += 6 + rnd(8) }
            case 3:  // a few colours
                let cols = (0..<(2 + rnd(6))).map { _ in (rnd(256), rnd(256), rnd(256)) }
                for y in ry..<(ry + rh) { for x in rx..<(rx + rw) { let c = cols[(((x - rx) / 3) + ((y - ry) / 5)) % cols.count]; put(x, y, c.0, c.1, c.2) } }
            case 4:  // a grid of thumbnails with thin gutters
                let side = 12 + rnd(30), gap = 1 + rnd(4)
                for ty in 0..<(1 + rnd(4)) { for tx in 0..<(1 + rnd(5)) {
                    let ox = rx + tx * (side + gap), oy = ry + ty * (side + gap)
                    for y in oy..<(oy + side) { for x in ox..<(ox + side) { put(x, y, rnd(256), rnd(256), rnd(256)) } }
                } }
            case 5:  // near-flat (varies within the gutter tolerance)
                let c = rnd(250)
                for y in ry..<(ry + rh) { for x in rx..<(rx + rw) { put(x, y, c + rnd(3), c + rnd(3), c + rnd(3)) } }
            default:  // textured stripes (low distinct colours, some texture: the cell net's ground)
                for y in ry..<(ry + rh) { for x in rx..<(rx + rw) { let v = (x % 4 < 2 ? 60 : 180) + rnd(12); put(x, y, v, v + 10, v - 10) } }
            }
        }
        return img
    }

    func assertSame(_ a: RegionFinder.Output, _ b: ReferenceFinder.Output, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.regions.map(\.rect), b.regions.map(\.rect), "regions: \(what)", file: file, line: line)
        XCTAssertEqual(a.regions.map(\.source.rawValue), b.regions.map(\.source.rawValue), "sources: \(what)", file: file, line: line)
        XCTAssertEqual(a.grids.map(\.members), b.grids.map(\.members), "grids: \(what)", file: file, line: line)
        XCTAssertEqual(a.grids.map(\.bounds), b.grids.map(\.bounds), "grid bounds: \(what)", file: file, line: line)
        XCTAssertEqual(a.cellsMarked, b.cellsMarked, "cells marked: \(what)", file: file, line: line)
        XCTAssertEqual(a.cellsTotal, b.cellsTotal, "cells: \(what)", file: file, line: line)
    }

    func testTheFinderProposesExactlyWhatTheOriginalDid() {
        let finder = RegionFinder(), reference = ReferenceFinder()
        var g = XorShift32(seed: 2026)
        var regions = 0
        for seed in UInt32(1)...60 {
            let w = 40 + Int(g.next() % 300), h = 30 + Int(g.next() % 220)
            let img = Self.scene(w, h, seed: seed)
            assertSame(finder.find(img), reference.find(img), "seed \(seed), whole \(w)x\(h)")
            regions += finder.find(img).regions.count
            // Areas inside the frame, at its edges and partly outside it (clamped).
            for _ in 0..<4 {
                let a = PixelRect(x: Int(g.next() % UInt32(w)) - 8, y: Int(g.next() % UInt32(h)) - 8,
                                  w: 1 + Int(g.next() % UInt32(w)), h: 1 + Int(g.next() % UInt32(h)))
                guard a.clamped(width: w, height: h) != nil else { continue }
                assertSame(finder.find(img, within: a), reference.find(img, within: a), "seed \(seed), area \(a)")
            }
        }
        XCTAssertGreaterThan(regions, 200, "the scenes hold pictures to find")
    }

    func testTheSameWithoutTheCellNetAndWithOtherSettings() {
        var c = FinderConfig()
        c.useCellNet = false
        var c2 = FinderConfig()
        c2.minDistinct = 6; c2.maxDominant = 0.6; c2.minTexture = 3
        for config in [c, c2] {
            let finder = RegionFinder(config: config), reference = ReferenceFinder(config: config)
            for seed in UInt32(100)...120 {
                let img = Self.scene(180, 140, seed: seed)
                assertSame(finder.find(img), reference.find(img), "seed \(seed)")
            }
        }
    }

    func testTinyFramesAndAreas() {
        let finder = RegionFinder(), reference = ReferenceFinder()
        for (w, h) in [(1, 1), (3, 2), (4, 4), (5, 9), (8, 8), (9, 4), (12, 7), (17, 33)] {
            let img = Self.scene(w, h, seed: UInt32(w * 31 + h))
            assertSame(finder.find(img), reference.find(img), "\(w)x\(h)")
            assertSame(finder.find(img, within: PixelRect(x: w / 2, y: h / 2, w: w, h: h)),
                       reference.find(img, within: PixelRect(x: w / 2, y: h / 2, w: w, h: h)), "\(w)x\(h), corner")
        }
    }

    /// Video-like content: a frame of fresh noise over a page, as the energy harness plays it.
    func testVideoLikeNoiseOverAPage() {
        let finder = RegionFinder(), reference = ReferenceFinder()
        var img = Self.scene(400, 260, seed: 9)
        var g = XorShift32(seed: 5)
        for frame in 0..<3 {
            for y in 40..<200 { for x in 60..<340 {
                let p = (y * 400 + x) * 4, n = Int(g.next() % 70)
                img.pixels[p] = UInt8(60 + n + frame); img.pixels[p + 1] = UInt8(90 + n); img.pixels[p + 2] = UInt8(80 + n)
            } }
            let a = PixelRect(x: 60, y: 40, w: 280, h: 160)
            assertSame(finder.find(img, within: a), reference.find(img, within: a), "frame \(frame)")
            assertSame(finder.find(img), reference.find(img), "frame \(frame), whole")
        }
    }

    /// The merge of grown regions on its own, against the vendored loop, on crowded random rectangles (many merges, chains
    /// of merges, and merges that make an earlier pair mergeable).
    func testMergingOverlapsIsTheSame() {
        func reference(_ g: [(PixelRect, UInt8)]) -> [(PixelRect, UInt8)] {
            var grown = g
            var merged = true
            while merged {
                merged = false
                outerLoop: for i in grown.indices {
                    for j in grown.indices where j > i {
                        if let inter = grown[i].0.intersection(grown[j].0), inter.area * 2 >= grown[i].0.union(grown[j].0).area {
                            grown[i] = (grown[i].0.union(grown[j].0), grown[i].1 | grown[j].1)
                            grown.remove(at: j)
                            merged = true
                            break outerLoop
                        }
                    }
                }
            }
            return grown
        }
        var g = XorShift32(seed: 31)
        var merges = 0
        for round in 0..<300 {
            let n = 2 + Int(g.next() % 60), span = 40 + Int(g.next() % 400)
            var rects: [(PixelRect, UInt8)] = []
            for _ in 0..<n {
                rects.append((PixelRect(x: Int(g.next() % UInt32(span)), y: Int(g.next() % UInt32(span)),
                                        w: 1 + Int(g.next() % 120), h: 1 + Int(g.next() % 120)), UInt8(1 + g.next() % 3)))
            }
            var fast = rects
            RegionFinder.mergeOverlapping(&fast)
            let slow = reference(rects)
            merges += rects.count - slow.count
            XCTAssertEqual(fast.map(\.0), slow.map(\.0), "round \(round)")
            XCTAssertEqual(fast.map(\.1), slow.map(\.1), "round \(round)")
        }
        XCTAssertGreaterThan(merges, 400, "the rounds merge a lot")
    }
}
