// SPDX-License-Identifier: Apache-2.0
// The option `LookPace.TICK_WHILE_COVERS_OVER` (off by default, docs/ENERGY.md): a still screen looked at every tick
// while more than N covers wait to lift. Off, nothing changes. On, it spends more looks to settle sooner, with the same
// budget, the same four clean rounds and the same clean-cache rule. Time is simulated; synthetic rectangles only.
//
// The figures in docs/ENERGY.md come from `figures` (set SAFESIGHTMAC_LOOKPACE_FIGURES=1; it takes a while).
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

/// What one settling looked like, with the option at `n` (nil: off).
struct PaceFigures {
    var settle: Double?
    var cpuSettlingSeconds = 0.0
    var judgements = 0
    var looks = 0
    var cpuPerMinuteSettled = 0.0
    var earlyLifts: [String] = []
    var overBudget = 0.0
    var line: String {
        String(format: "settle %@, CPU %.1f s, judgements %d, looks %d, settled CPU %.2f s/min, early lifts %d, over budget %.0f",
               settle.map { String(format: "%.1f s", $0) } ?? "never", cpuSettlingSeconds, judgements, looks, cpuPerMinuteSettled,
               earlyLifts.count, overBudget)
    }
}

extension ScreenSim {
    /// Frames until settled (as `settle`), checking after every frame that no cover was lifted before `VIDEO_VOTE` clean
    /// rounds: a cover that held fewer than `VIDEO_VOTE - 1` before the frame (a frame adds at most one) must still be
    /// covered after it. The screen is still while this runs, so nothing moves or is dropped for another reason.
    mutating func settleCheckingLifts(limit: Double, early: inout [String]) -> Double? {
        while t < limit {
            let before = p.held.compactMap { h -> (CGRect, Int)? in h.lastGlobal.map { ($0, h.clean) } }
            step()
            let plan = plans.last!.plan
            if plan.wholeDisplay == nil {
                for (g, clean) in before where clean < Register.VIDEO_VOTE - 1 && !Self.coarselyCovered(g, by: plan.items) {
                    early.append(String(format: "t %.2f clean %d at %.0f,%.0f,%.0f,%.0f", t, clean, g.minX, g.minY, g.width, g.height))
                }
            }
            if drawsNothing(plan) && !p.needsAnotherLook { return t }
        }
        return nil
    }

    /// Judgements since `from` against the budget for that long plus the bucket's burst (positive: over).
    func overBudget(judgements: Int, seconds: Double) -> Double {
        Double(judgements) - EnergyBudget.settlingJudgements(seconds: seconds)
    }
}

@Suite struct LookPaceOptionTests {
    let u = UsableCoversTests()
    var d: DisplayDescriptor { u.d }

    /// The busy page scrolled for `seconds` (as `SustainedChangeTests.scrollRun`), then still until it settles, with the
    /// option at `n`; then a minute settled, the menu bar's clock ticking.
    func scroll(_ n: Int?, exact: Bool, seconds: Double = 60) -> PaceFigures {
        var sim = u.pageSim()
        sim.p.tickWhileCoversOver = n
        sim.judge.exactChanges = exact
        sim.full()
        _ = sim.settle(limit: 400)
        let open = sim.t
        sim.scroll(by: 0)
        var dir = 8
        while sim.t < open + seconds {
            if sim.offset + dir > 3000 - u.pageView.h || sim.offset + dir < 0 { dir = -dir }
            sim.scroll(by: dir)
        }
        return settleFrom(&sim)
    }

    /// The still desktop under the Dock's display-sized window, from its first frame, with the option at `n`.
    func desktop(_ n: Int?) -> PaceFigures {
        var sim = ScreenSim(display: d, judge: RuleJudge(pictures: u.desktopPictures(), blindCalls: 0, msPerJudgement: 15, msPerCall: 4),
                            windows: u.vmWindows)
        sim.p.tickWhileCoversOver = n
        sim.clock = u.clock
        sim.full()
        return settleFrom(&sim, startAtZero: true)
    }

    func settleFrom(_ sim: inout ScreenSim, startAtZero: Bool = false) -> PaceFigures {
        let stop = startAtZero ? 0 : sim.t, cpu0 = startAtZero ? 0 : sim.cpuMs, j0 = startAtZero ? 0 : sim.judge.judgements
        let looks0 = sim.p.runSerial
        var f = PaceFigures()
        let at = sim.settleCheckingLifts(limit: stop + 900, early: &f.earlyLifts)
        f.settle = at.map { $0 - stop }
        f.cpuSettlingSeconds = (sim.cpuMs - cpu0) / 1000
        f.judgements = sim.judge.judgements - j0
        f.looks = sim.p.runSerial - looks0
        f.overBudget = sim.overBudget(judgements: f.judgements, seconds: sim.t - stop)
        if at != nil {
            let c = sim.cpuMs, t = sim.t
            sim.still(until: t + 120)
            f.cpuPerMinuteSettled = (sim.cpuMs - c) / 1000 / 2
        }
        return f
    }

