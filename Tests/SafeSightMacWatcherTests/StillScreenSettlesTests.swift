// SPDX-License-Identifier: Apache-2.0
// A still, harmless screen on a slow Mac must settle: every cover lifts and the looks stop. In the off-screen run of the
// virtual Mac's desktop (`safesightmac-harness static`) eight covers stayed for good on main: the menu bar's whole-window
// cover, and the desktop's covers. Each was waiting for one entry dearer than any call was ever given (the menu bar's
// whole pass, about 42 judgements; a long, thin line of text on the desktop, about 48), because the judgements saved up
// for it were spent by the calls that came before it. These tests drive the real cover layer with a fake judge that
// keeps the detector's order of work and its costs. Synthetic rectangles only; time is simulated.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

/// A fake judge with the detector's order of work and costs: in a call, entries never judged come first (the whole pass
/// right after the first picture), then the ones judged longest ago; an entry is judged only when its whole cost fits
/// what is left of the call's budget, and the cost of the first one that did not fit is reported (`nextCost`). An entry
/// judged before and not reached is shown as judged earlier; one never judged is left unjudged (`overload`). Region
/// entries are the screen's pictures inside the call's area; the whole pass is the call's area.
final class CostJudge: Judging {
    struct Entry { var rect: PixelRect; var cost: Int }
    struct Key: Hashable { var pass: JudgePass; var rect: PixelRect }
    var entries: [Entry]
    /// What a call's whole pass costs, by its area.
    var wholeCost: (PixelRect) -> Int
    /// Pictures that flag whenever judged.
    var flagged: Set<PixelRect> = []
    /// Pictures whose next judgement fails (a model fault): left unjudged, and what was seen of them is forgotten.
    var failNext: Set<PixelRect> = []
    /// The first calls judge nothing (the models still loading): every entry is left unjudged, as on a slow first look.
    var blindCalls: Int
    var lastJudged: [Key: Int] = [:]
    var serial = 0
    /// How often each picture has been judged (freshly), and model faults so far.
    var judgedCount: [PixelRect: Int] = [:]
    var faults = 0
    /// Real time each judgement takes (a slow Mac), so a call's time limit caps what it can judge, as it does there.
    var msPerJudgement = 0.0

    init(entries: [Entry], blindCalls: Int = 2, wholeCost: @escaping (PixelRect) -> Int = { _ in 2 }) {
        self.entries = entries; self.blindCalls = blindCalls; self.wholeCost = wholeCost
    }

    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        serial += 1
        let inside = entries.filter { $0.rect.intersection(area) == $0.rect }
        var tasks: [(Key, Int)] = [(Key(pass: .whole, rect: area), wholeCost(area))] + inside.map { (Key(pass: .region, rect: $0.rect), $0.cost) }
        if blindCalls > 0 {
            blindCalls -= 1
            let out = tasks.map { RegionVerdict(rect: $0.0.rect, display: $0.0.pass == .region ? .contain : .cover, reason: .overload, pass: $0.0.pass) }
            return FrameVerdict(regions: out, coverWindow: false, strike: false, hot: false, judgements: 0, overloaded: out.count)
        }
        // Never judged first (the whole pass right after the first picture), then the longest ago first.
        var fresh = tasks.filter { lastJudged[$0.0] == nil }
        if let w = fresh.firstIndex(where: { $0.0.pass == .whole }), w > 1 { let t = fresh.remove(at: w); fresh.insert(t, at: 1) }
        let again = tasks.filter { lastJudged[$0.0] != nil }.sorted { lastJudged[$0.0]! < lastJudged[$1.0]! }
        tasks = fresh + again
        var left = budget, judgements = 0, nextCost = 0
        var chosen: Set<Key> = []
        for (k, c) in tasks {
            if c > left { if nextCost == 0 { nextCost = c }; continue }
            left -= c; judgements += c; chosen.insert(k)
        }
        var out: [RegionVerdict] = [], overloaded = 0, faultsHere = 0
        for (k, _) in tasks {
            if chosen.contains(k) {
                if k.pass == .region, failNext.contains(k.rect) {
                    failNext.remove(k.rect); faults += 1; faultsHere += 1; lastJudged[k] = nil
                    out.append(RegionVerdict(rect: k.rect, display: .contain, reason: .overload, pass: k.pass)); overloaded += 1
                    continue
                }
                lastJudged[k] = serial
                if k.pass == .region { judgedCount[k.rect, default: 0] += 1 }
                let flag = k.pass == .region && flagged.contains(k.rect)
                out.append(RegionVerdict(rect: k.rect, display: flag ? .cover : .clear, reason: flag ? .bothFamilies : .judgedClean, pass: k.pass))
            } else if lastJudged[k] != nil {
                out.append(RegionVerdict(rect: k.rect, display: .clear, reason: .judgedEarlier, pass: k.pass))
            } else {
                out.append(RegionVerdict(rect: k.rect, display: k.pass == .region ? .contain : .cover, reason: .overload, pass: k.pass))
                overloaded += 1
            }
        }
        // The whole pass first, so a cover for it is made before the pictures' covers that it holds.
        out.sort { ($0.pass == .whole ? 0 : 1) < ($1.pass == .whole ? 0 : 1) }
        if judgements > 0 && msPerJudgement > 0 { usleep(useconds_t(Double(judgements) * msPerJudgement * 1000)) }
        return FrameVerdict(regions: out, coverWindow: false, strike: false, hot: false, judgements: judgements, overloaded: overloaded,
                            modelFaults: faultsHere, nextCost: nextCost)
    }
    func setRule(_ rule: DetectorRule) {}
}

