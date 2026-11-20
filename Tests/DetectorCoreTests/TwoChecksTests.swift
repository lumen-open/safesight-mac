// SPDX-License-Identifier: Apache-2.0
// Clean checks before a clean verdict is reused (SafeSight Mac). A picture is remembered as clean only after
// `CLEAN_CHECKS` (3) judgements in a row, each with fresh jitter, all come out clearly clean (under
// `CLEAN_CACHE_MARGIN` of the cut-off that acts there). Until then it is waiting for clean checks, never reused. A
// judgement at or over the margin, or a flag, marks it as never to be cached clean while held (`CLEAN_STICKY`); a
// model failure starts the count again. (Two checks, restarting, were the rule first; the file keeps its name.)
// Synthetic patterns and set scores only.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

/// A fake model that gives the next score of `sequence` (then `rest`) to every picture whose colour channel
/// `channel` dominates (its mean at least 60 over each other channel's), and 0 to anything else, whatever the
/// jitter. It stands in for a model whose score jitter moves from one judgement to the next.
final class SequenceModel: ScoringModel {
    let id: String, family: Family, side = 32
    let channel: Int
    var sequence: [Float]
    var rest: Float
    var calls = 0
    init(id: String, family: Family, channel: Int, sequence: [Float], rest: Float = 0) {
        self.id = id; self.family = family; self.channel = channel; self.sequence = sequence; self.rest = rest
    }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] {
        let n = side * side
        return tensors.map { t in
            let mean = (0..<3).map { c in Double((0..<n).reduce(0) { $0 + Int(t[c * n + $1]) }) / Double(n) }
            guard (0..<3).allSatisfy({ $0 == channel || mean[channel] >= mean[$0] + 60 }) else { return 0 }
            calls += 1
            return sequence.isEmpty ? rest : sequence.removeFirst()
        }
    }
}

final class TwoCleanChecksTests: XCTestCase {
    let ctx = JudgeContext(windowID: 1, startsCovered: false)
    /// A neutral 96 x 96 picture on a 400 x 300 frame: one region (band 64-127) and the whole pass (128+).
    let r = PixelRect(x: 60, y: 60, w: 96, h: 96)
    var img: RGBAImage {
        var i = canvas(400, 300)
        paint(&i, r, channel: nil, seed: 5)
        return i
    }

