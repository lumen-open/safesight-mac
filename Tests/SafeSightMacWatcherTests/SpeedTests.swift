// SPDX-License-Identifier: Apache-2.0
// The speed work in the cover layer: exact-match caching, covers that follow scrolling, covering first on
// busy pages, and judging near the pointer first with the fastest model's flag shown at once. Each test also
// checks that nothing is judged or covered less. Synthetic patterns and fake marker models only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher
import RegionFinder

@Suite struct VerdictCacheInThePipelineTests {
    let display = DisplayDescriptor(id: 5, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    var window: WindowSnapshot { Fixtures.oneWindow(display.bounds) }

    @Test func aReloadedPageIsNotJudgedAgainAndStaysCovered() {
        let d = Fixtures.detector()
        let p = DisplayPipeline(display: display, judger: d, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        var page = Fixtures.blank(600, 400)
        Fixtures.paint(&page, PixelRect(x: 40, y: 40, w: 120, h: 90), channel: nil, seed: 3)
        Fixtures.paint(&page, PixelRect(x: 300, y: 200, w: 100, h: 100), channel: nil, seed: 4)
        let flagged = PixelRect(x: 420, y: 40, w: 120, h: 120)
        Fixtures.paintFlagged(&page, flagged)
        let whole = [PixelRect(x: 0, y: 0, w: 600, h: 400)]
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        #expect(p.lastTimings.judgements > 0)
        // Shown again: the harmless pictures get their second clean check (`VerdictCache.CLEAN_CHECKS`).
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: display, scale: 1, dirty: whole, t: 0.5), snapshot: window, now: 0.5)
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: whole, t: 0.6), snapshot: window, now: 0.6)
        #expect(p.lastTimings.judgements > 0)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: display, scale: 1, dirty: whole, t: 1), snapshot: window, now: 1)
        d.resetTimings()
        let again = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: whole, t: 2), snapshot: window, now: 2)
        #expect(p.lastTimings.judgements == 0, "every verdict and the finder's proposals come from the exact-match caches")
        #expect(d.timings.finderCacheHits == 1)
        #expect(again.covers(CGRect(x: 420, y: 40, width: 120, height: 120), kind: .plain), "a cached flag covers as before")
    }

    /// While nothing changes, pictures seen clean once get their second clean check in the background (step 3c), so a
    /// reload after that is served from the cache. Nothing is covered or judged in the foreground meanwhile.
    @Test func aStillPageGetsItsSecondChecksInTheBackground() {
        let d = Fixtures.detector()
        let p = DisplayPipeline(display: display, judger: d, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        var page = Fixtures.blank(600, 400)
        Fixtures.paint(&page, PixelRect(x: 40, y: 40, w: 120, h: 90), channel: nil, seed: 3)
        Fixtures.paint(&page, PixelRect(x: 300, y: 200, w: 100, h: 100), channel: nil, seed: 4)
        let whole = [PixelRect(x: 0, y: 0, w: 600, h: 400)]
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        #expect(p.secondChecksDue, "the harmless pictures were seen clean once")
        var background = 0, t = 0.0
        for _ in 0..<10 where p.secondChecksDue {
            t += 0.1
            let plan = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: t), snapshot: window, now: t)
            background += p.lastTimings.secondCheckJudgements
            #expect(p.lastTimings.judgements == 0, "nothing in the foreground")
            #expect(plan.items.isEmpty && plan.wholeDisplay == nil, "and nothing covered or blurred")
        }
        #expect(background > 0)
        #expect(!p.secondChecksDue)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: display, scale: 1, dirty: whole, t: t + 1), snapshot: window, now: t + 1)
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: whole, t: t + 2), snapshot: window, now: t + 2)
        #expect(p.lastTimings.judgements == 0, "two clean checks: served from the cache")
    }

    /// With background checks off, the second check waits until the picture comes back.
    @Test func withoutBackgroundChecksTheSecondCheckWaitsForThePictureToComeBack() {
        let d = Fixtures.detector()
        let p = DisplayPipeline(display: display, judger: d, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        p.backgroundSecondChecks = false
        var page = Fixtures.blank(600, 400)
        Fixtures.paint(&page, PixelRect(x: 300, y: 200, w: 100, h: 100), channel: nil, seed: 4)
        let whole = [PixelRect(x: 0, y: 0, w: 600, h: 400)]
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: 0.1), snapshot: window, now: 0.1)
        #expect(p.lastTimings.secondCheckJudgements == 0)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: display, scale: 1, dirty: whole, t: 1), snapshot: window, now: 1)
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: whole, t: 2), snapshot: window, now: 2)
        #expect(p.lastTimings.judgements > 0, "judged again when it came back")
    }

    /// A background second check that flags covers at once; one that is clean clears nothing that was covered.
    @Test func aBackgroundCheckThatFlagsCoversAtOnce() {
        let a = SwitchModel(id: "fa", family: .a), b = SwitchModel(id: "fb", family: .b)
        let c = Cutoffs(cover: 0.5, clean: 0.4, strike: 0.95, gridMember: 0.9, gridLow: 0.9)
        let table = ThresholdTable(schema: "test", models: ["fa": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }),
                                                            "fb": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })])
        let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "switch"), table: table, config: DetectorConfig(), finder: RegionFinder())
        let p = DisplayPipeline(display: display, judger: d, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        var page = Fixtures.blank(600, 400)
        let pic = PixelRect(x: 300, y: 200, w: 100, h: 100)
        Fixtures.paint(&page, pic, channel: nil, seed: 4)
        a.score = 0.1; b.score = 0.1
        let shown = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        let g = CGRect(x: 300, y: 200, width: 100, height: 100)
        #expect(!shown.covers(g), "shown on its clean verdict")
        #expect(p.secondChecksDue)
        // The next judgement, as jitter could make it, flags: the background check covers the picture.
        a.score = 0.9; b.score = 0.9
        let checked = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: 0.1), snapshot: window, now: 0.1)
        #expect(p.lastTimings.secondCheckJudgements > 0)
        #expect(checked.covers(g, kind: .plain), "covered at once")
        // Clean again in later background frames: nothing is lifted by them (no second checks are due now).
        a.score = 0.1; b.score = 0.1
        let later = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: 0.2), snapshot: window, now: 0.2)
        #expect(later.covers(g, kind: .plain))
    }
}