@Suite struct StillScreenSettlesTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))

    /// Small pictures on a grid inside `r`, each costing `cost`.
    static func grid(_ r: PixelRect, side: Int = 16, step: Int = 22, cost: Int = 2) -> [CostJudge.Entry] {
        var out: [CostJudge.Entry] = []
        var y = r.y + 3
        while y + side <= r.maxY - 3 {
            var x = r.x + 3
            while x + side <= r.maxX - 3 { out.append(.init(rect: PixelRect(x: x, y: y, w: side, h: side), cost: cost)); x += step }
            y += step
        }
        return out
    }

    /// A thin strip (short side under 64, more than 2:1) costs what the detector's grown whole pass costs over the
    /// virtual Mac's menu bar; anything else is cheap.
    static func wholeCost(_ a: PixelRect) -> Int { a.shortSide < 64 && max(a.w, a.h) > 2 * a.shortSide ? 42 : 2 }

    struct Run { var frames: [CoverPlan]; var p: DisplayPipeline }

    /// One complete frame at t = 0, then a look at the last frame every quarter second (what the watcher asks for while
    /// `needsAnotherLook`), for `seconds`. `each` runs before every look (to change the screen or the judge).
    func still(_ p: DisplayPipeline, _ img: RGBAImage, _ snap: WindowSnapshot, seconds: Double,
               each: ((Int, inout RGBAImage) -> [PixelRect]?)? = nil) -> [CoverPlan] {
        var img = img
        var plans = [p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)]
        for k in 1...Int(seconds * 4) {
            let t = Double(k) * 0.25
            if let changed = each?(k, &img) {
                plans.append(p.process(Fixtures.frame(img, display: d, scale: 1, dirty: changed, t: t), snapshot: snap, now: t))
            } else {
                plans.append(p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t))
            }
        }
        return plans
    }

    /// The frame from which nothing was drawn to the end, in seconds, if any.
    static func settledAt(_ plans: [CoverPlan]) -> Double? {
        guard let last = plans.lastIndex(where: { $0.wholeDisplay != nil || !$0.items.isEmpty }) else { return 0 }
        return last + 1 < plans.count ? Double(last + 1) / 4 : nil
    }

    var menuBar: WindowInfo { WindowInfo(number: 2, ownerPID: 174, layer: 24, bounds: CGRect(x: 0, y: 0, width: 600, height: 30)) }
    var desktop: WindowInfo { WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 30, width: 600, height: 370)) }

    /// The menu bar's whole-window cover. Its window's call holds one entry, the whole pass over the thin strip, that costs
    /// 42 judgements, more than any call is given while the desktop's covers take the budget as it comes (40 a second).
    /// On main the judgements saved up for it were spent first by the calls before it in every look, so that pass was
    /// never judged and the cover never had a clean round while the desktop had anything left to judge. Now a call saving
    /// up is served in turn: no call that only judges again spends anything until it has been.
    @Test func theMenuBarsDearWholePassIsJudgedWhileTheDesktopStillHasWork() {
        let deskArea = PixelRect(x: 0, y: 30, w: 600, h: 370)
        let judge = CostJudge(entries: Self.grid(deskArea), wholeCost: Self.wholeCost)
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let snap = WindowSnapshot(windows: [desktop, menuBar], time: 0)
        let plans = still(p, Fixtures.blank(600, 400), snap, seconds: 40)
        let menu = CGRect(x: 0, y: 0, width: 600, height: 30)
        let menuGoneAt = plans.lastIndex { $0.items.contains { $0.rect.intersects(menu.insetBy(dx: 1, dy: 1)) } }.map { Double($0 + 1) / 4 }
        #expect(judge.lastJudged[CostJudge.Key(pass: .whole, rect: PixelRect(x: 0, y: 0, w: 600, h: 30))] != nil, "the menu bar's whole pass was judged")
        #expect((menuGoneAt ?? 0) <= 30, "the menu bar's covers lift while the desktop is still being judged: gone at \(menuGoneAt.map { "\($0) s" } ?? "never"); held \(p.heldLines)")
    }

    /// Desktop covers held for one dear entry: a long, thin line of text costs 48 judgements (16 pieces, three models). As
    /// on the virtual Mac, each call is held to the time a look may take (here 12 judgements), the first look has spent
    /// the bucket, and the desktop holds covers of several sizes over the same pictures (what merges and the first slow
    /// looks leave), which take turns. On main the line's call saved up only while it was reached in the same look, and the
    /// calls before it spent what came in, so it was judged only when the bucket happened to fill: the covers kept their
    /// count for minutes at a time, and the screen did not settle within five minutes. Now it settles, and the looks stop.
    @Test func desktopCoversHeldForOneDearPictureLift() {
        let line = PixelRect(x: 320, y: 380, w: 260, h: 12)
        let judge = CostJudge(entries: Self.grid(PixelRect(x: 0, y: 30, w: 300, h: 370)) + Self.grid(PixelRect(x: 300, y: 30, w: 300, h: 340))
                                  + [.init(rect: line, cost: 48)], blindCalls: 2, wholeCost: Self.wholeCost)
        judge.msPerJudgement = 0.5
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: 6)
        let snap = WindowSnapshot(windows: [desktop, menuBar], time: 0)
        let plans = still(p, Fixtures.blank(600, 400), snap, seconds: 300) { k, _ in
            guard k == 1 else { return nil }
            p.bucket.spend(Int(Register.JUDGEMENT_BURST))
            let t = JudgeTarget.window(number: desktop.number, ownerPID: desktop.ownerPID)
            p.held += [CGRect(x: 0, y: 0, width: 600, height: 370), CGRect(x: 0, y: 100, width: 600, height: 270),
                       CGRect(x: 200, y: 200, width: 400, height: 170), CGRect(x: 310, y: 340, width: 280, height: 30)].map {
                DisplayPipeline.Held(target: t, rel: $0, whole: false, kind: .plain, clean: 0)
            }
            return nil
        }
        #expect((judge.judgedCount[line] ?? 0) >= Register.VIDEO_VOTE, "the dear line was judged \(judge.judgedCount[line] ?? 0) times")
        let at = Self.settledAt(plans)
        #expect(at != nil, "settled; held \(p.heldLines)")
        #expect(!p.needsAnotherLook, "nothing left to judge: the looks stop")
    }

    /// Many entries per round: a cover over most of the desktop that needs about 1,000 entries judged for each clean
    /// round, far more than one call or one second's budget. Its rounds gather over many looks while the pixels under it
    /// stay the same, so it still lifts after four of them, and no sooner.
    @Test func aCoverNeedingMoreEntriesThanAnyLookCanJudgeStillLifts() {
        let judge = CostJudge(entries: Self.grid(PixelRect(x: 0, y: 0, w: 600, h: 400), side: 8, step: 15), blindCalls: 1)
        #expect(judge.entries.count >= 1000)
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let plans = still(p, Fixtures.blank(600, 400), Fixtures.oneWindow(d.bounds), seconds: 300)
        let at = Self.settledAt(plans)
        #expect(at != nil, "settled; held \(p.heldLines)")
        // Four rounds of every picture (two judgements each) at 40 a second, after the bucket's first 400.
        let least = (Double(4 * 2 * judge.entries.count) - Register.JUDGEMENT_BURST) / Register.JUDGEMENT_BUDGET
        if let at { #expect(at >= least * 0.9, "not before four whole rounds: settled at \(at) s, four rounds need about \(least) s") }
        #expect(judge.judgedCount.values.allSatisfy { $0 >= Register.VIDEO_VOTE }, "every picture judged clean four times before the lift")
        #expect(!p.needsAnotherLook)
    }

    // MARK: Fail closed, with the dear entries served in turn

    /// A flagged picture on the same busy, still screen stays covered for good, with a dear entry saved up for next to it;
    /// the menu bar, with nothing flagged in it, still settles.
    @Test func aFlaggedPictureStaysCovered() {
        let deskArea = PixelRect(x: 0, y: 30, w: 600, h: 370)
        var entries = Self.grid(deskArea)
        let bad = entries[40].rect
        entries.append(.init(rect: PixelRect(x: 400, y: 386, w: 190, h: 10), cost: 48))
        let judge = CostJudge(entries: entries, wholeCost: Self.wholeCost)
        judge.flagged = [bad]
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let plans = still(p, Fixtures.blank(600, 400), WindowSnapshot(windows: [desktop, menuBar], time: 0), seconds: 200)
        let g = CGRect(x: bad.x, y: bad.y, width: bad.w, height: bad.h)
        let firstCovered = plans.firstIndex { $0.covers(g, kind: .plain) }
        #expect(firstCovered != nil)
        if let firstCovered { #expect(plans[firstCovered...].allSatisfy { $0.covers(g, kind: .plain) }, "never lifted once flagged") }
        #expect(p.needsAnotherLook, "a flagged cover is still held")
        let menu = CGRect(x: 0, y: 0, width: 600, height: 30).insetBy(dx: 1, dy: 1)
        #expect(!plans.last!.items.contains { $0.rect.intersects(menu) }, "the menu bar settled: \(p.heldLines)")
    }

    /// A model failure in the middle of a round blocks that round: the cover does not lift on it, and lifts only after
    /// four clean rounds in which every entry was really judged.
    @Test func aModelFailureMidRoundBlocksTheLift() {
        let line = PixelRect(x: 320, y: 380, w: 260, h: 12)
        let entries = Self.grid(PixelRect(x: 0, y: 0, w: 600, h: 370)) + [.init(rect: line, cost: 48)]
        let judge = CostJudge(entries: entries, blindCalls: 1)
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        // The dear line fails every time it is judged for the first minute: no round can complete while it does.
        var plans: [CoverPlan] = []
        plans = still(p, Fixtures.blank(600, 400), Fixtures.oneWindow(d.bounds), seconds: 200) { k, _ in
            if k <= 240 { judge.failNext.insert(line) } else { judge.failNext.remove(line) }
            return nil
        }
        let g = CGRect(x: line.x, y: line.y, width: line.w, height: line.h)
        #expect(judge.faults > 0, "the failure was met")
        #expect(plans[1...240].allSatisfy { $0.covers(g) }, "covered while every judgement of it failed")
        #expect(judge.judgedCount[line, default: 0] >= Register.VIDEO_VOTE, "four real judgements before the lift")
        #expect(Self.settledAt(plans) != nil, "then it settles; held \(p.heldLines)")
    }

    /// A change under a cover starts its count again, even while dear entries are being saved up for: the clean judgements
    /// it had gathered no longer count, and it stays until four more clean rounds of what it hides now.
    @Test func aChangeUnderACoverStartsItsCountAgain() {
        let line = PixelRect(x: 320, y: 380, w: 260, h: 12)
        let judge = CostJudge(entries: Self.grid(PixelRect(x: 0, y: 0, w: 600, h: 370)) + [.init(rect: line, cost: 48)], blindCalls: 1)
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        let spot = PixelRect(x: 330, y: 382, w: 4, h: 4)
        let g = CGRect(x: spot.x, y: spot.y, width: spot.w, height: spot.h)
        func countOverSpot() -> Int {
            p.held.filter { p.fullRect($0, snap, p.visibleByTarget(snap))?.intersects(g) ?? false }.map(\.clean).max() ?? -1
        }
        var before = -1, after = -1
        let changeAt = 160
        let plans = still(p, Fixtures.blank(600, 400), snap, seconds: 120) { k, img in
            if k == changeAt + 1 { after = countOverSpot() }
            guard k == changeAt else { return nil }
            before = countOverSpot()
            img.pixels[(spot.y * 600 + spot.x) * 4] = 7
            return [spot]
        }
        #expect(before > 0, "clean judgements were gathered over the spot before the change: \(before)")
        #expect(after >= 0 && after < before && after <= 1, "the change started the count again: \(before) before, \(after) after")
        // Four new rounds take far longer than the next few looks: still covered just after.
        #expect(plans[changeAt...(changeAt + 8)].allSatisfy { $0.covers(g) }, "still covered right after the change")
    }
}
