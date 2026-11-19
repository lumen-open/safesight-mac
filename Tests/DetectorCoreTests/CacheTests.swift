// SPDX-License-Identifier: Apache-2.0
// The verdict cache and the finder cache (SafeSight Mac). A cached verdict, and above all a clean one, is
// reused only on an exact match of a tile's pixels and size; the memory is bounded; the finder's cached
// proposals are exactly what the finder would propose. Synthetic patterns only.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

final class CacheTests: XCTestCase {
    func noise(_ w: Int, _ h: Int, seed: UInt32) -> RGBAImage {
        var g = XorShift32(seed: seed)
        return RGBAImage(width: w, height: h, pixels: (0..<(w * h * 4)).map { i in i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: g.next()) })
    }

    // MARK: The exact key

    func testTheKeyIsExactAndIgnoresOnlyThePosition() {
        var img = noise(200, 120, seed: 1)
        // The same 40 x 30 pixels at two places.
        let a = PixelRect(x: 10, y: 10, w: 40, h: 30), b = PixelRect(x: 120, y: 70, w: 40, h: 30)
        for y in 0..<30 { for x in 0..<40 { for c in 0..<4 {
            img.pixels[((b.y + y) * 200 + b.x + x) * 4 + c] = img.pixels[((a.y + y) * 200 + a.x + x) * 4 + c]
        } } }
        let k = VerdictCache.key(img, a, pass: "region", version: "v1")
        XCTAssertEqual(k, VerdictCache.key(img, b, pass: "region", version: "v1"), "same pixels and size, other place: same key")
        XCTAssertNotEqual(k, VerdictCache.key(img, a, pass: "whole", version: "v1"), "pass is part of the key")
        XCTAssertNotEqual(k, VerdictCache.key(img, a, pass: "region", version: "v2"), "bundle version is part of the key")
        XCTAssertNotEqual(k, VerdictCache.key(img, PixelRect(x: 10, y: 10, w: 30, h: 40), pass: "region", version: "v1"), "size is part of the key")
        // Any single byte of any channel, including alpha, changes the key.
        for c in 0..<4 {
            var m = img
            let p = ((a.y + 29) * 200 + a.x + 39) * 4 + c
            m.pixels[p] ^= 1
            XCTAssertNotEqual(k, VerdictCache.key(m, a, pass: "region", version: "v1"), "channel \(c)")
        }
    }

    func testAKeyUsesTheFullDigest() {
        // Two keys that agree on their first 128 bits are still different keys.
        let x = ExactKey(bytes: Array(repeating: 7, count: 32))
        let y = ExactKey(bytes: Array(repeating: 7, count: 16) + Array(repeating: 9, count: 16))
        XCTAssertNotEqual(x, y)
    }

    // MARK: Reuse only on an exact match

    func testACleanVerdictIsReusedOnlyForTheSamePixels() {
        var img = canvas(400, 300)
        let r = PixelRect(x: 60, y: 60, w: 96, h: 96)
        paint(&img, r, channel: nil, seed: 5)   // harmless: judged clean
        let (d, a, _) = detector()
        let first = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false))
        XCTAssertGreaterThan(first.judgements, 0)
        let calls = a.calls
        XCTAssertEqual(d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)).judgements, 0, "the same pixels are not judged again")
        XCTAssertEqual(a.calls, calls)
        // One pixel of the picture changes by one level: judged again, never inherited.
        var near = img
        near.pixels[((r.y + 40) * 400 + r.x + 40) * 4] &+= 1
        XCTAssertGreaterThan(d.judge(near, context: JudgeContext(windowID: 1, startsCovered: false)).judgements, 0)
    }

    func testAFlaggedPictureNeverInheritsACleanVerdict() {
        // A harmless picture is judged clean and cached; a flagged picture drawn in its place, same size and
        // place, is covered.
        var img = canvas(400, 300)
        let r = PixelRect(x: 60, y: 60, w: 120, h: 120)
        paint(&img, r, channel: nil, seed: 6)
        let (d, _, _) = detector()
        XCTAssertFalse(d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)).regions.contains { $0.display == .cover })
        var flagged = img
        paint(&flagged, PixelRect(x: r.x, y: r.y, w: 60, h: 120), channel: 0, seed: 7)
        paint(&flagged, PixelRect(x: r.x + 60, y: r.y, w: 60, h: 120), channel: 2, seed: 8)
        let v = d.judge(flagged, context: JudgeContext(windowID: 1, startsCovered: false))
        XCTAssertTrue(v.regions.contains { $0.display == .cover && $0.rect.intersects(r) })
    }

    func testAMovedPictureIsNotJudgedAgain() {
        var img = canvas(600, 400)
        let r = PixelRect(x: 60, y: 60, w: 96, h: 96)
        paint(&img, r, channel: nil, seed: 5)
        let (d, _, _) = detector()
        _ = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false), within: PixelRect(x: 40, y: 40, w: 160, h: 160))
        // The same content, 200 pixels to the right (a window moved): every entry comes from the cache.
        var moved = canvas(600, 400)
        paint(&moved, PixelRect(x: 260, y: 60, w: 96, h: 96), channel: nil, seed: 5)
        let v = d.judge(moved, context: JudgeContext(windowID: 1, startsCovered: false), within: PixelRect(x: 240, y: 40, w: 160, h: 160))
        XCTAssertEqual(v.judgements, 0)
        XCTAssertTrue(v.regions.contains { $0.rect == PixelRect(x: 260, y: 60, w: 96, h: 96) })
    }

    // MARK: Memory bound and eviction

    func testTheCacheIsBounded() {
        let c = VerdictCache(capacity: 64)
        XCTAssertEqual(c.maxBytes, 64 * VerdictCache.bytesPerEntry)
        let img = noise(64, 64, seed: 3)
        let o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false)
        for i in 0..<5_000 {
            c.put(VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 1 + i % 64, h: 1 + (i / 64) % 64), pass: "region", version: "v"), o)
            XCTAssertLessThanOrEqual(c.count, 64)
        }
        XCTAssertLessThanOrEqual(VerdictCache.defaultCapacity * VerdictCache.bytesPerEntry, 4 << 20, "the default stays under about 4 MB")
    }

    func testRecentlyUsedEntriesSurvive() {
        let c = VerdictCache(capacity: 64)
        let img = noise(64, 64, seed: 3)
        let o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false)
        let kept = VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 64, h: 64), pass: "region", version: "v")
        c.put(kept, o)
        for i in 0..<2_000 {
            c.put(VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 1 + i % 63, h: 1 + i / 63), pass: "slice", version: "v"), o)
            if i % 16 == 0 { XCTAssertNotNil(c.get(kept), "used often, so kept (step \(i))") }
        }
        // An entry nobody asks for again is dropped.
        let once = VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 5, h: 5), pass: "whole", version: "v")
        c.put(once, o)
        for i in 0..<200 { c.put(VerdictCache.key(img, PixelRect(x: 1, y: 1, w: 1 + i % 60, h: 1 + i / 60), pass: "region", version: "v"), o) }
        XCTAssertNil(c.get(once))
    }

    // MARK: The finder cache is exact

    func page(_ w: Int, _ h: Int, seed: UInt32) -> RGBAImage {
        var img = canvas(w, h)
        var g = XorShift32(seed: seed)
        for i in 0..<6 {
            let s = min(30 + Int(g.next() % 90), w / 3 - 24, h / 2 - 24)
            paint(&img, PixelRect(x: 20 + (i % 3) * (w / 3), y: 20 + (i / 3) * (h / 2), w: s, h: s), channel: nil, seed: seed &+ UInt32(i))
        }
        return img
    }

    func testCachedFinderProposalsAreExactlyTheFindersAtTheSamePlace() {
        let (d, _, _) = detector()
        let img = page(600, 400, seed: 11)
        for area in [PixelRect(x: 0, y: 0, w: 600, h: 400), PixelRect(x: 16, y: 8, w: 300, h: 200), PixelRect(x: 200, y: 100, w: 64, h: 64)] {
            let fresh = d.finder.find(img, within: area).regions.map(\.rect)
            let k = FinderCache.key(img, area)
            XCTAssertNil(d.finderCache.get(k, for: area))
            d.finderCache.put(k, area, d.finder.find(img, within: area))
            XCTAssertEqual(d.finderCache.get(k, for: area)?.regions.map(\.rect), fresh)
        }
    }

    func testCachedFinderProposalsFollowTheSameContentElsewhere() {
        // A 300 x 200 window of content on a plain page, at two places with the same surroundings.
        let content = page(300, 200, seed: 12)
        func scene(_ ox: Int, _ oy: Int) -> RGBAImage {
            var img = canvas(900, 700)
            for y in 0..<200 { for x in 0..<300 { for c in 0..<4 {
                img.pixels[((oy + y) * 900 + ox + x) * 4 + c] = content.pixels[(y * 300 + x) * 4 + c]
            } } }
            return img
        }
        let (d, _, _) = detector()
        let a = PixelRect(x: 200, y: 200, w: 300, h: 200), b = PixelRect(x: 380, y: 260, w: 300, h: 200)
        let one = scene(a.x, a.y), two = scene(b.x, b.y)
        let ka = FinderCache.key(one, a), kb = FinderCache.key(two, b)
        XCTAssertEqual(ka, kb, "same pixels everywhere the finder can read")
        d.finderCache.put(ka, a, d.finder.find(one, within: a))
        XCTAssertEqual(d.finderCache.get(kb, for: b)?.regions.map(\.rect), d.finder.find(two, within: b).regions.map(\.rect))
        // A change inside the finder's reach but outside the area: a different key, so the finder runs.
        var three = two
        let p = ((b.y - 20) * 900 + b.x + 50) * 4
        three.pixels[p] &+= 9
        XCTAssertNotEqual(FinderCache.key(three, b), kb)
        // A change beyond its reach does not matter to the finder, nor to the key.
        var four = two
        four.pixels[((b.y - FinderCache.reach(b) - 5) * 900 + b.x) * 4] &+= 9
        XCTAssertEqual(FinderCache.key(four, b), kb)
        XCTAssertEqual(d.finder.find(four, within: b).regions.map(\.rect), d.finder.find(two, within: b).regions.map(\.rect))
    }

    func testJudgingWithTheFinderCacheGivesTheSameEntries() {
        // The same frame judged twice: the second call reuses the finder and every verdict, and its entries
        // are the first call's.
        let img = page(800, 500, seed: 13)
        let (d, _, _) = detector()
        let one = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false))
        let two = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false))
        XCTAssertEqual(d.timings.finderCacheHits, 1)
        XCTAssertEqual(one.regions.map(\.rect), two.regions.map(\.rect))
        XCTAssertEqual(one.regions.map(\.display), two.regions.map(\.display))
        XCTAssertEqual(two.judgements, 0)
    }
}
