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
        // The safety rule: a harmless picture is judged clean and cached; a flagged picture drawn in its place,
        // same size and place, is judged afresh, and nothing over it comes from the cache.
        // Whether it is then covered is the models' call, not the cache's. So the cut-offs here (0.3) sit far
        // below the flagged picture's score for each family (0.47 to 0.5 over 2,000 jitter draws). At a
        // cut-off of 0.5, jitter put both families just under it about one run in 30.
        var img = canvas(400, 300)
        let r = PixelRect(x: 60, y: 60, w: 120, h: 120)
        paint(&img, r, channel: nil, seed: 6)
        let (d, _, _) = detector(cover: 0.3)
        let ctx = JudgeContext(windowID: 1, startsCovered: false)
        let first = d.judge(img, context: ctx)
        XCTAssertGreaterThan(first.judgements, 0)
        XCTAssertFalse(first.regions.contains { $0.display != .clear }, "the harmless picture is judged clean")
        XCTAssertEqual(d.judge(img, context: ctx).judgements, 0, "and its clean verdict is cached")
        var flagged = img
        paint(&flagged, PixelRect(x: r.x, y: r.y, w: 60, h: 120), channel: 0, seed: 7)
        paint(&flagged, PixelRect(x: r.x + 60, y: r.y, w: 60, h: 120), channel: 2, seed: 8)
        d.resetTimings()
        let v = d.judge(flagged, context: ctx)
        XCTAssertGreaterThan(v.judgements, 0, "the changed picture is judged afresh")
        XCTAssertEqual(d.timings.cacheHits, 0, "no entry of the changed frame comes from the cache")
        XCTAssertEqual(v.overloaded, 0, "every entry was judged")
        XCTAssertFalse(v.regions.contains { $0.rect.intersects(r) && $0.reason == .cached && $0.display == .clear },
                       "no region over it carries a cached clean verdict")
        XCTAssertTrue(v.regions.contains { $0.display == .cover && $0.rect.intersects(r) }, "far above the cut-offs, it is covered")
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
        let o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false, cacheable: true)
        for i in 0..<5_000 {
            c.put(VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 1 + i % 64, h: 1 + (i / 64) % 64), pass: "region", version: "v"), o)
            XCTAssertLessThanOrEqual(c.count, 64)
        }
        XCTAssertLessThanOrEqual(VerdictCache.defaultCapacity * VerdictCache.bytesPerEntry, 4 << 20, "the default stays under about 4 MB")
    }

    func testRecentlyUsedEntriesSurvive() {
        let c = VerdictCache(capacity: 64)
        let img = noise(64, 64, seed: 3)
        let o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false, cacheable: true)
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

/// A fake model whose score the test sets, whatever the pixels and the jitter, so the margin tests are
/// deterministic with no change to jitter.
final class SetScoreModel: ScoringModel {
    let id: String, family: Family, side = 32
    var score: Float
    var calls = 0
    init(id: String, family: Family, score: Float) { self.id = id; self.family = family; self.score = score }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] {
        calls += tensors.count
        return tensors.map { _ in score }
    }
}

/// The margin rule for caching (SafeSight Mac): a clean outcome is cached only when every model scored it
/// below `CLEAN_CACHE_MARGIN` of its lowest action cut-off for the size band (cover, or containment where a
/// blur can apply); a borderline-clean one is judged again each time it comes back; an outcome that covers is
/// cached. Synthetic patterns and set scores only.
final class CleanCacheMarginTests: XCTestCase {
    let ctx = JudgeContext(windowID: 1, startsCovered: false)
    /// A neutral 96 x 96 picture on a 400 x 300 frame: one region (band 64-127) and the whole pass (128+).
    let r = PixelRect(x: 60, y: 60, w: 96, h: 96)
    var img: RGBAImage {
        var i = canvas(400, 300)
        paint(&i, r, channel: nil, seed: 5)
        return i
    }