    // MARK: Off: today's behaviour

    @Test func offByDefault() {
        #expect(LookPace.TICK_WHILE_COVERS_OVER == nil, "the option ships off")
        let p = DisplayPipeline(display: d, judger: ScriptedJudge { VerdictScript.clean($0) }, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [])
        #expect(p.tickWhileCoversOver == nil)
    }

    /// Many covers waiting, nothing left over: off, the pace is today's (`looksEveryTick` is `hasLeftOverWork`, and a look
    /// a tick after the last is not due); on, every tick.
    @Test func manyCoversWaitingSetThePaceOnlyWithTheOptionOn() {
        let p = DisplayPipeline(display: d, judger: ScriptedJudge { VerdictScript.clean($0) }, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [])
        p.stillLookPace = (Register.TICK, EnergyMode.full.lookEvery)
        p.held = (0..<40).map { k in
            DisplayPipeline.Held(target: .surface(display: d.id), rel: CGRect(x: 20 * k, y: 40, width: 16, height: 16), whole: false, kind: .plain, clean: 1)
        }
        p.lastLookAt = 100
        #expect(!p.hasLeftOverWork)
        #expect(!p.looksEveryTick && !p.stillLookDue(100 + Register.TICK), "off: once every lookEvery")
        #expect(p.stillLookDue(100 + EnergyMode.full.lookEvery))
        for n in [1, 8, 32] {
            p.tickWhileCoversOver = n
            #expect(p.looksEveryTick && p.stillLookDue(100 + Register.TICK), "on at \(n): every tick with 40 covers waiting")
        }
        p.tickWhileCoversOver = 40
        #expect(!p.looksEveryTick && !p.stillLookDue(100 + Register.TICK), "40 waiting is not more than 40")
        // Flagged covers are not counted: a sooner look cannot lift them.
        p.tickWhileCoversOver = 1
        for i in p.held.indices { p.held[i].flaggedAt = CGRect(x: 0, y: 0, width: 1, height: 1) }
        #expect(!p.looksEveryTick)
        // The budget is empty: no extra look.
        for i in p.held.indices { p.held[i].flaggedAt = nil }
        p.setBudgetShare(0); p.bucket.spend(Int(Register.JUDGEMENT_BURST))
        #expect(!p.stillLookDue(100 + Register.TICK), "an empty bucket gets no extra look")
        #expect(p.stillLookDue(100 + EnergyMode.full.lookEvery), "today's pace still")
        // Covers gone: back to today's pace.
        p.setBudgetShare(Register.JUDGEMENT_BUDGET)
        p.held = []
        #expect(!p.looksEveryTick)
    }

    // MARK: On: the same rules

    /// The still desktop: settles, no cover lifted before four clean rounds, the budget held, and back to today's pace
    /// (no look wanted) once settled.
    @Test(arguments: [1, 8, 32]) func theStillDesktopKeepsTheRules(n: Int) {
        let f = desktop(n)
        print("LOOKPACE desktop N=\(n): \(f.line)")
        #expect(f.settle != nil)
        #expect(f.earlyLifts.isEmpty, "lifted before four clean rounds: \(f.earlyLifts.prefix(3))")
        #expect(f.overBudget <= 0, "over the judging budget by \(f.overBudget)")
        #expect(f.settle.map { $0 <= 60 } ?? false, "settles at least as the default's limit: \(f.line)")
    }

    /// The default, checked the same way, so the check itself is known to pass today.
    @Test func theStillDesktopKeepsTheRulesWithTheOptionOff() {
        let f = desktop(nil)
        print("LOOKPACE desktop off: \(f.line)")
        #expect(f.earlyLifts.isEmpty && f.overBudget <= 0)
    }

    /// The busy page after a minute of scrolling, option on at its keenest: no cover lifted before four clean rounds, the
    /// budget held, and the screen settles.
    @Test func theScrolledPageKeepsTheRules() {
        let f = scroll(1, exact: true)
        print("LOOKPACE scroll exact N=1: \(f.line)")
        #expect(f.settle != nil)
        #expect(f.earlyLifts.isEmpty, "lifted before four clean rounds: \(f.earlyLifts.prefix(3))")
        #expect(f.overBudget <= 0, "over the judging budget by \(f.overBudget)")
    }

