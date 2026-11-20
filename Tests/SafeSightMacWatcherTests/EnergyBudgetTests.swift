// SPDX-License-Identifier: Apache-2.0
// The energy budget (SafeSightMacWatcher/Energy.swift, docs/ENERGY.md), on the real cover layer with a fake judge that keeps
// the detector's order of work and costs (`CostJudge`). Time is simulated; synthetic rectangles only.
//
// - A settled still screen judges nothing and asks for no look.
// - While a still screen settles, judgements stay within the budget for the energy mode.
// - Saving energy only slows the settling: the same four clean rounds before a cover lifts, a flag stays covered, and
//   new pictures are judged at the full budget.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

@Suite struct EnergyBudgetTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    var menuBar: WindowInfo { WindowInfo(number: 2, ownerPID: 174, layer: 24, bounds: CGRect(x: 0, y: 0, width: 600, height: 30)) }
    var desktop: WindowInfo { WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 30, width: 600, height: 370)) }

    struct Run { var settledAt: Double?; var judgements: Int; var looks: Int; var judgementsWhenSettled: Int; var plans: [CoverPlan] }

    /// One complete frame at t = 0, then a look every `mode.lookEvery` while the pipeline wants one (as the watcher asks),
    /// (every tick while new pictures are left over), for `seconds`; and after it settles, a "nothing changed" frame every tick anyway (as if the capture sent them).
    func still(_ p: DisplayPipeline, _ judge: CostJudge, _ snap: WindowSnapshot, mode: EnergyMode, seconds: Double) -> Run {
        p.energy = mode
        // The fake judge's clock times the looks, as in StillScreenSettlesTests: the same on any machine.
        p.clock = { [unowned judge] in judge.clockNs }
        var plans = [p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: snap, now: 0)]
        var t = 0.0, lastLook = 0.0, looks = 0, settledAt: Double?, judgedThen = 0
        let counted = { judge.judgedCount.values.reduce(0, +) }
        while t < seconds {
            t += Register.TICK
            let calm = plans.last!.wholeDisplay == nil && plans.last!.items.isEmpty
            if settledAt == nil, calm, !p.needsAnotherLook { settledAt = t; judgedThen = counted() }
            if settledAt != nil {
                plans.append(p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t))
                continue
            }
            let every = p.hasLeftOverWork ? Register.TICK : mode.lookEvery
            guard p.needsAnotherLook, t - lastLook >= every - 1e-9 else { continue }
            lastLook = t; looks += 1
            plans.append(p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t))
        }
        return Run(settledAt: settledAt, judgements: settledAt == nil ? counted() : judgedThen, looks: looks,
                   judgementsWhenSettled: counted() - judgedThen, plans: plans)
    }

    func desktopRun(_ mode: EnergyMode, seconds: Double = 600, flagged: Set<PixelRect> = []) -> (Run, CostJudge, DisplayPipeline) {
        let judge = CostJudge(entries: StillScreenSettlesTests.grid(PixelRect(x: 0, y: 30, w: 600, h: 370)), wholeCost: StillScreenSettlesTests.wholeCost)
        judge.flagged = flagged
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let run = still(p, judge, WindowSnapshot(windows: [desktop, menuBar], time: 0), mode: mode, seconds: seconds)
        return (run, judge, p)
    }

    @Test func theModeFollowsWhatMacOSSays() {
        #expect(EnergyMode.from(onBattery: false, lowPowerMode: false, thermal: .nominal) == .full)
        #expect(EnergyMode.from(onBattery: false, lowPowerMode: false, thermal: .fair) == .full)
        #expect(EnergyMode.from(onBattery: true, lowPowerMode: false, thermal: .nominal) == .battery)
        #expect(EnergyMode.from(onBattery: false, lowPowerMode: true, thermal: .nominal) == .low)
        #expect(EnergyMode.from(onBattery: true, lowPowerMode: false, thermal: .serious) == .low)
        #expect(EnergyMode.from(onBattery: false, lowPowerMode: false, thermal: .critical) == .low)
        // Saving only ever slows: never a larger share, never quicker looks.
        for m in EnergyMode.allCases {
            #expect(m.settleRateScale > 0 && m.settleRateScale <= 1)
            #expect(m.lookEvery >= Register.TICK)
        }
    }

    @Test(arguments: EnergyMode.allCases)
    func aSettledStillScreenJudgesNothingAndAsksForNoLook(_ mode: EnergyMode) {
        let (run, _, p) = desktopRun(mode, seconds: mode == .full ? 360 : 900)
        #expect(run.settledAt != nil, "settles in \(mode)")
        #expect(run.judgementsWhenSettled <= EnergyBudget.SETTLED_JUDGEMENTS_PER_MINUTE, "judged \(run.judgementsWhenSettled) at rest")
        #expect(!p.needsAnotherLook)
    }

    @Test(arguments: EnergyMode.allCases)
    func settlingStaysWithinTheJudgementBudget(_ mode: EnergyMode) {
        let (run, _, _) = desktopRun(mode, seconds: 900)
        let at = try! #require(run.settledAt)
        // Judgements over the whole settling, against the mode's rate for that long, plus the bucket's first burst.
        let allowed = (Register.JUDGEMENT_BUDGET * mode.settleRateScale) * at + Register.JUDGEMENT_BURST
        #expect(Double(run.judgements) <= allowed, "\(run.judgements) judgements in \(at) s, budget \(allowed)")
        // Looks: at most one a tick, and far fewer than that once only covers wait to lift.
        #expect(Double(run.looks) <= at / Register.TICK + 1)
    }

    @Test func savingEnergySettlesLaterNeverSooner() {
        let full = desktopRun(.full, seconds: 900).0, battery = desktopRun(.battery, seconds: 900).0, low = desktopRun(.low, seconds: 900).0
        let f = try! #require(full.settledAt), b = try! #require(battery.settledAt), l = try! #require(low.settledAt)
        #expect(b >= f && l >= b, "full \(f) s, battery \(b) s, low \(l) s")
        #expect(l <= EnergyBudget.SETTLE_WITHIN / EnergyMode.low.settleRateScale)
    }

    /// The same evidence in every mode: every picture judged clean four times before the screen is clear.
    @Test(arguments: [EnergyMode.battery, .low])
    func aCoverNeedsTheSameFourCleanRoundsWhenSaving(_ mode: EnergyMode) {
        let judge = CostJudge(entries: StillScreenSettlesTests.grid(PixelRect(x: 0, y: 0, w: 600, h: 400), side: 8, step: 15), blindCalls: 1)
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let run = still(p, judge, Fixtures.oneWindow(d.bounds), mode: mode, seconds: 1500)
        let at = try! #require(run.settledAt)
        let least = (Double(4 * 2 * judge.entries.count) - Register.JUDGEMENT_BURST) / (Register.JUDGEMENT_BUDGET * mode.settleRateScale)
        // (Roughly: judging left over from the first frame's new pictures runs at the full rate.)
        #expect(at >= least * 0.8, "not before four whole rounds at the mode's rate: \(at) s against \(least) s")
        #expect(judge.judgedCount.values.allSatisfy { $0 >= Register.VIDEO_VOTE })
    }

    @Test func aFlaggedPictureStaysCoveredInLowPower() {
        let bad = StillScreenSettlesTests.grid(PixelRect(x: 0, y: 30, w: 600, h: 370))[40].rect
        let (run, _, p) = desktopRun(.low, seconds: 600, flagged: [bad])
        let g = CGRect(x: bad.x, y: bad.y, width: bad.w, height: bad.h)
        let first = try! #require(run.plans.firstIndex { $0.covers(g, kind: .plain) })
        #expect(run.plans[first...].allSatisfy { $0.covers(g, kind: .plain) }, "never lifted once flagged")
        #expect(p.needsAnotherLook)
    }

    /// Only the settling slows: with work left over from new pictures, or a frame with new pixels, the full budget.
    @Test func newPicturesAreJudgedAtTheFullBudgetWhenSaving() {
        let judge = CostJudge(entries: StillScreenSettlesTests.grid(PixelRect(x: 0, y: 30, w: 600, h: 370)), wholeCost: StillScreenSettlesTests.wholeCost)
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        p.energy = .low
        let snap = WindowSnapshot(windows: [desktop, menuBar], time: 0)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        #expect(p.bucket.rate == Register.JUDGEMENT_BUDGET, "a frame with new pixels: full rate")
        p.pending = [CGRect(x: 10, y: 40, width: 50, height: 50)]
        _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 1), snapshot: snap, now: 1)
        #expect(p.bucket.rate == Register.JUDGEMENT_BUDGET, "work left over from new pictures: full rate")
        p.pending = []
        #expect(!p.held.isEmpty, "covers wait to lift")
        _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 2), snapshot: snap, now: 2)
        #expect(p.bucket.rate == Register.JUDGEMENT_BUDGET * EnergyMode.low.settleRateScale, "covers waiting to lift: the mode's share")
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, PixelRect(x: 100, y: 100, w: 40, h: 40), channel: 0, seed: 3)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 100, y: 100, w: 40, h: 40)], t: 3), snapshot: snap, now: 3)
        #expect(p.bucket.rate == Register.JUDGEMENT_BUDGET, "new pixels again: full rate")
    }

    /// Fewer, larger looks while only covers wait to lift: each look's fixed cost (the window split, finding pictures,
    /// hashing) is paid less often for the same judgements, and never less often than a second at full power.
    @Test func lookingLessOftenWhileOnlyCoversWait() {
        #expect(EnergyMode.full.lookEvery == 1)
        let (run, _, _) = desktopRun(.full, seconds: 900)
        let at = try! #require(run.settledAt)
        #expect(Double(run.looks) < at / Register.TICK / 2, "\(run.looks) looks in \(at) s")
    }

    /// At a settled screen, frames whose every pixel is the last judged frame's judge nothing, however long it lasts; a frame
    /// that says nothing changed while its pixels did is judged.
    @Test func unchangedFramesAtASettledScreenJudgeNothing() {
        let (run, judge, p) = desktopRun(.full, seconds: 360)
        let at = try! #require(run.settledAt)
        let snap = WindowSnapshot(windows: [desktop, menuBar], time: 0)
        let img = Fixtures.blank(600, 400)
        let before = judge.serial
        var t = at
        for _ in 0..<(5 * 60 * 4) {
            t += Register.TICK
            let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: t), snapshot: snap, now: t)
            #expect(plan.items.isEmpty && plan.wholeDisplay == nil)
        }
        #expect(judge.serial == before, "no judge call in five minutes of unchanged frames")
        // The capture says nothing changed, but a pixel did: judged.
        var other = img
        Fixtures.paint(&other, PixelRect(x: 200, y: 200, w: 8, h: 8), channel: 1, seed: 5)
        t += Register.TICK
        _ = p.process(Fixtures.frame(other, display: d, scale: 1, dirty: [], t: t), snapshot: snap, now: t)
        #expect(judge.serial > before, "a changed pixel is never taken for an unchanged frame")
    }

    /// With a cover held, unchanged frames are still judged as before (the cover's own checks go on).
    @Test func unchangedFramesStillJudgeWhileACoverIsHeld() {
        let bad = StillScreenSettlesTests.grid(PixelRect(x: 0, y: 30, w: 600, h: 370))[40].rect
        let (_, judge, p) = desktopRun(.full, seconds: 120, flagged: [bad])
        #expect(!p.held.isEmpty)
        let before = judge.serial
        let snap = WindowSnapshot(windows: [desktop, menuBar], time: 0)
        for k in 1...8 {
            let t = 120 + Double(k) * Register.TICK
            _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, dirty: [], t: t), snapshot: snap, now: t)
        }
        #expect(judge.serial > before)
    }
}