    /// Cut-offs for "fa", "fb" and the tie-breaker "fr": `cover` in every band, or `byBand` where given. The
    /// containment cut-off is `clean`, or else the cover cut-off, so that it does not lower the margin.
    func cutoffs(_ cover: Float = 0.5, clean: Float? = nil, byBand: [Band: Float] = [:]) -> ThresholdTable {
        var m: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb", "fr"] {
            m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map {
                ($0.rawValue, Cutoffs(cover: byBand[$0] ?? cover, clean: clean ?? byBand[$0] ?? cover, strike: 0.95, gridMember: 0.3, gridLow: 0.2))
            })
        }
        return ThresholdTable(schema: "test", models: m)
    }

    func scored(_ a: Float, _ b: Float, referee: Float? = nil, table: ThresholdTable? = nil, rule: DetectorRule = .balanced)
        -> (Detector, SetScoreModel, SetScoreModel, SetScoreModel?) {
        let fa = SetScoreModel(id: "fa", family: .a, score: a), fb = SetScoreModel(id: "fb", family: .b, score: b)
        let fr = referee.map { SetScoreModel(id: "fr", family: .b, score: $0) }
        var cfg = DetectorConfig(); cfg.rule = rule
        let d = Detector(models: ModelSet(models: [fa, fb], referee: fr, bundleVersion: "margin"), table: table ?? cutoffs(),
                         config: cfg, finder: RegionFinder())
        return (d, fa, fb, fr)
    }

    func over(_ v: FrameVerdict) -> RegionVerdict? { v.regions.first { $0.pass == .region && $0.rect.intersects(r) } }

    func testTheMarginIsHalfTheLowestActionCutOff() {
        XCTAssertEqual(VerdictCache.CLEAN_CACHE_MARGIN, 0.5)
        let c = Cutoffs(cover: 0.8, clean: 0.3, strike: 0.9, gridMember: 0.8, gridLow: 0.8)
        XCTAssertEqual(VerdictCache.actionCutoff(c, containable: true), 0.3, "where a blur can apply, containment acts first")
        XCTAssertEqual(VerdictCache.actionCutoff(c, containable: false), 0.8)
        XCTAssertEqual(VerdictCache.cleanLevel(c, containable: true), 0.15)
        XCTAssertEqual(VerdictCache.cleanLevel(c, containable: false), 0.4)
        // A containment cut-off above the cover cut-off never raises the level.
        let high = Cutoffs(cover: 0.5, clean: 0.7, strike: 0.9, gridMember: 0.5, gridLow: 0.5)
        XCTAssertEqual(VerdictCache.cleanLevel(high, containable: true), 0.25)
    }

    func testASmallPictureJustUnderTheContainmentCutOffIsJudgedAgainAndCanBeBlurred() {
        // The region (96 px) can be blurred in a hot window, and its containment cut-off (0.3) is under its cover
        // cut-off (0.5). Family A scores 0.2: under both, so it is shown, but not under half the containment
        // cut-off (0.15). Before, only the cover cut-off counted (0.2 < 0.25), so it was cached and never blurred.
        let (d, fa, _, _) = scored(0.2, 0, table: cutoffs(0.5, clean: 0.3))
        let first = d.judge(img, context: ctx)
        XCTAssertEqual(over(first)?.display, .clear)
        XCTAssertEqual(first.judgements, 4, "the region and the whole pass, two models each")
        d.resetTimings()
        let again = d.judge(img, context: ctx)
        XCTAssertEqual(again.judgements, 2, "the region is judged again; the whole pass, which no blur applies to, is cached")
        XCTAssertEqual(d.timings.cacheHits, 1)
        // The window turns hot, and the next fresh judgement lands just over the containment cut-off: blurred.
        d.hot.mark(ctx.windowID, ctx.now)
        fa.score = 0.35
        let hot = d.judge(img, context: ctx)
        XCTAssertGreaterThan(hot.judgements, 0)
        XCTAssertEqual(over(hot)?.display, .contain, "a borderline small picture gets another chance to be blurred")
        XCTAssertEqual(over(hot)?.reason, .hotContext)
    }

    func testOnlyPictureRegionsThatCanBeBlurredAreHeldToTheContainmentCutOff() {
        // 0.1 is under half of both cut-offs (0.3 and 0.5): the small picture is cached.
        let (d, _, _, _) = scored(0.1, 0.1, table: cutoffs(0.5, clean: 0.3))
        _ = d.judge(img, context: ctx)
        XCTAssertEqual(d.judge(img, context: ctx).judgements, 0, "clearly clean for both actions: cached")
        // A 160-pixel picture is never blurred (128 and up), so only its cover cut-off counts: 0.2 is under half
        // of it (0.25), though over its containment cut-off (0.1). The same for the whole pass.
        var big = canvas(400, 300)
        let rb = PixelRect(x: 60, y: 60, w: 160, h: 160)
        paint(&big, rb, channel: nil, seed: 5)
        let (e, _, _, _) = scored(0.2, 0.2, table: cutoffs(0.5, clean: 0.1))
        let first = e.judge(big, context: ctx)
        XCTAssertEqual(first.regions.filter { $0.pass == .region }.map(\.rect), [rb], "one region, as the setup expects")
        XCTAssertFalse(first.regions.contains { $0.display != .clear })
        XCTAssertEqual(e.judge(big, context: ctx).judgements, 0, "cached")
        // The same scores on the 96-pixel picture, which can be blurred: it is judged again, the whole pass is not.
        let (f, _, _, _) = scored(0.2, 0.2, table: cutoffs(0.5, clean: 0.1))
        _ = f.judge(img, context: ctx)
        XCTAssertEqual(f.judge(img, context: ctx).judgements, 2)
    }

    func testABorderlineCleanOutcomeIsNotCachedAndIsJudgedAgain() {
        // Both families score 0.4 against a cut-off of 0.5: clean, but not clearly (0.4 >= 0.25).
        let (d, fa, fb, _) = scored(0.4, 0.4)
        let first = d.judge(img, context: ctx)
        XCTAssertEqual(over(first)?.display, .clear)
        XCTAssertGreaterThan(first.judgements, 0)
        d.resetTimings()
        let calls = fa.calls
        let again = d.judge(img, context: ctx)
        XCTAssertEqual(again.judgements, first.judgements, "the same pixels are judged again, every entry")
        XCTAssertEqual(d.timings.cacheHits, 0)
        XCTAssertGreaterThan(fa.calls, calls)
        // The next fresh judgement goes the other way (as jitter can make it): the same pixels are now covered.
        fa.score = 0.6; fb.score = 0.6
        let third = d.judge(img, context: ctx)
        XCTAssertGreaterThan(third.judgements, 0)
        XCTAssertEqual(over(third)?.display, .cover, "a borderline picture gets another chance to be caught")
        XCTAssertEqual(over(third)?.reason, .bothFamilies)
    }

    func testAClearlyCleanOutcomeIsCached() {
        let (d, fa, fb, _) = scored(0.1, 0.2)
        let first = d.judge(img, context: ctx)
        XCTAssertEqual(over(first)?.display, .clear)
        XCTAssertGreaterThan(first.judgements, 0)
        let calls = (fa.calls, fb.calls)
        d.resetTimings()
        let again = d.judge(img, context: ctx)
        XCTAssertEqual(again.judgements, 0, "every entry comes from the cache")
        XCTAssertEqual(d.timings.cacheMisses, 0)
        XCTAssertEqual(fa.calls, calls.0); XCTAssertEqual(fb.calls, calls.1)
        XCTAssertEqual(over(again)?.display, .clear)
    }

    func testEveryModelMustBeBelowTheMarginStrictly() {
        // (family A, family B, cached?) against a cut-off of 0.5, so the margin is 0.25. A score that is not a
        // number is no clean score at all: it is a model failure, never clear and never cached (ModelFaultTests).
        for (a, b, cached) in [(Float(0.1), Float(0.2499), true), (0.1, 0.25, false), (0.25, 0.1, false), (0, 0.49, false),
                               (0.49, 0, false), (0, 0, true)] {
            let (d, _, _, _) = scored(a, b)
            let first = d.judge(img, context: ctx)
            XCTAssertEqual(over(first)?.display, .clear, "\(a), \(b): clean either way")
            let again = d.judge(img, context: ctx)
            XCTAssertEqual(again.judgements == 0, cached, "\(a), \(b)")
        }
    }

    func testTheMarginUsesEachSizeBandsCutOff() {
        // The region (96 px, band 64-127) has a cut-off of 0.9; the whole pass (300 px, band 128+) one of 0.3.
        // A score of 0.2 is clearly clean for the region (below 0.45) but not for the whole pass (0.15).
        let (d, _, _, _) = scored(0.2, 0.2, table: cutoffs(byBand: [.b64: 0.9, .b128: 0.3]))
        let first = d.judge(img, context: ctx)
        XCTAssertFalse(first.regions.contains { $0.display != .clear })
        XCTAssertEqual(first.regions.filter { $0.pass == .region }.map(\.rect), [r], "one region, as the setup expects")
        XCTAssertEqual(first.judgements, 4, "the region and the whole pass, two models each")
        d.resetTimings()
        let again = d.judge(img, context: ctx)
        XCTAssertEqual(d.timings.cacheHits, 1, "the region comes from the cache")
        XCTAssertEqual(again.judgements, 2, "the whole pass is judged again")
    }

    func testACoveredOutcomeIsCached() {
        // Both families agree; a dispute nobody could settle; under Either, one family's flag.
        for (a, b, rule, reason) in [(Float(0.9), Float(0.9), DetectorRule.balanced, Reason.bothFamilies),
                                     (0.9, 0, .balanced, .disputed), (0, 0.9, .either, .referee)] {
            let (d, fa, _, _) = scored(a, b, rule: rule)
            let first = d.judge(img, context: ctx)
            XCTAssertEqual(over(first)?.display, .cover, "\(rule) \(reason)")
            XCTAssertEqual(over(first)?.reason, reason)
            let calls = fa.calls
            // Even if a fresh judgement would now clear it, the same pixels stay covered from the cache.
            fa.score = 0
            let again = d.judge(img, context: ctx)
            XCTAssertEqual(again.judgements, 0, "\(rule) \(reason): cached")
            XCTAssertEqual(fa.calls, calls)
            XCTAssertEqual(over(again)?.display, .cover)
            XCTAssertEqual(over(again)?.reason, reason)
        }
    }

    func testADisputeTheTieBreakerDeclinedIsJudgedAgain() {
        // Family A flags, family B does not, the tie-breaker declines: shown clear, but not clearly clean.
        let (d, _, _, fr) = scored(0.9, 0, referee: 0)
        let first = d.judge(img, context: ctx)
        XCTAssertEqual(over(first)?.display, .clear)
        let asked = fr!.calls
        XCTAssertGreaterThan(asked, 0)
        XCTAssertGreaterThan(d.judge(img, context: ctx).judgements, 0, "judged again")
        XCTAssertGreaterThan(fr!.calls, asked, "the tie-breaker is asked again")
        fr!.score = 0.9
        let third = d.judge(img, context: ctx)
        XCTAssertEqual(over(third)?.display, .cover)
        XCTAssertEqual(over(third)?.reason, .referee)
    }

    func testTheCacheRefusesAnOutcomeNotMarkedCacheable() {
        let c = VerdictCache(capacity: 64)
        let k = VerdictCache.key(img, r, pass: "region", version: "v")
        var o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false)
        c.put(k, o)
        XCTAssertNil(c.get(k), "not marked: not kept")
        o.cacheable = true
        c.put(k, o)
        XCTAssertEqual(c.get(k), o)
    }
}

