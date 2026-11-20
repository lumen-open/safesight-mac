// SPDX-License-Identifier: Apache-2.0
// The fresh-four measurement switch (`Register.FRESH_FOUR`, off by default): with it on, a cover's round counts only
// entries the models judged afresh in that round, never an outcome the verdict cache handed back, and a cover's own
// calls take no clean outcome from the cache (a cached cover is still reused). Synthetic patterns and fake models only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher
import RegionFinder

@Suite struct FreshFourTests {
    let display = DisplayDescriptor(id: 5, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    var window: WindowSnapshot { Fixtures.oneWindow(display.bounds) }
    let whole = PixelRect(x: 0, y: 0, w: 600, h: 400)

    @Test func offByDefault() {
        #expect(Register.FRESH_FOUR == false)
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        #expect(p.freshVotesOnly == false)
        #expect(JudgeContext(windowID: 1, startsCovered: false).freshClean == false)
    }

    /// At the detector: a cache hit is marked; with `freshClean` a cached clean outcome is judged again, and a cached cover
    /// is still reused.
    @Test func freshCleanJudgesCachedCleanAgainButKeepsCachedCovers() {
        let d = Fixtures.detector()
        var page = Fixtures.blank(600, 400)
        let pic = PixelRect(x: 300, y: 200, w: 100, h: 100), flagged = PixelRect(x: 60, y: 60, w: 120, h: 120)
        Fixtures.paint(&page, pic, channel: nil, seed: 4)
        Fixtures.paintFlagged(&page, flagged)
        let ctx = JudgeContext(windowID: 1, startsCovered: false)
        _ = d.judge(page, context: ctx, within: whole, budget: 100_000)
        _ = d.judge(page, context: ctx, within: whole, budget: 100_000)   // the second clean check
        let cached = d.judge(page, context: ctx, within: whole, budget: 100_000)
        #expect(cached.judgements == 0, "two clean checks: everything from the cache")
        #expect(!cached.regions.isEmpty && cached.regions.allSatisfy(\.fromCache))
        var fresh = ctx
        fresh.freshClean = true
        let v = d.judge(page, context: fresh, within: whole, budget: 100_000)
        #expect(v.judgements > 0, "clean outcomes judged again")
        let clean = v.regions.filter { $0.display == .clear }
        #expect(!clean.isEmpty && clean.allSatisfy { !$0.fromCache })
        let cover = v.regions.filter { $0.rect == flagged && $0.pass == .region }
        #expect(!cover.isEmpty && cover.allSatisfy { $0.display == .cover && $0.fromCache }, "a cached cover is reused")
    }

    /// One run of a cover over a picture that changes to a harmless one under it, then looks at a still screen. Scores turn
    /// to a flag from look `flipAt` on. Returns the look the cover lifted at, and the judgements made at each look.
    func run(fresh: Bool, flipAt: Int?) -> (lifted: Int?, judgements: [Int]) {
        let a = SwitchModel(id: "fa", family: .a), b = SwitchModel(id: "fb", family: .b)
        let c = Cutoffs(cover: 0.5, clean: 0.4, strike: 0.95, gridMember: 0.9, gridLow: 0.9)
        let table = ThresholdTable(schema: "test", models: ["fa": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }),
                                                            "fb": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })])
        let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "fresh"), table: table, config: DetectorConfig(), finder: RegionFinder())
        let p = DisplayPipeline(display: display, judger: d, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        p.backgroundSecondChecks = false
        p.freshVotesOnly = fresh
        let pic = PixelRect(x: 300, y: 200, w: 100, h: 100), g = CGRect(x: 300, y: 200, width: 100, height: 100)
        var page = Fixtures.blank(600, 400)
        Fixtures.paint(&page, PixelRect(x: 40, y: 40, w: 120, h: 90), channel: nil, seed: 3)
        Fixtures.paint(&page, pic, channel: nil, seed: 4)
        a.score = 0.1; b.score = 0.1
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        a.score = 0.9; b.score = 0.9
        var flagged = page
        Fixtures.paint(&flagged, pic, channel: nil, seed: 5)
        let covered = p.process(Fixtures.frame(flagged, display: display, scale: 1, dirty: [pic], t: 0.1), snapshot: window, now: 0.1)
        #expect(covered.covers(g, kind: .plain))
        // Clearly clean scores (under half the cover cut-off), so two checks make the picture a cached clean verdict.
        a.score = 0.1; b.score = 0.1
        var harmless = page
        Fixtures.paint(&harmless, pic, channel: nil, seed: 6)
        _ = p.process(Fixtures.frame(harmless, display: display, scale: 1, dirty: [pic], t: 0.2), snapshot: window, now: 0.2)
        var judged: [Int] = []
        for k in 1...20 {
            if let f = flipAt, k >= f { a.score = 0.9; b.score = 0.9 }
            let t = 0.2 + Double(k) * 0.25
            let plan = p.process(Fixtures.frame(harmless, display: display, scale: 1, dirty: [], status: .idle, t: t), snapshot: window, now: t)
            judged.append(p.lastTimings.judgements)
            if !plan.covers(g) { return (k, judged) }
        }
        return (nil, judged)
    }

    /// Today a round can count outcomes from the cache: after two clean checks the cover's last rounds cost nothing. With
    /// the switch on every round is judged, so it costs more and lifts no sooner.
    @Test func withTheSwitchOnEveryRoundIsJudged() {
        let off = run(fresh: false, flipAt: nil), on = run(fresh: true, flipAt: nil)
        #expect(off.lifted != nil && on.lifted != nil, "both lift a harmless picture")
        #expect(off.judgements.contains(0), "today some looks count rounds from the cache alone: \(off.judgements)")
        #expect(!on.judgements.contains(0), "with the switch on every look before the lift judges: \(on.judgements)")
        #expect(on.judgements.reduce(0, +) > off.judgements.reduce(0, +))
        #expect((on.lifted ?? 99) >= (off.lifted ?? 0))
    }

    /// The miss it closes: a picture that passed two jittered checks but would flag on the next ones. Today the cache
    /// answers the cover's remaining rounds and it lifts; with the switch on they are judged, it flags and stays covered.
    @Test func aFlagAfterTwoCleanChecksKeepsTheCoverOnlyWithTheSwitchOn() throws {
        let probe = run(fresh: false, flipAt: nil)
        // The first look today answered from the cache alone.
        let flip = try #require(probe.judgements.firstIndex(of: 0)).advanced(by: 1)
        let off = run(fresh: false, flipAt: flip), on = run(fresh: true, flipAt: flip)
        #expect(off.lifted != nil, "today the cached verdict lifts it although the next judgements would flag")
        #expect(on.lifted == nil, "with the switch on the fresh round flags and it stays covered: \(on.judgements)")
    }
}
