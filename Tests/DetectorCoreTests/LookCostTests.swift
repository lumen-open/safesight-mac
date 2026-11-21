// SPDX-License-Identifier: Apache-2.0
// What a look at a still screen costs besides its judgements (docs/ENERGY.md): the watcher judges the same last frame
// again and again while covers wait to lift, one judge call per window and per cover. Each call used to find the pictures
// again and hash every entry again. The finder cache must hold a whole look's calls, and the exact keys are worked out
// once per frame. Neither may change a key or a verdict: a key is reused only for the very same pixel storage, and any
// changed pixel gets its own full hash. Synthetic patterns only.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

final class LookCostTests: XCTestCase {
    func frame(_ w: Int, _ h: Int, seed: UInt32) -> RGBAImage {
        var img = canvas(w, h)
        var g = XorShift32(seed: seed)
        for i in 0..<40 {
            let r = PixelRect(x: (i % 8) * (w / 8) + 4, y: (i / 8) * (h / 5) + 4, w: 20 + Int(g.next() % 30), h: 20 + Int(g.next() % 30))
            paint(&img, r, channel: nil, seed: seed &+ UInt32(i))
        }
        return img
    }

    /// The areas one look judges: a call per window and per cover, more than the old finder cache could hold (32).
    func areas(_ w: Int, _ h: Int) -> [PixelRect] {
        (0..<60).map { i in PixelRect(x: (i % 10) * (w / 10), y: (i / 10) * (h / 6), w: w / 10, h: h / 6) }
    }

    func testASecondLookFindsEveryCallInTheFinderCache() {
        let img = frame(1000, 600, seed: 3)
        let (d, _, _) = detector()
        let ctx = JudgeContext(windowID: 1, startsCovered: false)
        let first = areas(1000, 600).map { d.judge(img, context: ctx, within: $0, budget: 0) }
        d.resetTimings()
        let second = areas(1000, 600).map { d.judge(img, context: ctx, within: $0, budget: 0) }
        XCTAssertEqual(d.timings.finderCacheHits, 60, "every call of the second look reuses the finder's proposals")
        XCTAssertEqual(first.map { $0.regions.map(\.rect) }, second.map { $0.regions.map(\.rect) })
        XCTAssertEqual(first.map { $0.regions.map(\.display) }, second.map { $0.regions.map(\.display) })
    }

    func testFrameKeysAreTheFullHashOfTheSamePixels() {
        var img = frame(400, 300, seed: 5)
        let memo = FrameKeys()
        let rects = [PixelRect(x: 0, y: 0, w: 400, h: 300), PixelRect(x: 10, y: 20, w: 37, h: 41), PixelRect(x: 399, y: 299, w: 1, h: 1)]
        for r in rects {
            XCTAssertEqual(memo.key(img, r, header: [1, 2], tag: "t"), ExactKey.of(img, r, header: [1, 2], tag: "t"))
            XCTAssertEqual(memo.key(img, r, header: [1, 2], tag: "t"), ExactKey.of(img, r, header: [1, 2], tag: "t"), "from the memo")
            XCTAssertEqual(memo.key(img, r, header: [1, 3], tag: "t"), ExactKey.of(img, r, header: [1, 3], tag: "t"), "the header is part of it")
            XCTAssertEqual(memo.key(img, r, header: [1, 2], tag: "u"), ExactKey.of(img, r, header: [1, 2], tag: "u"), "the tag is part of it")
        }
        XCTAssertGreaterThan(memo.hits, 0)
        // One pixel changed in place, in the same variable: its own full hash, never the memo's.
        let before = memo.key(img, rects[1], header: [1, 2], tag: "t")
        img.pixels[(25 * 400 + 15) * 4] ^= 1
        let after = memo.key(img, rects[1], header: [1, 2], tag: "t")
        XCTAssertEqual(after, ExactKey.of(img, rects[1], header: [1, 2], tag: "t"))
        XCTAssertNotEqual(after, before, "a changed pixel is a new key")
        // Another frame with the same pixels gets the same key (the hash, not the storage, decides).
        let copy = RGBAImage(width: 400, height: 300, pixels: Array(img.pixels))
        XCTAssertEqual(memo.key(copy, rects[1], header: [1, 2], tag: "t"), after)
    }

    func testTheJudgeHashesAStillFrameOnce() {
        let img = frame(800, 500, seed: 9)
        let (d, _, _) = detector()
        let ctx = JudgeContext(windowID: 1, startsCovered: false)
        let one = d.judge(img, context: ctx, budget: 0)
        let misses = d.frameKeys.misses
        let two = d.judge(img, context: ctx, budget: 0)
        XCTAssertEqual(d.frameKeys.misses, misses, "the same frame again: no pixel is hashed twice")
        XCTAssertEqual(one.regions.map(\.rect), two.regions.map(\.rect))
        // A new frame (one pixel changed) is hashed afresh, and its changed entries are new to the caches.
        var changed = img
        changed.pixels[(30 * 800 + 30) * 4] ^= 1
        _ = d.judge(changed, context: ctx, budget: 0)
        XCTAssertGreaterThan(d.frameKeys.misses, misses)
    }

    /// Two displays settling at once: their looks take turns, and each display's frame keeps its keys.
    func testTwoDisplaysTakingTurnsKeepTheirKeys() {
        let one = frame(600, 400, seed: 1), two = frame(500, 300, seed: 2)
        let memo = FrameKeys()
        let r = PixelRect(x: 5, y: 5, w: 100, h: 80)
        _ = memo.key(one, r, header: [], tag: "t"); _ = memo.key(two, r, header: [], tag: "t")
        let misses = memo.misses
        for _ in 0..<5 {
            XCTAssertEqual(memo.key(one, r, header: [], tag: "t"), ExactKey.of(one, r, header: [], tag: "t"))
            XCTAssertEqual(memo.key(two, r, header: [], tag: "t"), ExactKey.of(two, r, header: [], tag: "t"))
        }
        XCTAssertEqual(memo.misses, misses, "both frames' keys are kept")
        // A new frame of one display's size takes that display's place; the other keeps its keys.
        var next = one
        next.pixels[0] ^= 1
        XCTAssertEqual(memo.key(next, r, header: [], tag: "t"), ExactKey.of(next, r, header: [], tag: "t"))
        let after = memo.misses
        _ = memo.key(two, r, header: [], tag: "t")
        XCTAssertEqual(memo.misses, after)
    }
}