/// The slice grid anchored to the content (SafeSight Mac): with no anchor it is the lab build's grid; with
/// one, it still covers every pixel of the area with the same overlap, and it is at most one slice longer
/// per axis.
final class SliceGridTests: XCTestCase {
    /// The lab build's grid, as it was.
    func labSlices(_ area: PixelRect, size: Int, stride: Int) -> [PixelRect] {
        if area.w <= size && area.h <= size { return [] }
        func starts(_ len: Int) -> [Int] {
            if len <= size { return [0] }
            var s = Array(Swift.stride(from: 0, through: len - size, by: stride))
            if s.last! != len - size { s.append(len - size) }
            return s
        }
        var out: [PixelRect] = []
        for y in starts(area.h) { for x in starts(area.w) {
            out.append(PixelRect(x: area.x + x, y: area.y + y, w: min(size, area.w), h: min(size, area.h)))
        } }
        return out
    }

    func testNoAnchorIsTheLabGrid() {
        for (w, h) in [(513, 300), (2880, 1800), (1000, 1000), (600, 2000), (512, 513)] {
            let a = PixelRect(x: 7, y: 3, w: w, h: h)
            XCTAssertEqual(Detector.slices(a, size: 512, stride: 384), labSlices(a, size: 512, stride: 384))
        }
    }