/// Second clean checks as part of the looks at a still screen: they keep the looks going only until done or bounded, and
/// they never count towards lifting a cover.
@Suite struct SecondChecksInTheLooksTests {
    let display = DisplayDescriptor(id: 5, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    var window: WindowSnapshot { Fixtures.oneWindow(display.bounds) }

    /// A judge whose second checks never finish (a Mac too slow for them, say).
    final class NeverDone: Judging {
        func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int, progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
            FrameVerdict(regions: [RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)], coverWindow: false, strike: false,
                         hot: false, judgements: 1, overloaded: 0, secondChecksLeft: 1)
        }
        func setRule(_ rule: DetectorRule) {}
        var asked = 0
        func checkAgainInBackground(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict? {
            asked += 1
            return FrameVerdict(regions: [], coverWindow: false, strike: false, hot: false, judgements: 0, overloaded: 0, secondChecksLeft: 1)
        }
    }

    @Test func secondChecksKeepTheLooksGoingOnlyUntilTheirBound() {
        let j = NeverDone()
        let p = DisplayPipeline(display: display, judger: j, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        let page = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        #expect(p.needsAnotherLook, "a second check is something left to judge")
        var t = 0.0
        while t < DisplayPipeline.secondChecksFor - 1 {
            t += 0.25
            _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: t), snapshot: window, now: t)
            #expect(p.needsAnotherLook)
        }
        #expect(j.asked > 0)
        t = DisplayPipeline.secondChecksFor + 1
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: t), snapshot: window, now: t)
        #expect(p.lastTimings.secondChecksGivenUp == 1)
        #expect(!p.needsAnotherLook, "past its bound the looks stop")
        let asked = j.asked
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: t + 1), snapshot: window, now: t + 1)
        #expect(j.asked == asked, "and a look sent anyway does nothing")
    }

    /// Only still time counts towards the bound: after longer than the bound of activity (scrolling, a video), the first
    /// looks at the still screen still give second checks, and the looks then stop within the bound of stillness.
    @Test func activityLongerThanTheBoundThenStillnessStillGetsSecondChecks() {
        let j = NeverDone()
        let p = DisplayPipeline(display: display, judger: j, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        var page = Fixtures.blank(600, 400)
        var t = 0.0
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: t), snapshot: window, now: t)
        let whole = [PixelRect(x: 0, y: 0, w: 600, h: 400)]
        while t < DisplayPipeline.secondChecksFor + 10 {
            t += 0.25
            page.pixels[(Int(t * 4) % 400) * 4] &+= 1   // something changes every frame
            _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: whole, t: t), snapshot: window, now: t)
        }
        #expect(j.asked == 0, "no look while the screen changes")
        #expect(p.needsAnotherLook)
        let still = t
        t += 0.25
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: t), snapshot: window, now: t)
        #expect(j.asked > 0, "the first still look gives second checks")
        #expect(p.lastTimings.secondChecksGivenUp == 0)
        while t < still + DisplayPipeline.secondChecksFor + 1 {
            t += 0.25
            _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [], status: .idle, t: t), snapshot: window, now: t)
        }
        #expect(!p.needsAnotherLook, "and after the bound of stillness the looks stop, full re-judges included")
    }

    /// A change under a cover starts its count again; then it lifts after `VIDEO_VOTE` clean judgements of what it hides,
    /// with background second checks or without: they are never counted towards a cover's lift directly.
    @Test func aChangeUnderACoverLiftsAfterTheSameLooksWithOrWithoutBackgroundChecks() {
        func run(background: Bool) -> (lifted: Int?, background: Int) {
            let a = SwitchModel(id: "fa", family: .a), b = SwitchModel(id: "fb", family: .b)
            let c = Cutoffs(cover: 0.5, clean: 0.4, strike: 0.95, gridMember: 0.9, gridLow: 0.9)
            let table = ThresholdTable(schema: "test", models: ["fa": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }),
                                                                "fb": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })])
            let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "change"), table: table, config: DetectorConfig(), finder: RegionFinder())
            let p = DisplayPipeline(display: display, judger: d, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
            p.backgroundSecondChecks = background
            let pic = PixelRect(x: 300, y: 200, w: 100, h: 100), g = CGRect(x: 300, y: 200, width: 100, height: 100)
            var page = Fixtures.blank(600, 400)
            Fixtures.paint(&page, PixelRect(x: 40, y: 40, w: 120, h: 90), channel: nil, seed: 3)
            Fixtures.paint(&page, pic, channel: nil, seed: 4)
            // Only the picture scores high: a flag over it.
            a.score = 0.1; b.score = 0.1
            _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
            a.score = 0.9; b.score = 0.9
            var flagged = page
            Fixtures.paint(&flagged, pic, channel: nil, seed: 5)
            let covered = p.process(Fixtures.frame(flagged, display: display, scale: 1, dirty: [pic], t: 0.1), snapshot: window, now: 0.1)
            #expect(covered.covers(g, kind: .plain))
            // The picture under the cover changes to a harmless one.
            a.score = 0.1; b.score = 0.1
            var harmless = page
            Fixtures.paint(&harmless, pic, channel: nil, seed: 6)
            _ = p.process(Fixtures.frame(harmless, display: display, scale: 1, dirty: [pic], t: 0.2), snapshot: window, now: 0.2)
            var bg = 0
            for k in 1...20 {
                let t = 0.2 + Double(k) * 0.25
                let plan = p.process(Fixtures.frame(harmless, display: display, scale: 1, dirty: [], status: .idle, t: t), snapshot: window, now: t)
                bg += p.lastTimings.secondCheckJudgements
                if !plan.covers(g) { return (k, bg) }
            }
            return (nil, bg)
        }
        let on = run(background: true), off = run(background: false)
        #expect(on.lifted != nil, "it lifts")
        #expect(on.lifted == off.lifted, "after the same number of looks: \(on.lifted ?? -1) with background checks, \(off.lifted ?? -1) without")
        #expect(on.background > 0, "the background checks did run meanwhile")
        #expect(off.background == 0)
    }
}

