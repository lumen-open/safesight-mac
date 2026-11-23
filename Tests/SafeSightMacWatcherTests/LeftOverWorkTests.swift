// SPDX-License-Identifier: Apache-2.0
// What a look leaves for later, and what may wait for a later look shown as judged before. Synthetic rectangles only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

/// A scripted judge that also moves the pipeline's clock by `msPerCall` at every call, so what a look has time for is
/// decided by the test.
final class TimedScript: Judging {
    var answer: (PixelRect) -> FrameVerdict
    var calls: [PixelRect] = []
    var msPerCall: Double
    var clockNs: UInt64 = 1_000_000_000
    init(msPerCall: Double = 1, _ answer: @escaping (PixelRect) -> FrameVerdict) { self.msPerCall = msPerCall; self.answer = answer }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        calls.append(area)
        clockNs += UInt64(msPerCall * 1_000_000)
        return answer(area)
    }
    func setRule(_ rule: DetectorRule) {}
}

@Suite struct LeftOverWorkTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    func g(_ r: PixelRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }
    func idle(_ t: TimeInterval) -> CapturedFrame { CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t) }

    // MARK: Only what was left unjudged is left for later

    /// A slice the budget did not reach, in a call over the whole window (a full re-judge).
    let slice = PixelRect(x: 300, y: 100, w: 100, h: 100)
    /// What keeps changing (a video, say), far from the slice.
    let busy = PixelRect(x: 20, y: 20, w: 60, h: 40)

    /// Clean over the whole call, but the slice left unjudged whenever the call reaches it (until `judgeSliceAfter` calls).
    func sliceJudge(leaveSlice: @escaping () -> Bool) -> TimedScript {
        let s = slice
        return TimedScript { area in
            var v = VerdictScript.clean(area)
            if leaveSlice(), area.intersection(s) == s {
                v.regions.append(RegionVerdict(rect: s, display: .cover, reason: .overload, pass: .slice))
                v.overloaded = 1
            }
            return v
        }
    }

    /// After a call over the whole window leaves one slice unjudged, only that slice is left for later: the next call,
    /// over what changed since, reaches as far as the slice and no further. Before, the whole call area was left for later
    /// and every later call was over the whole window for as long as anything in it kept changing.
    @Test func aCallLeavesForLaterOnlyWhatItLeftUnjudged() {
        var leave = true
        let judge = sliceJudge(leaveSlice: { leave })
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        var img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        #expect(p.pending.map { $0.integral } == [g(slice)], "only the slice is left: \(p.pending)")
        leave = false
        Fixtures.paint(&img, busy, channel: nil, seed: 3)
        judge.calls = []
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [busy], t: 0.1), snapshot: snap, now: 0.1)
        // (What changed is read in blocks of 16 pixels.)
        let first = judge.calls.first
        #expect(first.map { $0.maxX <= slice.maxX + 16 && $0.maxY <= slice.maxY + 16 && $0.x <= busy.x && $0.y <= busy.y } == true,
                "the next call spans what changed and the slice, not the whole window: \(String(describing: first))")
    }

    /// The slice left unjudged stays covered where it stands, plainly, until its own cover has had four clean rounds, even
    /// though the later calls are no longer over the whole window.
    @Test func whatWasLeftUnjudgedStaysCoveredUntilItsOwnCleanRounds() {
        var leave = true
        let judge = sliceJudge(leaveSlice: { leave })
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        var img = Fixtures.blank(600, 400)
        var plan = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        #expect(plan.covers(g(slice), kind: .plain), "covered plainly at once: a slice left unjudged")
        leave = false
        var t = 0.0
        var lifted: Int?
        for k in 1...10 {
            t += 0.1
            Fixtures.paint(&img, busy, channel: nil, seed: UInt32(3 + k))
            plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [busy], t: t), snapshot: snap, now: t)
            if !plan.touches(g(slice)) { lifted = k; break }
        }
        #expect(lifted != nil && lifted! >= Register.VIDEO_VOTE, "lifts only after four clean rounds: look \(String(describing: lifted))")
    }

    /// A call that says it left something unjudged without saying where leaves its whole area for later.
    @Test func unjudgedWithoutAPlaceLeavesTheWholeCallForLater() {
        let judge = TimedScript { area in
            var v = VerdictScript.clean(area); v.overloaded = 1; return v
        }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: Fixtures.oneWindow(d.bounds), now: 0)
        #expect(p.pending == [d.bounds], "\(p.pending)")
    }

    // MARK: A part unchanged since the last frame waits, shown as judged before

    /// Two windows side by side; the left one keeps changing.
    let left = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
    let right = WindowInfo(number: 2, ownerPID: 600, layer: 0, bounds: CGRect(x: 300, y: 0, width: 300, height: 400))
    let change = PixelRect(x: 40, y: 40, w: 200, h: 200)
    let rightArea = CGRect(x: 300, y: 0, width: 300, height: 400)

    /// A pipeline where every call takes 300 ms against a 250 ms limit: a look judges the first part it comes to and no
    /// other. Judged once, clean; then 31 s later, a full re-judge is due.
    func busyRig(_ windows: [WindowInfo]) -> (DisplayPipeline, TimedScript, RGBAImage, WindowSnapshot) {
        let judge = TimedScript(msPerCall: 300) { VerdictScript.clean($0) }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: 250)
        p.clock = { [unowned judge] in judge.clockNs }
        let snap = WindowSnapshot(windows: windows, time: 0)
        let img = Fixtures.blank(600, 400)
        judge.msPerCall = 1
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: 0.1), snapshot: snap, now: 0.1)
        judge.msPerCall = 300
        return (p, judge, img, snap)
    }

    /// As `busyRig`, then a full re-judge on a frame where only the left window changed: the right window, unchanged,
    /// waits for the next look (the reported areas were just checked against the pixels, so the next frame is not).
    func dueRig(_ windows: [WindowInfo]) -> (DisplayPipeline, RGBAImage, WindowSnapshot) {
        let (p, _, img0, snap) = busyRig(windows)
        var img = img0
        Fixtures.paint(&img, change, channel: nil, seed: 4)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [change], t: 30.95), snapshot: snap, now: 30.95)
        #expect(p.dueAgain.contains { $0.intersects(rightArea) }, "waiting: \(p.dueAgain)")
        return (p, img, snap)
    }

    /// At a full re-judge on a frame where the left window changed, the right window, whose every pixel is as in the last
    /// frame and was judged, is not blurred for want of time: it waits for the next looks, shown as judged before, as a
    /// still screen's parts do. Before, it was blurred and its re-judge went ahead of the left window's new content at the
    /// next look.
    @Test func anUnchangedWindowWaitsShownAsJudgedBefore() {
        let (p, _, img0, snap) = busyRig([left, right])
        var img = img0
        Fixtures.paint(&img, change, channel: nil, seed: 5)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [change], t: 31), snapshot: snap, now: 31)
        #expect(!plan.touches(rightArea), "the unchanged window is shown as judged: \(plan.items.map(\.rect))")
        #expect(p.dueAgain.contains { $0.intersects(rightArea) }, "and is judged at the next looks")
        #expect(!p.pending.contains { $0.intersects(rightArea) }, "it is not work left over")
    }

    /// The same, but the right window's pixels changed without the frame saying so: it is blurred until judged.
    @Test func aChangeTheFrameDidNotReportIsBlurred() {
        let (p, img0, snap) = dueRig([left, right])
        var img = img0
        Fixtures.paint(&img, change, channel: nil, seed: 5)
        Fixtures.paint(&img, PixelRect(x: 400, y: 300, w: 20, h: 20), channel: nil, seed: 6)   // not reported
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [change], t: 31), snapshot: snap, now: 31)
        #expect(plan.touches(rightArea), "blurred until judged: \(plan.items.map(\.rect))")
        #expect(p.pending.contains { $0.intersects(rightArea) })
    }

    /// The window list a frame late: the right window has moved in the pixels but not yet in the list (its old place shows
    /// new pixels). Its part shows pixels that are not the last frame's: blurred until judged.
    @Test func aWindowListAFrameLateIsBlurred() {
        let (p, img0, snap) = dueRig([left, right])
        var img = img0
        Fixtures.paint(&img, change, channel: nil, seed: 5)
        Fixtures.paint(&img, PixelRect(x: 320, y: 0, w: 280, h: 400), channel: nil, seed: 7)   // what the move drew, not yet in the list
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [change], t: 31), snapshot: snap, now: 31)
        #expect(plan.touches(rightArea), "blurred until judged")
    }

    /// A window in front of the right one moved away (the list changed since the last look): what it uncovered was never
    /// judged as the right window's, so the right window is blurred until judged, as at a still look.
    @Test func aWindowOnTopThatMovedAwayLeavesItsPlaceBlurred() {
        let front = WindowInfo(number: 3, ownerPID: 700, layer: 0, bounds: CGRect(x: 350, y: 50, width: 100, height: 100))
        let (p, _, img0, _) = busyRig([front, left, right])
        var img = img0
        let moved = WindowInfo(number: 3, ownerPID: 700, layer: 0, bounds: CGRect(x: 350, y: 250, width: 100, height: 100))
        Fixtures.paint(&img, change, channel: nil, seed: 5)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [change], t: 31),
                             snapshot: WindowSnapshot(windows: [moved, left, right], time: 31), now: 31)
        #expect(plan.covers(CGRect(x: 350, y: 50, width: 100, height: 100)), "what the window uncovered is blurred until judged: \(plan.items.map(\.rect))")
    }

    /// A see-through window over part of the right one (or one with a hole): what shows through it changed, unreported.
    /// That window's part is blurred until judged; the rest of the right window, unchanged, may wait.
    @Test func aSeeThroughWindowWhoseContentChangedIsBlurred() {
        let glass = WindowInfo(number: 3, ownerPID: 700, layer: 0, bounds: CGRect(x: 350, y: 50, width: 100, height: 100), alpha: 0.5)
        let (p, img0, snap) = dueRig([glass, left, right])
        var img = img0
        Fixtures.paint(&img, change, channel: nil, seed: 5)
        Fixtures.paint(&img, PixelRect(x: 380, y: 80, w: 30, h: 30), channel: nil, seed: 8)   // shows through, unreported
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [change], t: 31), snapshot: snap, now: 31)
        #expect(plan.covers(CGRect(x: 380, y: 80, width: 30, height: 30)), "blurred until judged: \(plan.items.map(\.rect))")
    }

    /// A part left waiting longer than `JUDGING_STALL` is blurred until judged, however unchanged it is.
    @Test func aPartWaitingTooLongIsBlurred() {
        let (p, _, img0, snap) = busyRig([left, right])
        var img = img0
        var t = 31.0, k = 0
        var plan = p.lastPlan
        while t < 31 + Register.JUDGING_STALL + 1 {
            k += 1
            Fixtures.paint(&img, change, channel: nil, seed: UInt32(10 + k))
            plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [change], t: t), snapshot: snap, now: t)
            if plan.touches(rightArea) { break }
            t += 0.3
        }
        #expect(plan.touches(rightArea), "blurred once it has waited past JUDGING_STALL (at \(t - 31) s)")
        #expect(t - 31 >= Register.JUDGING_STALL - 0.31, "and not before: \(t - 31) s")
    }

    /// A part the frame reports as changed is new content: it is blurred until judged even when its pixels turn out the same
    /// as the last frame's (a redraw of the same pixels), never left waiting shown as judged before. Only the "not fresh"
    /// condition tells this case apart: the pixels match, nothing is left unjudged and the window list is the same.
    @Test func aReportedChangeIsNeverLeftWaitingEvenWithTheSamePixels() {
        let (p, img0, snap) = dueRig([left, right])
        var img = img0
        Fixtures.paint(&img, change, channel: nil, seed: 5)
        let sameRight = PixelRect(x: 400, y: 100, w: 100, h: 100)   // reported, but its pixels are as before
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [change, sameRight], t: 31), snapshot: snap, now: 31)
        #expect(plan.covers(g(sameRight)), "blurred until judged: \(plan.items.map(\.rect))")
        #expect(p.pending.contains { $0.contains(g(sameRight)) }, "it is work left over")
        #expect(!p.dueAgain.contains { $0.intersects(g(sameRight).insetBy(dx: 1, dy: 1)) }, "not left waiting: \(p.dueAgain)")
        // The rest of the window, unreported and as it was, is shown as judged before and waits for a later look.
        #expect(!plan.touches(CGRect(x: 520, y: 260, width: 60, height: 120)), "the rest stays as it was: \(plan.items.map(\.rect))")
    }

    // MARK: Covers over exactly the same place are one

    func dupRig(_ a: DisplayPipeline.Held, _ b: DisplayPipeline.Held) -> DisplayPipeline {
        let p = DisplayPipeline(display: d, judger: VerdictScript { VerdictScript.clean($0) }, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: Fixtures.oneWindow(d.bounds), now: 0)
        p.held = [a, b]
        return p
    }
    let t10 = JudgeTarget.window(number: 10, ownerPID: 500)
    let spot = CGRect(x: 100, y: 100, width: 80, height: 60)

    /// Two covers of the same window over exactly the same rectangle become one, judged by one call a round. Before, each
    /// took its own call at every round (after a minute of scrolling a busy page, half the covers held were such pairs).
    @Test func twoCoversOverTheSamePlaceBecomeOne() {
        let p = dupRig(.init(target: t10, rel: spot, whole: false, kind: .plain, clean: 0), .init(target: t10, rel: spot, whole: false, kind: .plain, clean: 0))
        _ = p.process(idle(0.1), snapshot: Fixtures.oneWindow(d.bounds), now: 0.1)
        #expect(p.held.count == 1, "\(p.heldLines)")
    }

    /// The one left keeps the most cautious state: the lower count (it lifts no sooner than the slower of the two would
    /// have) with its own round, ever flagged if either was, plain if either was, and judged again as soon as either was due.
    @Test func theCoverLeftKeepsTheMostCautiousState() {
        let e1 = DisplayPipeline.EntryKey(pass: .whole, rect: PixelRect(x: 100, y: 100, w: 80, h: 60))
        let e2 = DisplayPipeline.EntryKey(pass: .region, rect: PixelRect(x: 110, y: 110, w: 20, h: 20))
        var a = DisplayPipeline.Held(target: t10, rel: spot, whole: false, kind: .blur(BlurTile(columns: 1, rows: 1, rgba: [9, 9, 9, 255])), clean: 3)
        a.fromOverload = true; a.round = [e1, e2]
        var b = DisplayPipeline.Held(target: t10, rel: spot, whole: false, kind: .plain, clean: 1)
        b.everFlagged = true; b.round = [e1]
        b.flaggedAt = spot; b.flaggedWhen = 5
        let p = dupRig(a, b)
        p.mergeDuplicates()
        #expect(p.held.count == 1, "\(p.heldLines)")
        let m = p.held[0]
        #expect(m.clean == 1, "the lower count: \(m.clean)")
        #expect(m.round == [e1], "the round of the cover with the lower count: \(m.round)")
        #expect(m.everFlagged, "ever flagged")
        #expect(m.kind == .plain, "plain")
        #expect(m.flaggedAt == spot && m.flaggedWhen == 5, "judged again when the flagged one was due")
        // Merged the other way round: the same.
        let q = dupRig(b, a)
        q.mergeDuplicates()
        #expect(q.held.count == 1 && q.held[0].clean == 1 && q.held[0].everFlagged && q.held[0].round == [e1] && q.held[0].kind == .plain)
    }

    /// With the same count, the round keeps only the entries both covers have: an entry judged clean over one only is not
    /// yet a clean judgement of what the other hides.
    @Test func withTheSameCountOnlySharedRoundEntriesStay() {
        let e1 = DisplayPipeline.EntryKey(pass: .whole, rect: PixelRect(x: 100, y: 100, w: 80, h: 60))
        let e2 = DisplayPipeline.EntryKey(pass: .region, rect: PixelRect(x: 110, y: 110, w: 20, h: 20))
        let e3 = DisplayPipeline.EntryKey(pass: .region, rect: PixelRect(x: 140, y: 120, w: 20, h: 20))
        var a = DisplayPipeline.Held(target: t10, rel: spot, whole: false, kind: .plain, clean: 2); a.round = [e1, e2]
        var b = DisplayPipeline.Held(target: t10, rel: spot, whole: false, kind: .plain, clean: 2); b.round = [e1, e3]
        let p = dupRig(a, b)
        p.mergeDuplicates()
        #expect(p.held.count == 1 && p.held[0].round == [e1], "\(p.held.map(\.round))")
    }

    /// A cover that may be counted by a larger cover's call stays so only if both could be: one made for unjudged entries
    /// merged with one that was not (a flag's cover) is judged at its own size from then on.
    @Test func countedInsideOnlyIfBothCouldBe() {
        var a = DisplayPipeline.Held(target: t10, rel: spot, whole: false, kind: .plain, clean: 0); a.fromOverload = true
        let b = DisplayPipeline.Held(target: t10, rel: spot, whole: false, kind: .plain, clean: 0)
        #expect(a.countableInside && !b.countableInside)
        for (x, y) in [(a, b), (b, a)] {
            let p = dupRig(x, y)
            p.mergeDuplicates()
            #expect(p.held.count == 1 && !p.held[0].countableInside, "\(p.heldLines)")
        }
        var c = DisplayPipeline.Held(target: t10, rel: spot, whole: false, kind: .plain, clean: 0); c.fromOverload = true; c.fromMotion = true
        let p = dupRig(a, c)
        p.mergeDuplicates()
        #expect(p.held.count == 1 && !p.held[0].countableInside, "a copy where content went is never counted inside: \(p.heldLines)")
    }

    /// Covers over the same place of different windows, or over places that only overlap, are not merged.
    @Test func onlyTheSamePlaceOfTheSameWindowIsMerged() {
        let other = JudgeTarget.window(number: 11, ownerPID: 501)
        let p = dupRig(.init(target: t10, rel: spot, whole: false, kind: .plain, clean: 0), .init(target: other, rel: spot, whole: false, kind: .plain, clean: 0))
        p.mergeDuplicates()
        #expect(p.held.count == 2)
        p.held = [.init(target: t10, rel: spot, whole: false, kind: .plain, clean: 0),
                  .init(target: t10, rel: spot.offsetBy(dx: 1, dy: 0), whole: false, kind: .plain, clean: 0)]
        p.mergeDuplicates()
        #expect(p.held.count == 2)
    }
}