    func testAnAnchoredGridCoversEverythingWithTheSameOverlap() {
        var g = XorShift32(seed: 21)
        for _ in 0..<300 {
            let a = PixelRect(x: Int(g.next() % 400), y: Int(g.next() % 400), w: 300 + Int(g.next() % 2800), h: 300 + Int(g.next() % 2000))
            let anchor = SliceAnchor(x: Int(g.next() % 4000) - 2000, y: Int(g.next() % 4000) - 2000)
            let s = Detector.slices(a, size: 512, stride: 384, anchor: anchor)
            let lab = labSlices(a, size: 512, stride: 384)
            if lab.isEmpty { XCTAssertTrue(s.isEmpty); continue }
            for r in s { XCTAssertEqual(r.intersection(a), r, "inside the area") }
            // Per axis: sorted starts begin at the edge, end at the far edge, and step by at most `stride`.
            for (starts, lo, len) in [(Set(s.map(\.x)).sorted(), a.x, a.w), (Set(s.map(\.y)).sorted(), a.y, a.h)] {
                let side = min(512, len)
                XCTAssertEqual(starts.first, lo)
                XCTAssertEqual(starts.last! + side, lo + len)
                for (p, q) in zip(starts, starts.dropFirst()) { XCTAssertLessThanOrEqual(q - p, 384, "overlap at least 128") }
            }
            let cols = Set(s.map(\.x)).count, rows = Set(s.map(\.y)).count
            XCTAssertLessThanOrEqual(cols, Set(lab.map(\.x)).count + 1)
            XCTAssertLessThanOrEqual(rows, Set(lab.map(\.y)).count + 1)
            XCTAssertEqual(s.count, cols * rows)
        }
    }