/// A fake model with a score the test sets for every picture, whatever the jitter.
final class SwitchModel: ScoringModel {
    let id: String, family: Family, side = 32
    var score: Float = 0
    init(id: String, family: Family) { self.id = id; self.family = family }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] { tensors.map { _ in score } }
}

@Suite struct MotionTests {
    /// A page of bars and textured pictures, harmless.
    static func page(_ w: Int, _ h: Int, seed: UInt32) -> RGBAImage {
        var img = Fixtures.blank(w, h)
        var g = XorShift32(seed: seed)
        var y = 10
        while y < h - 40 {
            Fixtures.paint(&img, PixelRect(x: 10 + Int(g.next() % 40), y: y, w: 60 + Int(g.next() % (UInt32(w) / 2)), h: 8 + Int(g.next() % 20)), channel: nil, seed: g.next())
            y += 30 + Int(g.next() % 30)
        }
        return img
    }

    static func shifted(_ img: RGBAImage, dx: Int, dy: Int, fill: UInt8 = 240) -> RGBAImage {
        var out = Fixtures.blank(img.width, img.height)
        for y in 0..<img.height { for x in 0..<img.width {
            let sx = x - dx, sy = y - dy
            guard sx >= 0, sy >= 0, sx < img.width, sy < img.height else { continue }
            for c in 0..<4 { out.pixels[(y * img.width + x) * 4 + c] = img.pixels[(sy * img.width + sx) * 4 + c] }
        } }
        return out
    }