    func cutoffs(_ cover: Float = 0.5, clean: Float? = nil, ids: [String] = ["fa", "fb", "fr"]) -> ThresholdTable {
        var m: [String: [String: Cutoffs]] = [:]
        for id in ids {
            m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map {
                ($0.rawValue, Cutoffs(cover: cover, clean: clean ?? cover, strike: 0.95, gridMember: 0.3, gridLow: 0.2))
            })
        }
        return ThresholdTable(schema: "test", models: m)
    }

    func scored(_ a: Float, _ b: Float, table: ThresholdTable? = nil, budget: Int = 400) -> (Detector, FaultyModel, FaultyModel) {
        let fa = FaultyModel(id: "fa", family: .a, score: a), fb = FaultyModel(id: "fb", family: .b, score: b)
        var cfg = DetectorConfig(); cfg.maxJudgementsPerCall = budget
        return (Detector(models: ModelSet(models: [fa, fb], bundleVersion: "two"), table: table ?? cutoffs(), config: cfg, finder: RegionFinder()), fa, fb)
    }

    func over(_ v: FrameVerdict) -> RegionVerdict? { v.regions.first { $0.pass == .region && $0.rect == r } }
    func regionKey(_ d: Detector) -> ExactKey { VerdictCache.key(img, r, pass: "region", version: "two") }

    // MARK: One lucky low score is not enough

    func testOneClearlyCleanJudgementNeverYieldsACachedClean() {
        let (d, fa, _) = scored(0.1, 0.1)
        let first = d.judge(img, context: ctx)
        XCTAssertEqual(over(first)?.display, .clear, "shown on its real clean verdict")
        XCTAssertEqual(first.judgements, 4, "the region and the whole pass, two models each")
        let k = regionKey(d)
        XCTAssertTrue(d.cache.seenCleanOnce(k), "kept as seen clean once")
        XCTAssertNil(d.cache.get(k), "and that is never handed back as a clean verdict")
        let calls = fa.calls
        d.resetTimings()
        let second = d.judge(img, context: ctx)
        XCTAssertEqual(second.judgements, 4, "the same pixels are judged again, with fresh jitter")
        XCTAssertEqual(d.timings.cacheHits, 0)
        XCTAssertEqual(fa.calls - calls, 2, "family A judged the region and the whole pass again, one piece each")
    }

    func testEveryClearlyCleanJudgementInARowIsNeededBeforeReuse() {
        let (d, fa, _) = scored(0.1, 0.2)
        for _ in 1..<VerdictCache.CLEAN_CHECKS {
            XCTAssertEqual(d.judge(img, context: ctx).judgements, 4, "not yet: judged again")
            XCTAssertTrue(d.cache.seenCleanOnce(regionKey(d)), "still waiting for clean checks")
        }
        _ = d.judge(img, context: ctx)
        XCTAssertFalse(d.cache.seenCleanOnce(regionKey(d)))
        XCTAssertEqual(d.cache.checks(regionKey(d))?.clean, VerdictCache.CLEAN_CHECKS)
        let calls = fa.calls
        d.resetTimings()
        let third = d.judge(img, context: ctx)
        XCTAssertEqual(third.judgements, 0, "every entry comes from the cache")
        XCTAssertEqual(d.timings.cacheMisses, 0)
        XCTAssertEqual(fa.calls, calls)
        XCTAssertEqual(over(third)?.display, .clear)
        XCTAssertEqual(VerdictCache.CLEAN_CHECKS, 3)
    }

    // MARK: A borderline judgement marks it; a failure starts again

    func testAScoreAtOrOverTheMarginBetweenMarksItForGood() {
        // Cut-off 0.5, margin 0.25. Low, then 0.25 (at the margin: clean, but not clearly), then low many times.
        let (d, fa, fb) = scored(0.1, 0.1)
        _ = d.judge(img, context: ctx)
        XCTAssertTrue(d.cache.seenCleanOnce(regionKey(d)))
        fa.score = 0.25
        let between = d.judge(img, context: ctx)
        XCTAssertEqual(over(between)?.display, .clear, "still clean, so shown")
        XCTAssertTrue(d.cache.isStuck(regionKey(d)), "marked: never to be cached clean while held")
        XCTAssertFalse(d.cache.seenCleanOnce(regionKey(d)), "and no longer waiting for checks")
        fa.score = 0.1; fb.score = 0.1
        for n in 0..<(2 * VerdictCache.CLEAN_CHECKS) {
            XCTAssertEqual(d.judge(img, context: ctx).judgements, 4, "judged afresh every time (\(n)), never reused")
        }
        XCTAssertNil(d.cache.get(regionKey(d)))
    }

    func testAScoreOverTheMarginAfterTwoChecksStartsAgainWhereItIsJudged() {
        // A reused clean entry that is judged again where a blur can apply, and lands over the margin there,
        // is marked: it is not reused anywhere again while the cache holds it.
        // 0.2: clearly clean for the cover cut-off (under 0.25), not settled for a blur (over 0.15).
        let (d, fa, _) = scored(0.2, 0, table: cutoffs(0.5, clean: 0.3))
        for _ in 0..<VerdictCache.CLEAN_CHECKS { _ = d.judge(img, context: ctx) }
        XCTAssertEqual(d.judge(img, context: ctx).judgements, 0)
        d.hot.mark(ctx.windowID, ctx.now)
        fa.score = 0.26   // over half the cover cut-off: not clearly clean for anything
        _ = d.judge(img, context: ctx)
        XCTAssertTrue(d.cache.isStuck(regionKey(d)))
        fa.score = 0.2
        let other = JudgeContext(windowID: 2, startsCovered: false)
        d.resetTimings()
        _ = d.judge(img, context: other)
        XCTAssertEqual(d.timings.cacheHits, 1, "only the whole pass is reused; the region is judged again")
    }

    func testAFlagBetweenStartsAgainAndCovers() {
        let (d, fa, fb) = scored(0.1, 0.1)
        _ = d.judge(img, context: ctx)
        fa.score = 0.9; fb.score = 0.9
        let flagged = d.judge(img, context: ctx)
        XCTAssertEqual(over(flagged)?.display, .cover)
        XCTAssertFalse(d.cache.seenCleanOnce(regionKey(d)))
        XCTAssertEqual(d.cache.get(regionKey(d))?.covering, true, "the cover is kept; reusing it only covers")
        fa.score = 0.1; fb.score = 0.1
        let again = d.judge(img, context: ctx)
        XCTAssertEqual(over(again)?.display, .cover, "the same pixels stay covered from the cache")
    }

    func testAModelFailureBetweenStartsAgain() {
        for withFastPass in [false, true] {
            let (d, fa, fb) = scored(0.1, 0.1)
            let progress: ((JudgeProgress) -> Void)? = withFastPass ? { _ in } : nil
            _ = d.judge(img, context: ctx, progress: progress)
            XCTAssertTrue(d.cache.seenCleanOnce(regionKey(d)))
            // Both models fail on their next call: the fast pass (when there is one) or the full rule.
            fa.failCalls = 1; fb.failCalls = 1
            let failed = d.judge(img, context: ctx, progress: progress)
            XCTAssertNotEqual(over(failed)?.display, .clear, "\(withFastPass): a failure is never clear")
            XCTAssertEqual(over(failed)?.reason, .overload)
            XCTAssertNil(d.cache.checks(regionKey(d)), "\(withFastPass): the clean count is forgotten")
            fa.failCalls = 0; fb.failCalls = 0
            _ = d.judge(img, context: ctx, progress: progress)
            XCTAssertTrue(d.cache.seenCleanOnce(regionKey(d)), "\(withFastPass): one clean judgement since the failure")
            for _ in 1..<VerdictCache.CLEAN_CHECKS {
                XCTAssertGreaterThan(d.judge(img, context: ctx, progress: progress).judgements, 0, "\(withFastPass): judged again")
            }
            XCTAssertEqual(d.judge(img, context: ctx, progress: progress).judgements, 0, "\(withFastPass): reused after all of them")
        }
    }

    // MARK: Where a blur can apply

    func testWhereABlurCanApplyEveryCheckMustBeSettledForTheBlur() {
        // The 96-pixel region can be blurred in a hot window: its containment cut-off (0.3) is under its cover
        // cut-off (0.5), so there it needs scores under 0.15 every time; elsewhere under 0.25.
        let (d, fa, _) = scored(0.1, 0, table: cutoffs(0.5, clean: 0.3))
        let hot = JudgeContext(windowID: 3, startsCovered: false)
        d.hot.mark(hot.windowID, hot.now)
        for _ in 0..<VerdictCache.CLEAN_CHECKS { _ = d.judge(img, context: hot) }   // 0.1: settled for a blur every time
        XCTAssertEqual(d.cache.checks(regionKey(d))?.blur, VerdictCache.CLEAN_CHECKS)
        XCTAssertEqual(d.judge(img, context: hot).judgements, 0, "settled every time: reused in the hot window too")
        // Another picture: one check not settled for a blur, and it is never settled for one while held.
        let (e, ea, _) = scored(0.1, 0, table: cutoffs(0.5, clean: 0.3))
        e.hot.mark(hot.windowID, hot.now)
        _ = e.judge(img, context: hot)                  // 0.1: settled for a blur, once
        ea.score = 0.2
        _ = e.judge(img, context: hot)                  // 0.2: clearly clean for the cover cut-off, not for the blur
        XCTAssertEqual(e.cache.checks(regionKey(e))?.blur, 0, "the blur count is gone, for good")
        ea.score = 0.1
        _ = e.judge(img, context: hot)                  // the last clean check for the cover cut-off
        XCTAssertEqual(e.cache.checks(regionKey(e))?.clean, VerdictCache.CLEAN_CHECKS)
        XCTAssertEqual(e.judge(img, context: ctx).judgements, 0, "reused where no blur can apply")
        for _ in 0..<VerdictCache.CLEAN_CHECKS {
            XCTAssertEqual(e.judge(img, context: hot).judgements, 2, "judged again every time where a blur can apply")
        }
        XCTAssertEqual(e.cache.checks(regionKey(e))?.blur, 0)
    }

    func testAPictureSeenCleanOnceIsBlurredWhenTheWindowTurnsHot() {
        // A green 96-pixel picture is shown on one clean judgement. In the next call a red picture both families
        // flag turns the window hot. The green picture is not reused from its one clean check: it is judged in
        // that call, as an uncached picture would be, and blurred if the budget runs out before it.
        let a = ColorScoreModel(id: "fa", family: .a, scores: [0: 0.9, 1: 0.1]), b = ColorScoreModel(id: "fb", family: .b, scores: [0: 0.9])
        let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "hot"), table: cutoffs(0.45, clean: 0.3), config: DetectorConfig(), finder: RegionFinder())
        var page = canvas(600, 300)
        let green = PixelRect(x: 40, y: 60, w: 96, h: 96), red = PixelRect(x: 420, y: 160, w: 48, h: 48)
        paint(&page, green, channel: 1, seed: 3)
        let first = d.judge(page, context: ctx, budget: 400)
        XCTAssertEqual(first.regions.first { $0.rect == green }?.display, .clear)
        paint(&page, red, channel: 0, seed: 4)
        let second = d.judge(page, context: ctx, budget: 2)   // room for the red picture only (judged first: smaller)
        XCTAssertTrue(second.hot)
        XCTAssertEqual(second.regions.first { $0.rect == red }?.display, .cover)
        XCTAssertEqual(second.regions.first { $0.rect == green }?.reason, .overload, "not cleared on its one clean check")
        XCTAssertNotEqual(second.regions.first { $0.rect == green }?.display, .clear)
    }

    // MARK: Shown as it is meanwhile, and nothing cleared on one check

    // MARK: With "judged earlier" (`seenClear`): a display rule, never a cached verdict

    func testOneCleanCheckThenReuseWithNoBudgetIsShownAsJudgedEarlierNeverFromTheCache() {
        let (d, _, _) = scored(0.1, 0.1)
        _ = d.judge(img, context: ctx)
        XCTAssertNotNil(d.seenClear.get(regionKey(d)), "seen clean once is also seen clear on these pixels")
        d.resetTimings()
        let starved = d.judge(img, context: ctx, budget: 0)
        XCTAssertEqual(over(starved)?.display, .clear)
        XCTAssertEqual(over(starved)?.reason, .judgedEarlier, "shown as judged earlier: the display rule, not the cache")
        XCTAssertEqual(d.timings.cacheHits, 0, "nothing came from the cache")
        XCTAssertNil(d.cache.get(regionKey(d)))
        XCTAssertTrue(d.cache.seenCleanOnce(regionKey(d)), "still waiting for its second check")
        // Where the display rule does not apply (a covered-start window), it is unjudged.
        let covered = d.judge(img, context: JudgeContext(windowID: 9, startsCovered: true), budget: 0)
        XCTAssertEqual(covered.regions.first { $0.pass == .region }?.reason, .overload)
        // With budget it gets its real checks, before nothing else, and only then comes from the cache.
        for _ in 1..<VerdictCache.CLEAN_CHECKS {
            let second = d.judge(img, context: ctx)
            XCTAssertEqual(second.judgements, 4)
            XCTAssertEqual(over(second)?.reason, .judgedClean)
        }
        XCTAssertNil(d.seenClear.get(regionKey(d)), "reusable now: no longer kept as only seen clear")
        let served = d.judge(img, context: ctx, budget: 0)
        XCTAssertEqual(over(served)?.display, .clear)
        XCTAssertNotEqual(over(served)?.reason, .judgedEarlier)
        XCTAssertEqual(served.overloaded, 0)
    }

    func testAModelFailureAfterOneCleanCheckIsNeitherShownAsJudgedEarlierNorCounted() {
        let (d, fa, fb) = scored(0.1, 0.1)
        _ = d.judge(img, context: ctx)
        fa.failCalls = 1; fb.failCalls = 1
        let failed = d.judge(img, context: ctx)
        XCTAssertEqual(over(failed)?.reason, .overload)
        XCTAssertNil(d.seenClear.get(regionKey(d)), "what was seen clear is forgotten")
        XCTAssertNil(d.cache.checks(regionKey(d)), "and so is the clean count")
        let starved = d.judge(img, context: ctx, budget: 0)
        XCTAssertEqual(over(starved)?.reason, .overload, "after a failure, nothing is shown as judged earlier")
        XCTAssertNotEqual(over(starved)?.display, .clear)
    }

    func testAPictureSeenCleanOnceAndDueIsJudgedBeforeNothingNew() {
        // Entries never judged come first; a picture seen clean once waits behind them, as main's judged-earlier entries do.
        let (d, _, _) = scored(0.1, 0.1)
        _ = d.judge(img, context: ctx)
        var two = img
        paint(&two, PixelRect(x: 220, y: 60, w: 96, h: 96), channel: nil, seed: 8)
        let v = d.judge(two, context: ctx, budget: 2)   // one entry's worth
        XCTAssertTrue(v.regions.contains { $0.rect == PixelRect(x: 220, y: 60, w: 96, h: 96) && $0.reason == .judgedClean }, "the new picture first")
        XCTAssertEqual(over(v)?.reason, .judgedEarlier, "the one seen clean once waits, shown as judged earlier")
    }

    // MARK: Second checks in the background

    func testABackgroundSecondCheckJudgesOnlyPicturesSeenCleanOnce() {
        let (d, fa, _) = scored(0.1, 0.1)
        let area = PixelRect(x: 0, y: 0, w: 400, h: 300)
        let first = d.judge(img, context: ctx)
        XCTAssertEqual(first.secondChecksLeft, 2, "the region and the whole pass wait for clean checks")
        for n in 1..<VerdictCache.CLEAN_CHECKS {
            let v = d.secondChecks(img, context: ctx, within: area, budget: 400)
            XCTAssertEqual(v.judgements, 4)
            XCTAssertEqual(v.secondChecksLeft, n + 1 < VerdictCache.CLEAN_CHECKS ? 2 : 0, "one check a call, until each has all")
            XCTAssertEqual(v.overloaded, 0)
            XCTAssertFalse(v.regions.contains { $0.display != .clear })
        }
        XCTAssertEqual(d.judge(img, context: ctx).judgements, 0, "served from the cache now")
        // Nothing left to check: nothing is judged, and pictures never seen are not judged here either.
        let calls = fa.calls
        XCTAssertEqual(d.secondChecks(img, context: ctx, within: area, budget: 400).judgements, 0)
        var other = img
        paint(&other, PixelRect(x: 220, y: 60, w: 96, h: 96), channel: nil, seed: 8)
        let none = d.secondChecks(other, context: ctx, within: area, budget: 400)
        XCTAssertEqual(none.judgements, 0, "a picture never judged waits for its own first judgement")
        XCTAssertTrue(none.regions.isEmpty)
        XCTAssertEqual(fa.calls, calls)
    }

    func testABackgroundSecondCheckWithinItsBudgetLeavesTheRestWaiting() {
        let (d, _, _) = scored(0.1, 0.1)
        _ = d.judge(img, context: ctx)
        let v = d.secondChecks(img, context: ctx, within: PixelRect(x: 0, y: 0, w: 400, h: 300), budget: 2)
        XCTAssertEqual(v.judgements, 2)
        XCTAssertEqual(v.secondChecksLeft, 2, "both still wait: the one checked has one more to go, the other two")
        XCTAssertEqual(v.overloaded, 0, "one not reached is not a fault: it was not asked about")
    }

    func testABackgroundSecondCheckThatFlagsOrFailsCovers() {
        let (d, fa, fb) = scored(0.1, 0.1)
        let area = PixelRect(x: 0, y: 0, w: 400, h: 300)
        _ = d.judge(img, context: ctx)
        fa.failCalls = 1; fb.failCalls = 1
        let failed = d.secondChecks(img, context: ctx, within: area, budget: 400)
        XCTAssertEqual(over(failed)?.reason, .overload, "a failure is reported unjudged")
        XCTAssertNotEqual(over(failed)?.display, .clear)
        XCTAssertNil(d.cache.checks(regionKey(d)), "and the count starts again")
        fa.failCalls = 0; fb.failCalls = 0
        _ = d.judge(img, context: ctx)
        fa.score = 0.9; fb.score = 0.9
        let flagged = d.secondChecks(img, context: ctx, within: area, budget: 400)
        XCTAssertEqual(over(flagged)?.display, .cover)
        XCTAssertEqual(d.cache.get(regionKey(d))?.covering, true)
    }

    // MARK: The bound

    func testEntriesSeenCleanOnceAreBoundedWithTheRest() {
        let c = VerdictCache(capacity: 64)
        let img = canvas(64, 64)
        var o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false, cacheable: true)
        o.settledForBlur = true
        for i in 0..<5_000 {
            let k = VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 1 + i % 64, h: 1 + (i / 64) % 64), pass: "region", version: "v")
            c.put(k, o)
            if i % 3 == 0 { c.put(k, o) }   // some reach two checks
            XCTAssertLessThanOrEqual(c.count, 64)
        }
        // One dropped by the bound is simply judged again: its count starts from nothing.
        let k = VerdictCache.key(img, PixelRect(x: 0, y: 0, w: 3, h: 3), pass: "whole", version: "v")
        for _ in 0..<VerdictCache.CLEAN_CHECKS { c.put(k, o) }
        XCTAssertNotNil(c.get(k))
        for i in 0..<200 { c.put(VerdictCache.key(img, PixelRect(x: 1, y: 1, w: 1 + i % 60, h: 1 + i / 60), pass: "slice", version: "v"), o) }
        XCTAssertNil(c.get(k))
        c.put(k, o)
        XCTAssertNil(c.get(k), "back to seen clean once")
    }

    // MARK: The measurement's case: under half the cut-off once, over the cut-off the next time

    func testUnderHalfThenOverTheCutOffIsJudgedAgainAndCovered() {
        // As measured on a harmless 64-127 px entry (results/jitter-spread.json: Marqo 64-127 crossed 26 times):
        // with the sealed table's Marqo cut-offs for that band (cover 0.8235, containment 0.4524), family A first
        // scores 0.35, under half the cover cut-off (0.41), and next time 0.85, over it. Family B scores 0.
        // With one clean check the first score was cached and the picture stayed shown. Now it is judged again,
        // and the second judgement is a dispute with no tie-breaker to settle it, so it is covered.
        var c: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb"] {
            c[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, Cutoffs(cover: 0.8235, clean: 0.4524, strike: 0.95, gridMember: 0.9, gridLow: 0.9)) })
        }
        let a = SequenceModel(id: "fa", family: .a, channel: 1, sequence: [0.35, 0.85]), b = SequenceModel(id: "fb", family: .b, channel: 1, sequence: [])
        let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "seq"), table: ThresholdTable(schema: "test", models: c),
                         config: DetectorConfig(), finder: RegionFinder())
        var page = canvas(400, 300)
        paint(&page, r, channel: 1, seed: 9)
        let first = d.judge(page, context: ctx)
        XCTAssertEqual(over(first)?.display, .clear, "0.35: clean, and under half the cut-off")
        XCTAssertEqual(a.calls, 1, "the region alone is green enough to score")
        let second = d.judge(page, context: ctx)
        XCTAssertEqual(a.calls, 2, "judged again rather than served from one clean check")
        XCTAssertEqual(over(second)?.display, .cover)
        XCTAssertEqual(over(second)?.reason, .disputed)
        // And it stays covered: the covering outcome is kept.
        XCTAssertEqual(over(d.judge(page, context: ctx))?.display, .cover)
        XCTAssertEqual(a.calls, 2)
    }
}