    /// As `EnergyBudgetTests.aCoverNeedsTheSameFourCleanRoundsWhenSaving`, with the option on: every picture judged
    /// clean four times before the screen is clear, and not before four whole rounds at the budget's rate.
    @Test(arguments: [1, 8, 32]) func aCoverStillNeedsFourCleanRounds(n: Int) {
        let e = EnergyBudgetTests()
        let judge = CostJudge(entries: StillScreenSettlesTests.grid(PixelRect(x: 0, y: 0, w: 600, h: 400), side: 8, step: 15), blindCalls: 1)
        let p = DisplayPipeline(display: e.d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        p.tickWhileCoversOver = n
        let run = still(p, judge, Fixtures.oneWindow(e.d.bounds), seconds: 1500)
        let at = try! #require(run.settledAt)
        let least = (Double(4 * 2 * judge.entries.count) - Register.JUDGEMENT_BURST) / Register.JUDGEMENT_BUDGET
        #expect(at >= least * 0.8, "not before four whole rounds at the budget's rate: \(at) s against \(least) s")
        #expect(judge.judgedCount.values.allSatisfy { $0 >= Register.VIDEO_VOTE })
        #expect(Double(run.judgements) <= EnergyBudget.settlingJudgements(seconds: at), "\(run.judgements) judgements in \(at) s")
        #expect(!p.looksEveryTick && !p.needsAnotherLook, "back to today's pace once nothing waits")
        print(String(format: "LOOKPACE four rounds N=%d: settled %.1f s (least %.1f), %d looks", n, at, least, run.looks))
    }

    /// `EnergyBudgetTests`' still screen with the option on: its limits (judgements within the budget, at most a look a
    /// tick, settled within `SETTLE_WITHIN`, nothing judged at rest).
    @Test(arguments: [1, 8, 32]) func theEnergyBudgetLimitsHold(n: Int) {
        let e = EnergyBudgetTests()
        for mode in EnergyMode.allCases {
            let judge = CostJudge(entries: StillScreenSettlesTests.grid(PixelRect(x: 0, y: 30, w: 600, h: 370)), wholeCost: StillScreenSettlesTests.wholeCost)
            let p = DisplayPipeline(display: e.d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
            p.tickWhileCoversOver = n
            let run = still(p, judge, WindowSnapshot(windows: [e.desktop, e.menuBar], time: 0), mode: mode, seconds: 900)
            let at = try! #require(run.settledAt)
            #expect(Double(run.judgements) <= EnergyBudget.settlingJudgements(seconds: at), "\(mode): \(run.judgements) in \(at) s")
            #expect(Double(run.looks) <= at / Register.TICK + 1)
            #expect(at <= EnergyBudget.settleWithin(mode), "\(mode): settled in \(at) s")
            #expect(run.judgementsWhenSettled <= EnergyBudget.SETTLED_JUDGEMENTS_PER_MINUTE)
            #expect(!p.needsAnotherLook && !p.looksEveryTick)
            print(String(format: "LOOKPACE budget %@ N=%d: settled %.1f s, %d judgements, %d looks", mode.rawValue, n, at, run.judgements, run.looks))
        }
    }

    /// `EnergyBudgetTests.still`, with the app's pace as it runs with the option (`looksEveryTick` for `leftOver`).
    func still(_ p: DisplayPipeline, _ judge: CostJudge, _ snap: WindowSnapshot, mode: EnergyMode = .full, seconds: Double) -> EnergyBudgetTests.Run {
        let d = p.display
        p.clock = { [unowned judge] in judge.clockNs }
        p.stillLookPace = (Register.TICK, mode.lookEvery)
        var plans = [p.process(Fixtures.frame(Fixtures.blank(Int(d.bounds.width), Int(d.bounds.height)), display: d, scale: 1, t: 0), snapshot: snap, now: 0)]
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
            let due = LookPace.due(now: t, mode: mode, wants: p.needsAnotherLook ? [d.id] : [], leftOver: p.looksEveryTick ? [d.id] : [],
                                   lastAt: [d.id: lastLook], busy: [], waiting: [], holding: false)
            guard !due.offered.isEmpty else { continue }
            lastLook = t
            let serial = p.runSerial
            plans.append(p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t))
            if p.runSerial != serial { looks += 1 }
        }
        return EnergyBudgetTests.Run(settledAt: settledAt, judgements: settledAt == nil ? counted() : judgedThen, looks: looks,
                                     judgementsWhenSettled: counted() - judgedThen, plans: plans)
    }

    // MARK: The figures (docs/ENERGY.md)

    /// Each N against the default (-1 stands for off), the scroll in exact and old mode, and the still desktop.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAFESIGHTMAC_LOOKPACE_FIGURES"] != nil),
          arguments: [-1, 32, 8, 1], ["exact", "old", "desktop"])
    func figures(n: Int, what: String) {
        let option = n < 0 ? nil : n
        let name = option.map { "N=\($0)" } ?? "off"
        let f = what == "desktop" ? desktop(option) : scroll(option, exact: what == "exact")
        print("LOOKPACE FIG \(what) \(name): \(f.line)")
        #expect(f.earlyLifts.isEmpty && f.overBudget <= 0, "\(f.line) \(f.earlyLifts.prefix(3))")
    }
}