    @Test func aScrollIsFound() {
        let a = Self.page(400, 300, seed: 1)
        let all = PixelRect(x: 0, y: 0, w: 400, h: 300)
        #expect(MotionFinder.find(old: a, new: Self.shifted(a, dx: 0, dy: -37), area: all) == Translation(dx: 0, dy: -37))
        #expect(MotionFinder.find(old: a, new: Self.shifted(a, dx: 0, dy: 52), area: all) == Translation(dx: 0, dy: 52))
        #expect(MotionFinder.find(old: a, new: Self.shifted(a, dx: -25, dy: 0), area: all) == Translation(dx: -25, dy: 0))
        #expect(MotionFinder.find(old: a, new: a, area: all) == nil, "nothing moved")
        #expect(MotionFinder.find(old: a, new: Self.page(400, 300, seed: 2), area: all) == nil, "another page")
        #expect(MotionFinder.find(old: Fixtures.blank(400, 300), new: Fixtures.blank(400, 300), area: all) == nil, "nothing to go by")
    }

    @Test func aMatchIsExact() {
        let a = Self.page(400, 300, seed: 3)
        var b = Self.shifted(a, dx: 0, dy: -20)
        let r = PixelRect(x: 20, y: 40, w: 100, h: 80)
        #expect(MotionFinder.matches(old: a, new: b, r: r, t: Translation(dx: 0, dy: -20)))
        b.pixels[((r.y + 5) * 400 + r.x + 5) * 4 + 1] &+= 1
        #expect(!MotionFinder.matches(old: a, new: b, r: r, t: Translation(dx: 0, dy: -20)))
    }

