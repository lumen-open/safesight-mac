// SPDX-License-Identifier: Apache-2.0
// What an entry left unjudged covers on a busy Mac. Something new or changed is covered until judged; what a look only
// judges again (a full re-judge of a still window, a part left for a later look) and has no time for stays as it was,
// shown as judged before, and is judged at a later look. Synthetic rectangles only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

@Suite struct CoversUnderLoadTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    func g(_ r: PixelRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }

    /// As on the virtual Mac: a menu bar in front, and a window the size of the display (the Dock's) in front of everything
    /// else, so everything below the menu bar is judged as that window's.
    let menuBar = WindowInfo(number: 2, ownerPID: 174, layer: 24, bounds: CGRect(x: 0, y: 0, width: 600, height: 30))
    let dock = WindowInfo(number: 3, ownerPID: 860, layer: 20, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    var windows: [WindowInfo] { [menuBar, dock] }
    /// What is the Dock's to judge: everything below the menu bar.
    let dockArea = PixelRect(x: 0, y: 30, w: 600, h: 370)
    let clock = PixelRect(x: 540, y: 8, w: 40, h: 14)
    let far = CGRect(x: 420, y: 280, width: 120, height: 80)

    /// A judge that judges everything clean, except that while `starved` is true a call over all of the Dock's area leaves
    /// its whole pass and its slices (as 200-point squares) unjudged, as a call given too little leaves them.
    final class Starved: Judging {
        var starved = false
        var faults = false
        var calls: [PixelRect] = []
        let area: PixelRect
        init(area: PixelRect) { self.area = area }
        func judgeArea(_ frame: RGBAImage, context: JudgeContext, within a: PixelRect, budget: Int,
                       progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
            calls.append(a)
            guard starved, a.intersection(area) == area else { return VerdictScript.clean(a) }
            var out = [RegionVerdict(rect: a, display: .cover, reason: .overload, pass: .whole)]
            var y = a.y
            while y < a.maxY {
                var x = a.x
                while x < a.maxX {
                    out.append(RegionVerdict(rect: PixelRect(x: x, y: y, w: min(200, a.maxX - x), h: min(200, a.maxY - y)), display: .cover, reason: .overload, pass: .slice))
                    x += 200
                }
                y += 200
            }
            return FrameVerdict(regions: out, coverWindow: false, strike: false, hot: false, judgements: 0, overloaded: out.count,
                                modelFaults: faults ? 1 : 0)
        }
        func setRule(_ rule: DetectorRule) {}
    }

    /// A settled screen (judged clean at 0 s and 0.1 s), then, 31 s later, the clock ticks: a full re-judge is due, and
    /// the Dock's call over its whole area is starved.
    func settled() -> (DisplayPipeline, Starved, RGBAImage, WindowSnapshot) {
        let judge = Starved(area: dockArea)
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = WindowSnapshot(windows: windows, time: 0)
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, PixelRect(x: 40, y: 60, w: 300, h: 200), channel: nil, seed: 2)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: 0.1), snapshot: snap, now: 0.1)
        #expect(plan.items.isEmpty && plan.wholeDisplay == nil, "settled")
        judge.starved = true
        return (p, judge, img, snap)
    }

    func tick(_ img: inout RGBAImage, seed: UInt32) { Fixtures.paint(&img, clock, channel: nil, seed: seed) }

    // MARK: Judged again, not covered

    /// Finding D2: a full re-judge of a still window that runs out of budget covered the whole call area (the virtual
    /// Mac's Dock: everything below the menu bar, for 35 s and 170 s), though every pixel in it was judged and shown
    /// before, unchanged. It now stays as it was, and is judged at the next look.
    @Test func aStillWindowsRejudgeThatRunsOutIsNotCovered() {
        let (p, judge, img0, snap) = settled()
        var img = img0
        tick(&img, seed: 9)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [clock], t: 31), snapshot: snap, now: 31)
        #expect(!plan.touches(far), "the unchanged window is in sight: \(plan.items.map(\.rect))")
        #expect(p.held.allSatisfy { $0.target != .window(number: dock.number, ownerPID: dock.ownerPID) }, "nothing held over it: \(p.heldLines)")
        #expect(p.dueAgain.contains { $0.contains(g(dockArea)) }, "the whole pass is judged again later: \(p.dueAgain)")
        #expect(p.needsAnotherLook && p.hasLeftOverWork, "another look is wanted")
        // The next look judges it again, over the same area (the same entry), and then nothing is left.
        judge.starved = false; judge.calls = []
        let next = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 31.25), snapshot: snap, now: 31.25)
        #expect(judge.calls.contains { $0.intersection(dockArea) == dockArea }, "judged again over all of it: \(judge.calls)")
        #expect(p.dueAgain.isEmpty && next.items.isEmpty, "nothing left: \(p.dueAgain), \(next.items.map(\.rect))")
    }

    /// Finding D2b: a small window opens on a settled screen just as a full re-judge is due (the first change after 30 s
    /// of rest always is). Its pixels are the Dock's, so the call is over the whole display; the whole pass and the slices
    /// left unjudged covered most of the display. Only the window, the one thing new, is covered now; the slices of
    /// unchanged places, and the rest of the whole pass, are judged again later.
    @Test func aSmallNewWindowIsCoveredWhereItIsNotOverTheDisplay() {
        let (p, _, img0, _) = settled()
        var img = img0
        let small = PixelRect(x: 200, y: 150, w: 100, h: 90)
        Fixtures.paint(&img, small, channel: nil, seed: 11)
        let win = WindowInfo(number: 9, ownerPID: 900, layer: 3, bounds: g(small))
        let snap = WindowSnapshot(windows: [menuBar, dock, win], time: 31)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [small], t: 31), snapshot: snap, now: 31)
        #expect(plan.covers(g(small), kind: .plain), "the new window, unjudged, is covered plainly")
        #expect(!plan.touches(far), "the rest of the display, unchanged, is in sight: \(plan.items.map(\.rect))")
        let largest = plan.items.map { $0.rect.width * $0.rect.height }.max() ?? 0
        #expect(largest <= 2 * g(small).width * g(small).height, "covered about the window's size: \(plan.items.map(\.rect))")
    }

    // MARK: Trying to break it: anything changed is covered

    /// A pixel that changed in the Dock's area without the frame saying so is covered, whatever the frame reports.
    @Test func aChangeTheFrameDoesNotReportIsCovered() {
        let (p, _, img0, snap) = settled()
        var img = img0
        tick(&img, seed: 9)
        let hidden = PixelRect(x: 450, y: 300, w: 20, h: 20)
        Fixtures.paint(&img, hidden, channel: nil, seed: 12)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [clock], t: 31), snapshot: snap, now: 31)
        #expect(plan.covers(g(hidden)), "covered: \(plan.items.map(\.rect))")
    }

    /// A frame that reports nothing changed, though a pixel in the Dock's area did, at a full re-judge: covered.
    @Test func aFrameReportingNothingChangedThoughAPixelDidIsCovered() {
        let (p, _, img0, snap) = settled()
        var img = img0
        let hidden = PixelRect(x: 450, y: 300, w: 4, h: 4)
        Fixtures.paint(&img, hidden, channel: nil, seed: 13)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: 31), snapshot: snap, now: 31)
        #expect(plan.covers(g(hidden)), "covered: \(plan.items.map(\.rect))")
    }

    /// A change while the whole pass waits to be judged again (between the look that ran out and the next): the next
    /// look, starved again, covers what changed.
    @Test func aChangeWhileItWaitsIsCovered() {
        for reported in [true, false] {
            let (p, _, img0, snap) = settled()
            var img = img0
            tick(&img, seed: 9)
            _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [clock], t: 31), snapshot: snap, now: 31)
            #expect(!p.dueAgain.isEmpty)
            let spot = PixelRect(x: 470, y: 320, w: 30, h: 30)
            Fixtures.paint(&img, spot, channel: nil, seed: 14)
            let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: reported ? [spot] : [], t: 31.25), snapshot: snap, now: 31.25)
            #expect(plan.covers(g(spot)), "covered (reported: \(reported)): \(plan.items.map(\.rect))")
        }
    }

    /// The window list changed (a window in front moved) though no pixel did, as a list read ahead of its frame: where it
    /// stood and where it stands now are covered for the entries left unjudged there.
    @Test func aWindowListThatChangedWithoutThePixelsIsCoveredWhereItChanged() {
        let judge = Starved(area: dockArea)
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let note = WindowInfo(number: 7, ownerPID: 700, layer: 30, bounds: CGRect(x: 60, y: 300, width: 80, height: 60), alpha: 0)
        let snap = WindowSnapshot(windows: [note, menuBar, dock], time: 0)
        var img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: 0.1), snapshot: snap, now: 0.1)
        judge.starved = true
        tick(&img, seed: 9)
        let movedNote = WindowInfo(number: 7, ownerPID: 700, layer: 30, bounds: CGRect(x: 300, y: 300, width: 80, height: 60), alpha: 0)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [clock], t: 31),
                             snapshot: WindowSnapshot(windows: [movedNote, menuBar, dock], time: 31), now: 31)
        #expect(plan.covers(note.bounds) && plan.covers(movedNote.bounds), "where the list changed is covered: \(plan.items.map(\.rect))")
        #expect(!plan.touches(CGRect(x: 450, y: 60, width: 100, height: 100)), "elsewhere it is as it was: \(plan.items.map(\.rect))")
    }

    /// A model failure is a fault: what it left unjudged is covered, unchanged or not.
    @Test func aModelFailureIsCoveredAsBefore() {
        let (p, judge, img0, snap) = settled()
        judge.faults = true
        var img = img0
        tick(&img, seed: 9)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [clock], t: 31), snapshot: snap, now: 31)
        #expect(plan.covers(far, kind: .plain), "covered: \(plan.items.map(\.rect))")
    }

    /// It waits at most `JUDGING_STALL`: a window whose re-judge keeps running out is covered from then on, as before.
    @Test func itWaitsNoLongerThanTheStallLimit() {
        let (p, _, img0, snap) = settled()
        var img = img0
        tick(&img, seed: 9)
        var plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [clock], t: 31), snapshot: snap, now: 31)
        var t = 31.0
        while t < 31 + Register.JUDGING_STALL + 1 && !plan.touches(far) {
            t += 0.25
            plan = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t)
        }
        #expect(plan.covers(far), "covered once it has waited past JUDGING_STALL (at \(t - 31) s)")
        #expect(t - 31 >= Register.JUDGING_STALL - 0.26, "and not before: \(t - 31) s")
    }

    /// Anything held covered stays covered: an entry left unjudged over a held cover is never "shown as judged before".
    @Test func whatWasCoveredIsNeverTreatedAsShown() {
        let (p, _, img0, snap) = settled()
        let t = JudgeTarget.window(number: dock.number, ownerPID: dock.ownerPID)
        let spot = CGRect(x: 420, y: 280, width: 60, height: 40)
        p.held.append(DisplayPipeline.Held(target: t, rel: spot, whole: false, kind: .plain, clean: 0, everFlagged: true))
        var img = img0
        tick(&img, seed: 9)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [clock], t: 31), snapshot: snap, now: 31)
        #expect(plan.covers(spot, kind: .plain), "still covered")
        #expect(p.held.contains { $0.target == t && $0.rel.contains(spot) }, "and still held: \(p.heldLines)")
    }

    // MARK: The cost of a judgement

    /// A call over a large area that made few judgements costs mostly what any call over that area costs (finding pictures,
    /// working out keys). It no longer makes a judgement look dear: on the virtual Mac one background check over the
    /// whole display took the estimate from 7 to 53 ms, and every call for a minute after was given a fifth of what it
    /// had time for.
    @Test func aDearCallWithFewJudgementsDoesNotMakeJudgementsLookDear() {
        let p = DisplayPipeline(display: d, judger: VerdictScript { VerdictScript.clean($0) }, budgetShare: 1e6, ignoredPIDs: [])
        p.msPerJudgement = 8
        var v = VerdictScript.clean(dockArea)
        v.judgements = 2; v.overheadMs = 290
        p.noteCallCost(306, v)
        #expect(p.msPerJudgement < 9, "\(p.msPerJudgement)")
        // Without a measure of the overhead, the whole call counts, as before.
        v.overheadMs = 0
        p.noteCallCost(306, v)
        #expect(p.msPerJudgement > 40)
    }
}