    func testScrolledSlicesComeFromTheCache() {
        // A tall page; a 600 x 1300 view of it, then the view 100 pixels further down. With the grid moved
        // with the content, the inner slice rows of the second view have the same pixels as slices of the
        // first (the edge rows are new either way).
        var tall = canvas(600, 1500)
        var g = XorShift32(seed: 4)
        for i in 0..<14 { paint(&tall, PixelRect(x: 20 + Int(g.next() % 380), y: i * 100 + 10, w: 150, h: 50), channel: nil, seed: UInt32(30 + i)) }
        func view(_ off: Int) -> RGBAImage {
            RGBAImage(width: 600, height: 1300, pixels: Array(tall.pixels[(off * 600 * 4)..<((off + 1300) * 600 * 4)]))
        }
        func secondCall(anchored: Bool) -> Int {
            let (d, _, _) = detector()
            _ = d.judge(view(0), context: JudgeContext(windowID: 1, startsCovered: false, sliceAnchor: anchored ? SliceAnchor(x: 0, y: 0) : nil))
            d.resetTimings()
            _ = d.judge(view(100), context: JudgeContext(windowID: 1, startsCovered: false, sliceAnchor: anchored ? SliceAnchor(x: 0, y: -100) : nil))
            return d.timings.tiles.values.reduce(0, +)
        }
        let plain = secondCall(anchored: false), anchored = secondCall(anchored: true)
        XCTAssertLessThan(anchored, plain, "anchored: \(anchored) tiles judged, unanchored: \(plain)")
    }
}
