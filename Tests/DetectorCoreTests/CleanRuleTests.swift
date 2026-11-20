// SPDX-License-Identifier: Apache-2.0
// The clean-cache rule switch (`VerdictCache.CleanRule`), used only by lab measurements: the default is unchanged,
// only stricter rules can be set, and each knob (margin, checks, sticky) acts as described. Set outcomes and set
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

    func testTheDefaultIsUnchanged() {
        XCTAssertEqual(VerdictCache.CleanRule.standard, .init(margin: 0.5, checks: 2, sticky: false))
        XCTAssertEqual(VerdictCache().rule, .standard)
        let c = Cutoffs(cover: 0.8, clean: 0.3, strike: 0.95, gridMember: 0.3, gridLow: 0.2)
        XCTAssertEqual(VerdictCache.cleanLevel(c, containable: false), 0.4)
        XCTAssertEqual(VerdictCache.cleanLevel(c, containable: false, margin: 0.25), 0.2)
    }

    func testOnlyAStricterRuleCanBeSet() {
        let c = VerdictCache()
        XCTAssertFalse(c.setRule(.init(margin: 0.6, checks: 2, sticky: false)), "a higher margin is refused")
        XCTAssertFalse(c.setRule(.init(margin: 0.5, checks: 1, sticky: false)), "fewer checks are refused")
        XCTAssertFalse(c.setRule(.init(margin: .nan, checks: 2, sticky: false)))
        XCTAssertFalse(c.setRule(.init(margin: -0.1, checks: 2, sticky: false)))
        XCTAssertEqual(c.rule, .standard, "a refused rule changes nothing")
        XCTAssertTrue(c.setRule(.init(margin: 0.2, checks: 3, sticky: true)))
        XCTAssertEqual(c.rule, .init(margin: 0.2, checks: 3, sticky: true))
    }

    func testSettingARuleEmptiesTheCache() {
        let c = VerdictCache()
        c.put(key(), clean()); c.put(key(), clean())
        XCTAssertNotNil(c.get(key()))
        c.setRule(.init(margin: 0.4, checks: 2, sticky: false))
        XCTAssertNil(c.checks(key()))
    }

    func testThreeChecksNeedThreeInARow() {
        let c = VerdictCache()
        c.setRule(.init(margin: 0.5, checks: 3, sticky: false))
        c.put(key(), clean()); c.put(key(), clean())
        XCTAssertNil(c.get(key()), "two are not enough")
        XCTAssertTrue(c.seenCleanOnce(key()), "still waiting for a check")
        c.put(key(), clean())
        XCTAssertNotNil(c.get(key()))
        XCTAssertEqual(c.get(key())?.settledForBlur, true)
    }

    func testRestartStartsAgainAfterABorderlineJudgement() {
        let c = VerdictCache()
        c.put(key(), clean()); c.put(key(), borderline); c.put(key(), clean())
        XCTAssertNil(c.get(key()))
        c.put(key(), clean())
        XCTAssertNotNil(c.get(key()), "today's rule: two in a row after the borderline one cache it")
    }

    func testStickyNeverCachesAPictureOnceBorderline() {
        let c = VerdictCache()
        c.setRule(.init(margin: 0.5, checks: 2, sticky: true))
        c.put(key(), clean()); c.put(key(), borderline)
        for _ in 0..<10 { c.put(key(), clean()) }
        XCTAssertNil(c.get(key()), "once borderline, never cached clean while held")
        XCTAssertTrue(c.isStuck(key()))
        XCTAssertFalse(c.seenCleanOnce(key()), "no background second checks for it")
        c.forget(key())
        c.put(key(), clean()); c.put(key(), clean())
        XCTAssertNil(c.get(key()), "a model failure keeps the mark")
        // A picture clearly clean from the start is cached as usual.
        c.put(key(1), clean()); c.put(key(1), clean())
        XCTAssertNotNil(c.get(key(1)))
    }

    func testStickyKeepsAPictureNotSettledForABlurUnsettled() {
        let c = VerdictCache()
        c.setRule(.init(margin: 0.5, checks: 2, sticky: true))
        c.put(key(), clean(settled: false))
        c.put(key(), clean()); c.put(key(), clean())
        XCTAssertEqual(c.get(key())?.settledForBlur, false, "reused where no blur applies, never settled for one")
    }

    func testStickyAfterACoverStaysUncached() {
        let c = VerdictCache()
        c.setRule(.init(margin: 0.5, checks: 2, sticky: true))
        c.put(key(), cover)
        XCTAssertEqual(c.get(key())?.covering, true, "a cover is reused at once")
        c.put(key(), clean()); c.put(key(), clean())
        XCTAssertNil(c.get(key()), "once flagged, never cached clean while held")
    }

    /// Through the detector: a lower margin makes a score that was clearly clean borderline.
    func testALowerMarginReachesTheJudgement() {
        var m: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb"] {
            m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, Cutoffs(cover: 0.5, clean: 0.5, strike: 0.95, gridMember: 0.3, gridLow: 0.2)) })
        }
        func run(_ margin: Float?) -> Bool {
            let fa = FaultyModel(id: "fa", family: .a, score: 0.2), fb = FaultyModel(id: "fb", family: .b, score: 0.2)
            let d = Detector(models: ModelSet(models: [fa, fb], bundleVersion: "rule"), table: ThresholdTable(schema: "test", models: m),
                             config: DetectorConfig(), finder: RegionFinder())
            if let margin { XCTAssertTrue(d.cache.setRule(.init(margin: margin, checks: 2, sticky: false))) }
            var i = canvas(400, 300)
            paint(&i, PixelRect(x: 60, y: 60, w: 96, h: 96), channel: nil, seed: 5)
            let ctx = JudgeContext(windowID: 1, startsCovered: false)
            for _ in 0..<3 { _ = d.judge(i, context: ctx) }
            return d.timings.cacheHits > 0
        }
        XCTAssertTrue(run(nil), "0.2 is under half of 0.5: cached after two checks")
        XCTAssertFalse(run(0.3), "0.2 is not under 0.3 of 0.5 (0.15): never cached")
    }
}