    let display = DisplayDescriptor(id: 6, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    var window: WindowSnapshot { Fixtures.oneWindow(display.bounds) }
    let whole = [PixelRect(x: 0, y: 0, w: 600, h: 400)]

    @Test func coversMoveWithScrolledContentBeforeJudging() {
        var page = Self.page(600, 400, seed: 5)
        let pic = PixelRect(x: 380, y: 200, w: 120, h: 120)
        Fixtures.paintFlagged(&page, pic)
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        p.coverGoalMs = 1e9   // this test is about motion alone
        #expect(p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0).covers(CGRect(x: 380, y: 200, width: 120, height: 120)))
        // The page scrolls up by 60 pixels.
        let next = Self.shifted(page, dx: 0, dy: -60)
        var early: [CoverPlan] = []
        let final = p.process(Fixtures.frame(next, display: display, scale: 1, dirty: whole, t: 0.1), snapshot: window, now: 0.1) { early.append($0) }
        #expect(early.count == 1, "a plan with the moved cover is handed out before judging")
        let newPlace = CGRect(x: 380, y: 140, width: 120, height: 120)
        #expect(early.first?.covers(newPlace) == true)
        #expect(early.first?.covers(newPlace.offsetBy(dx: 0, dy: -60)) == true, "and one step further along the motion")
        #expect(final.covers(newPlace))
        // The old place's lower part, now harmless page, is not left covered: no smear.
        #expect(!final.covers(CGRect(x: 380, y: 270, width: 120, height: 50)))
        #expect(p.lastTimings.provisionalMs.count == 1)
    }

    @Test func aCoverWhosePictureDidNotMoveWithThePageCoversBothPlaces() {
        // The page scrolls, but the picture under the cover is replaced at the same moment: its new place
        // cannot be shown to hold the covered pixels, so the old place stays covered as well.
        var page = Self.page(600, 400, seed: 6)
        let pic = PixelRect(x: 380, y: 200, w: 120, h: 120)
        Fixtures.paintFlagged(&page, pic)
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        var next = Self.shifted(page, dx: 0, dy: -60)
        Fixtures.paint(&next, PixelRect(x: 380, y: 140, w: 120, h: 120), channel: nil, seed: 77)   // harmless now
        var early: [CoverPlan] = []
        _ = p.process(Fixtures.frame(next, display: display, scale: 1, dirty: whole, t: 0.1), snapshot: window, now: 0.1) { early.append($0) }
        #expect(early.first?.covers(CGRect(x: 380, y: 200, width: 120, height: 120)) == true, "old place still covered")
        #expect(early.first?.covers(CGRect(x: 380, y: 140, width: 120, height: 120)) == true, "new place covered too")
    }

    @Test func nothingMovesAndNothingIsHandedOutWhenNothingScrolled() {
        var page = Self.page(600, 400, seed: 7)
        Fixtures.paintFlagged(&page, PixelRect(x: 380, y: 200, w: 120, h: 120))
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        p.coverGoalMs = 1e9   // this test is about motion alone
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        var changed = page
        Fixtures.paint(&changed, PixelRect(x: 20, y: 20, w: 50, h: 50), channel: nil, seed: 8)
        var early: [CoverPlan] = []
        let plan = p.process(Fixtures.frame(changed, display: display, scale: 1, dirty: [PixelRect(x: 16, y: 16, w: 64, h: 64)], t: 0.1), snapshot: window, now: 0.1) { early.append($0) }
        #expect(early.isEmpty)
        #expect(plan.covers(CGRect(x: 380, y: 200, width: 120, height: 120)))
    }
}

/// A marker model that takes about as long as a real one, so that the cover layer's estimate is realistic.
final class SlowModel: ScoringModel {
    let inner: MarkerModel
    let msPerTile: Double
    var id: String { inner.id }
    var family: Family { inner.family }
    var side: Int { inner.side }
    init(_ inner: MarkerModel, msPerTile: Double) { self.inner = inner; self.msPerTile = msPerTile }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] {
        usleep(useconds_t(msPerTile * 1000 * Double(tensors.count)))
        return try inner.flagScores(tensors)
    }
}

/// Keeps the order of judge calls (by context) and forwards to the detector.
final class OrderJudger: Judging {
    let inner: Detector
    var order: [UInt64] = []
    init(_ d: Detector) { inner = d }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        order.append(context.windowID)
        return inner.judgeArea(frame, context: context, within: area, budget: budget, progress: progress)
    }
    func setRule(_ rule: DetectorRule) { inner.setRule(rule) }
}

