// SPDX-License-Identifier: Apache-2.0
// The clean-cache rule (`VerdictCache.CleanRule`): the default (sticky, margin 0.25, three checks), the lab switch that
// sets only stricter rules (lab builds only), and how each knob (margin, checks, sticky) acts, the sticky marks' own
// bounded set and what a rule change or an eviction does to them included. Set outcomes and set
// scores only, on synthetic pixels.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

final class CleanRuleTests: XCTestCase {
    let img = canvas(64, 64)
    func key(_ i: Int = 0) -> ExactKey { VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 8 + i, h: 8), pass: "region", version: "v") }
    func clean(settled: Bool = true) -> TileOutcome {
        var o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false, cacheable: true)
        o.settledForBlur = settled
        return o
    }
    var borderline: TileOutcome { TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false) }
    var cover: TileOutcome {
        var o = TileOutcome(flagA: true, flagB: true, strikeBoth: false, clean: false, gridMember: false, gridLow: false, forced: false, cacheable: true)
        o.covering = true; o.settledForBlur = true
        return o
    }

    func testTheDefaultIsStickyWithThreeChecks() {
        XCTAssertEqual(VerdictCache.CLEAN_CACHE_MARGIN, 0.25)
        XCTAssertEqual(VerdictCache.CLEAN_CHECKS, 3)
        XCTAssertTrue(VerdictCache.CLEAN_STICKY)
        XCTAssertEqual(VerdictCache.CleanRule.standard, .init(margin: 0.25, checks: 3, sticky: true))
        XCTAssertEqual(VerdictCache().rule, .standard, "every build starts with the standard rule")
        let c = Cutoffs(cover: 0.8, clean: 0.3, strike: 0.95, gridMember: 0.3, gridLow: 0.2)
        XCTAssertEqual(VerdictCache.cleanLevel(c, containable: false), 0.2)
        XCTAssertEqual(VerdictCache.cleanLevel(c, containable: false, margin: 0.125), 0.1)
    }

    #if KESTREL_LAB
    func testOnlyAStricterRuleCanBeSet() {
        let c = VerdictCache()
        XCTAssertFalse(c.setRule(.init(margin: 0.3, checks: 3, sticky: true)), "a higher margin is refused")
        XCTAssertFalse(c.setRule(.init(margin: 0.5, checks: 3, sticky: true)), "the old margin is refused")
        XCTAssertFalse(c.setRule(.init(margin: 0.25, checks: 2, sticky: true)), "fewer checks are refused")
        XCTAssertFalse(c.setRule(.init(margin: 0.25, checks: 3, sticky: false)), "restarting instead of sticky is refused")
        XCTAssertFalse(c.setRule(.init(margin: .nan, checks: 3, sticky: true)))
        XCTAssertFalse(c.setRule(.init(margin: -0.1, checks: 3, sticky: true)))
        XCTAssertEqual(c.rule, .standard, "a refused rule changes nothing")
        XCTAssertTrue(c.setRule(.init(margin: 0.2, checks: 4, sticky: true)))
        XCTAssertEqual(c.rule, .init(margin: 0.2, checks: 4, sticky: true))
    }

    func testSettingARuleEmptiesTheCache() {
        let c = VerdictCache()
        for _ in 0..<3 { c.put(key(), clean()) }
        XCTAssertNotNil(c.get(key()))
        XCTAssertTrue(c.setRule(.init(margin: 0.2, checks: 3, sticky: true)))
        XCTAssertNil(c.checks(key()))
    }
    #endif

    func testThreeChecksNeedThreeInARow() {
        let c = VerdictCache()
        c.put(key(), clean()); c.put(key(), clean())
        XCTAssertNil(c.get(key()), "two are not enough")
        XCTAssertTrue(c.seenCleanOnce(key()), "still waiting for a check")
        c.put(key(), clean())
        XCTAssertFalse(c.seenCleanOnce(key()), "no longer waiting")
        XCTAssertNotNil(c.get(key()))
        XCTAssertEqual(c.get(key())?.settledForBlur, true)
    }

    func testAPictureOnceBorderlineIsNeverCachedClean() {
        let c = VerdictCache()
        c.put(key(), clean()); c.put(key(), borderline)
        for _ in 0..<10 { c.put(key(), clean()) }
        XCTAssertNil(c.get(key()), "once borderline, never cached clean while held")
        XCTAssertTrue(c.isStuck(key()))
        XCTAssertFalse(c.seenCleanOnce(key()), "never queued for more background checks")
        c.forget(key())
        for _ in 0..<3 { c.put(key(), clean()) }
        XCTAssertNil(c.get(key()), "a model failure keeps the mark")
        XCTAssertTrue(c.isStuck(key()))
        // A picture clearly clean from the start is cached as usual.
        for _ in 0..<3 { c.put(key(1), clean()) }
        XCTAssertNotNil(c.get(key(1)))
    }

    func testABorderlineFirstJudgementMarksAtOnce() {
        let c = VerdictCache()
        c.put(key(), borderline)
        XCTAssertTrue(c.isStuck(key()))
        XCTAssertFalse(c.seenCleanOnce(key()))
        for _ in 0..<3 { c.put(key(), clean()) }
        XCTAssertNil(c.get(key()))
    }

    func testAPictureNotSettledForABlurStaysUnsettled() {
        let c = VerdictCache()
        c.put(key(), clean(settled: false))
        for _ in 0..<3 { c.put(key(), clean()) }
        XCTAssertEqual(c.get(key())?.settledForBlur, false, "reused where no blur applies, never settled for one")
    }

    func testAfterACoverItStaysUncached() {
        let c = VerdictCache()
        c.put(key(), cover)
        XCTAssertEqual(c.get(key())?.covering, true, "a cover is reused at once")
        for _ in 0..<3 { c.put(key(), clean()) }
        XCTAssertNil(c.get(key()), "once flagged, never cached clean while held")
    }

    /// The marks live in their own bounded set. Dropping one gives only fresh first chances: the pixels are judged again
    /// as if never seen, need `CLEAN_CHECKS` clearly clean judgements in a row, and a borderline one marks them again.
    func testADroppedMarkGivesOnlyFreshFirstChances() {
        let c = VerdictCache(capacity: 8, markCapacity: 8)
        c.put(key(), borderline)
        XCTAssertTrue(c.isStuck(key()))
        for i in 1...40 { c.put(key(i), borderline) }   // pushes the mark out, oldest first
        XCTAssertFalse(c.isStuck(key()), "dropped")
        XCTAssertNil(c.checks(key()), "dropped: nothing is held for these pixels")
        XCTAssertNil(c.get(key()), "dropped is never reused: it is judged again")
        c.put(key(), clean()); c.put(key(), clean())
        XCTAssertNil(c.get(key()), "fresh first chances: two are not enough")
        c.put(key(), borderline)
        XCTAssertTrue(c.isStuck(key()), "a borderline one marks it again")
        for _ in 0..<3 { c.put(key(), clean()) }
        XCTAssertNil(c.get(key()))
        // Emptied of counts and verdicts (a detector rule change): the mark stays.
        c.removeAll()
        XCTAssertTrue(c.isStuck(key()))
        for _ in 0..<3 { c.put(key(), clean()) }
        XCTAssertNil(c.get(key()))
        // Emptied of everything (lab benches only): fresh first chances again.
        c.removeEverything()
        XCTAssertFalse(c.isStuck(key()))
        for _ in 0..<2 { c.put(key(), clean()) }
        XCTAssertNil(c.get(key()))
    }

    func testTheMarksAreBounded() {
        let c = VerdictCache(capacity: 64, markCapacity: 64)
        let img = canvas(64, 64)
        for i in 0..<5_000 {
            c.put(VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 1 + i % 64, h: 1 + (i / 64) % 64), pass: "region", version: "v"), borderline)
            XCTAssertLessThanOrEqual(c.markCount, 64)
        }
        XCTAssertEqual(VerdictCache().markCapacity, 65_536)
        XCTAssertLessThanOrEqual(VerdictCache.defaultMarkCapacity * VerdictCache.bytesPerEntry, 4 << 20, "the marks stay under about 4 MB")
    }

    /// Switching Balanced and Either empties the counts and verdicts, but never the marks: a mark comes from a score
    /// against a cut-off, which neither rule changes, so a switch gives no borderline picture a fresh first chance.
    func testAMarkSurvivesARuleSwitch() {
        var m: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb"] {
            m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, Cutoffs(cover: 0.5, clean: 0.5, strike: 0.95, gridMember: 0.3, gridLow: 0.2)) })
        }
        let fa = FaultyModel(id: "fa", family: .a, score: 0.3), fb = FaultyModel(id: "fb", family: .b, score: 0.05)
        let d = Detector(models: ModelSet(models: [fa, fb], bundleVersion: "switch"), table: ThresholdTable(schema: "test", models: m),
                         config: DetectorConfig(), finder: RegionFinder())
        var i = canvas(400, 300)
        let r = PixelRect(x: 60, y: 60, w: 96, h: 96)
        paint(&i, r, channel: nil, seed: 5)
        let ctx = JudgeContext(windowID: 1, startsCovered: false)
        let k = VerdictCache.key(i, r, pass: "region", version: "switch")
        _ = d.judge(i, context: ctx)                     // 0.3: clean, but not under a quarter of 0.5
        XCTAssertTrue(d.cache.isStuck(k))
        d.setRule(.either); d.setRule(.balanced)
        XCTAssertTrue(d.cache.isStuck(k), "the mark survives Balanced to Either to Balanced")
        fa.score = 0.05
        d.resetTimings()
        for _ in 0..<(VerdictCache.CLEAN_CHECKS + 2) { _ = d.judge(i, context: ctx) }
        XCTAssertNil(d.cache.get(k), "never cached clean, however many clean judgements follow the switch")
        // Counts and verdicts are still cleared by a switch: another picture, cached clean, is judged again after it.
        var j = canvas(400, 300)
        paint(&j, r, channel: nil, seed: 9)
        for _ in 0..<VerdictCache.CLEAN_CHECKS { _ = d.judge(j, context: ctx) }
        XCTAssertEqual(d.judge(j, context: ctx).judgements, 0)
        d.setRule(.either)
        XCTAssertGreaterThan(d.judge(j, context: ctx).judgements, 0, "a switch clears the counts and verdicts")
    }

    #if KESTREL_LAB
    /// Through the detector: a lower margin makes a score that was clearly clean borderline.
    func testALowerMarginReachesTheJudgement() {
        var m: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb"] {
            m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, Cutoffs(cover: 0.5, clean: 0.5, strike: 0.95, gridMember: 0.3, gridLow: 0.2)) })
        }
        func run(_ margin: Float?) -> Bool {
            let fa = FaultyModel(id: "fa", family: .a, score: 0.1), fb = FaultyModel(id: "fb", family: .b, score: 0.1)
            let d = Detector(models: ModelSet(models: [fa, fb], bundleVersion: "rule"), table: ThresholdTable(schema: "test", models: m),
                             config: DetectorConfig(), finder: RegionFinder())
            if let margin { XCTAssertTrue(d.cache.setRule(.init(margin: margin, checks: 3, sticky: true))) }
            var i = canvas(400, 300)
            paint(&i, PixelRect(x: 60, y: 60, w: 96, h: 96), channel: nil, seed: 5)
            let ctx = JudgeContext(windowID: 1, startsCovered: false)
            for _ in 0..<4 { _ = d.judge(i, context: ctx) }
            return d.timings.cacheHits > 0
        }
        XCTAssertTrue(run(nil), "0.1 is under a quarter of 0.5: cached after three checks")
        XCTAssertFalse(run(0.15), "0.1 is not under 0.15 of 0.5 (0.075): never cached")
    }
    #endif
}