@Suite struct CoverFirstTests {
    let display = DisplayDescriptor(id: 7, bounds: CGRect(x: 0, y: 0, width: 800, height: 500))
    var window: WindowSnapshot { Fixtures.oneWindow(display.bounds) }
    let whole = [PixelRect(x: 0, y: 0, w: 800, h: 500)]

    func slowDetector(ms: Double = 4) -> Detector {
        let a = SlowModel(MarkerModel(id: "fa", family: .a, channel: 0), msPerTile: ms), b = SlowModel(MarkerModel(id: "fb", family: .b, channel: 2), msPerTile: ms)
        let c = Cutoffs(cover: 0.3, clean: 0.05, strike: 0.8, gridMember: 0.3, gridLow: 0.3)
        let table = ThresholdTable(schema: "test", models: ["fa": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }),
                                                            "fb": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })])
        return Detector(models: ModelSet(models: [a, b], bundleVersion: "slow"), table: table, config: DetectorConfig(), finder: RegionFinder())
    }

    func busyPage(seed: UInt32) -> (RGBAImage, [PixelRect]) {
        var img = Fixtures.blank(800, 500)
        var pics: [PixelRect] = []
        for i in 0..<3 { for j in 0..<5 {
            let r = PixelRect(x: 20 + j * 155, y: 20 + i * 160, w: 120, h: 120)
            Fixtures.paint(&img, r, channel: nil, seed: seed &+ UInt32(i * 5 + j)); pics.append(r)
        } }
        return (img, pics)
    }

    func g(_ r: PixelRect) -> CGRect { CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h)) }

    @Test func aBusyPageIsBlurredFirstAndShownWhenCleared() {
        let p = DisplayPipeline(display: display, judger: slowDetector(), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        _ = p.process(Fixtures.frame(Fixtures.blank(800, 500), display: display, scale: 1, t: 0), snapshot: window, now: 0)
        let (page, pics) = busyPage(seed: 10)
        var early: [CoverPlan] = []
        let final = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: whole, t: 1), snapshot: window, now: 1) { early.append($0) }
        #expect(p.lastTimings.coveredFirst >= pics.count)
        let first = early.first
        #expect(first != nil, "a plan is handed out before judging ends")
        for r in pics { #expect(first?.covers(g(r)) == true, "new picture blurred until judged") }
        #expect(first?.items.allSatisfy { $0.kind != .plain } == true, "blurs, not covers")
        for r in pics { #expect(!final.covers(g(r)), "shown once cleared") }
    }

    @Test func newPicturesAreBlurredFirstOnlyWhenJudgingWouldOverrunTheGoal() {
        // The same new picture, once with a goal judging easily meets and once with one it cannot meet.
        // (Unoptimised test builds are too slow to time the 0.1 s goal itself; the bench does that.)
        for (goal, blurred) in [(1e9, false), (0.0, true)] {
            let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
            p.coverGoalMs = goal
            _ = p.process(Fixtures.frame(Fixtures.blank(800, 500), display: display, scale: 1, t: 0), snapshot: window, now: 0)
            var img = Fixtures.blank(800, 500)
            let r = PixelRect(x: 400, y: 100, w: 120, h: 120)
            Fixtures.paint(&img, r, channel: nil, seed: 4)
            var early: [CoverPlan] = []
            let final = p.process(Fixtures.frame(img, display: display, scale: 1, dirty: [r], t: 1), snapshot: window, now: 1) { early.append($0) }
            #expect((p.lastTimings.coveredFirst > 0) == blurred)
            #expect((early.first?.covers(g(r)) ?? false) == blurred)
            #expect(!final.covers(g(r)), "harmless: shown once judged either way")
        }
    }

    @Test func aFastFlagIsBlurredBeforeTheFullRuleCovers() {
        let p = DisplayPipeline(display: display, judger: slowDetector(ms: 1), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        _ = p.process(Fixtures.frame(Fixtures.blank(800, 500), display: display, scale: 1, t: 0), snapshot: window, now: 0)
        var img = Fixtures.blank(800, 500)
        let r = PixelRect(x: 300, y: 150, w: 120, h: 120)
        Fixtures.paintFlagged(&img, r)
        var early: [CoverPlan] = []
        let final = p.process(Fixtures.frame(img, display: display, scale: 1, dirty: [r], t: 1), snapshot: window, now: 1) { early.append($0) }
        #expect(p.lastTimings.fastFlags >= 1)
        #expect(early.contains { $0.covers(g(r)) && $0.items.contains { $0.kind != .plain } }, "blurred as soon as the fastest model flagged")
        #expect(final.covers(g(r), kind: .plain), "then covered by the full rule")
    }

    @Test func earlyPlansKeepEveryCoverAlreadyShown() {
        let p = DisplayPipeline(display: display, judger: slowDetector(), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        var base = Fixtures.blank(800, 500)
        let flagged = PixelRect(x: 640, y: 340, w: 120, h: 120)
        Fixtures.paintFlagged(&base, flagged)
        #expect(p.process(Fixtures.frame(base, display: display, scale: 1, t: 0), snapshot: window, now: 0).covers(g(flagged), kind: .plain))
        var (page, _) = busyPage(seed: 30)
        Fixtures.paintFlagged(&page, flagged)
        var early: [CoverPlan] = []
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: [PixelRect(x: 0, y: 0, w: 620, h: 500)], t: 1), snapshot: window, now: 1) { early.append($0) }
        #expect(!early.isEmpty)
        for e in early { #expect(e.covers(g(flagged), kind: .plain), "the earlier cover stays in every early plan") }
    }

    @Test func noEarlyPlanWhileTheDisplayIsCoveredWhole() {
        let p = DisplayPipeline(display: display, judger: slowDetector(), budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        let (page, _) = busyPage(seed: 40)
        var early: [CoverPlan] = []
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0) { early.append($0) }
        #expect(early.isEmpty, "until its first judged frame the display stays covered whole")
    }

    @Test func theWindowUnderThePointerIsJudgedFirst() {
        let d = DisplayDescriptor(id: 8, bounds: CGRect(x: 0, y: 0, width: 800, height: 400))
        let left = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        let right = WindowInfo(number: 2, ownerPID: 501, layer: 0, bounds: CGRect(x: 400, y: 0, width: 400, height: 400))
        let snap = WindowSnapshot(windows: [left, right], time: 0)
        let j = OrderJudger(Fixtures.detector())
        let p = DisplayPipeline(display: d, judger: j, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        _ = p.process(Fixtures.frame(Fixtures.blank(800, 400), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        var img = Fixtures.blank(800, 400)
        Fixtures.paint(&img, PixelRect(x: 50, y: 50, w: 100, h: 100), channel: nil, seed: 1)
        Fixtures.paint(&img, PixelRect(x: 550, y: 50, w: 100, h: 100), channel: nil, seed: 2)
        let dirty = [PixelRect(x: 48, y: 48, w: 104, h: 104), PixelRect(x: 548, y: 48, w: 104, h: 104)]
        j.order = []
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: dirty, t: 1), snapshot: snap, now: 1, pointer: CGPoint(x: 700, y: 300))
        let rightID = JudgeTarget.window(number: 2, ownerPID: 501).contextID, leftID = JudgeTarget.window(number: 1, ownerPID: 500).contextID
        #expect(j.order.first == rightID)
        #expect(Set(j.order) == [rightID, leftID], "both are still judged")
        j.order = []
        var img2 = img
        Fixtures.paint(&img2, PixelRect(x: 50, y: 200, w: 100, h: 100), channel: nil, seed: 3)
        Fixtures.paint(&img2, PixelRect(x: 550, y: 200, w: 100, h: 100), channel: nil, seed: 4)
        let dirty2 = [PixelRect(x: 48, y: 198, w: 104, h: 104), PixelRect(x: 548, y: 198, w: 104, h: 104)]
        _ = p.process(Fixtures.frame(img2, display: d, scale: 1, dirty: dirty2, t: 2), snapshot: snap, now: 2)
        #expect(j.order.first == leftID, "with no pointer, front to back as before")
    }
}
