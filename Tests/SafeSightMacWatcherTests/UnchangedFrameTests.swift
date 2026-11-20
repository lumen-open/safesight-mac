// SPDX-License-Identifier: Apache-2.0
// The third live run (20 November 2026): in a virtual Mac every captured frame reported the whole display as changed,
// and every update of the app's own covers (left out of capture) brought a new frame. The screen never settled: about 18
// frames a second, each judged whole, at 120 to 155% of a core. What changed is now read from the pixels, a frame with
// no changed pixel is a "nothing changed" frame, and "nothing changed" no longer erases what a waiting frame changed.
// Synthetic patterns only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

@Suite struct ChangedBlocksTests {
    @Test func samePixelsChangeNothingAndOnePixelChangesOneBlock() throws {
        let a = Fixtures.blank(300, 200)
        #expect(DirtyRegions.changedBlocks(old: a, new: a) == [])
        var b = a
        b.pixels[(150 * 300 + 100) * 4 + 1] &+= 1
        let r = try #require(DirtyRegions.changedBlocks(old: a, new: b))
        #expect(r.count == 1)
        #expect(r[0].x <= 100 && r[0].maxX > 100 && r[0].y <= 150 && r[0].maxY > 150)
        #expect(r[0].w <= DirtyRegions.block && r[0].h <= DirtyRegions.block, "only the block holding the pixel")
        #expect(DirtyRegions.changedBlocks(old: a, new: Fixtures.blank(300, 201)) == nil, "another size: judged whole")
    }

    @Test func everyChangedPlaceIsFoundAtTheEdgesToo() throws {
        let a = Fixtures.blank(301, 199)
        var b = a
        for (x, y) in [(0, 0), (300, 198), (299, 0), (0, 198)] { b.pixels[(y * 301 + x) * 4] &+= 9 }
        let r = try #require(DirtyRegions.changedBlocks(old: a, new: b))
        for (x, y) in [(0, 0), (300, 198), (299, 0), (0, 198)] {
            #expect(r.contains { $0.x <= x && x < $0.maxX && $0.y <= y && y < $0.maxY }, "\(x),\(y)")
        }
    }
}

@Suite struct NothingChangedTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))

    /// A "nothing changed" frame merged with a frame waiting to be judged keeps that frame's changed areas; before, it
    /// turned them into "everything changed", and a slow Mac judged and covered the whole display each time.
    @Test func nothingChangedNeverErasesWhatAWaitingFrameChanged() {
        let img = Fixtures.blank(300, 200)
        let r = PixelRect(x: 32, y: 32, w: 32, h: 32)
        var box = FrameMailbox()
        box.offer(Fixtures.frame(img, display: d, scale: 1, dirty: [r], t: 0))
        box.offer(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0.01))
        #expect(box.peek?.dirty == [r])
        #expect(box.peek?.status == .complete && box.peek?.image != nil)
        var other = FrameMailbox()
        other.offer(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0))
        other.offer(Fixtures.frame(img, display: d, scale: 1, dirty: [r], t: 0.01))
        #expect(other.peek?.dirty == [r])
        #expect(FrameQueue.unjudgedAreas(box.peek!) == [CGRect(x: 32, y: 32, width: 32, height: 32)], "a waiting frame covers only what changed")
    }

    /// A complete frame in which no pixel changed is judged like a "nothing changed" frame: nothing is judged on a still,
    /// clean screen, however long it stays still.
    @Test func aFrameWithNoChangedPixelIsJudgedAsNothingChanged() {
        var img = Fixtures.blank(300, 200)
        Fixtures.paint(&img, PixelRect(x: 40, y: 40, w: 80, h: 80), channel: nil, seed: 3)
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let first = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: Fixtures.oneWindow(d.bounds), now: 0)
        #expect(first.items.isEmpty)
        // Let it finish what a still screen gets (second checks of pictures seen clean once).
        var t = 0.0
        while p.needsAnotherLook && t < 60 {
            t += 0.25
            _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: Fixtures.oneWindow(d.bounds), now: t)
        }
        #expect(!p.needsAnotherLook)
        let settled = p.lastPlan
        var early = 0
        // Well past the full re-judge's rhythm, a frame with no changed pixel (what the capture now sends for a frame its
        // own covers caused) starts no judging and draws nothing new.
        let calls = p.lastTimings
        let again = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: t + 40), snapshot: Fixtures.oneWindow(d.bounds), now: t + 40) { _ in early += 1 }
        #expect(p.lastTimings == calls, "no judging ran")
        #expect(again == settled && early == 0)
    }
}

/// The review of the fix: what a frame reporting nothing changed, a new map, many small changes and other frame kinds do.
@Suite struct UnchangedFrameReviewTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
    var snap: WindowSnapshot { Fixtures.oneWindow(d.bounds) }

    /// A frame that reports nothing changed but whose pixels differ from the last judged frame: the places that changed are
    /// judged (before, nothing outside the covers was, and a flagged picture painted in such a frame got no cover).
    @Test func aFrameReportingNothingWhosePixelsChangedIsJudged() {
        let img = Fixtures.blank(300, 200)
        var b = img
        let flagged = PixelRect(x: 40, y: 40, w: 120, h: 120)
        Fixtures.paintFlagged(&b, flagged)
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let plan = p.process(Fixtures.frame(b, display: d, scale: 1, dirty: [], t: 0.5), snapshot: snap, now: 0.5)
        #expect(plan.covers(CGRect(x: 40, y: 40, width: 120, height: 120)), "\(plan.items.count) covers, whole \(String(describing: plan.wholeDisplay))")
    }

    /// The same pixels under another map on the same stream (the display moved in the arrangement): what changed cannot
    /// be read against the last frame, so everything is judged again rather than taken as "nothing changed".
    @Test func anotherMapOnTheSameStreamIsEverythingChanged() {
        var img = Fixtures.blank(300, 200)
        Fixtures.paint(&img, PixelRect(x: 40, y: 40, w: 120, h: 120), channel: nil, seed: 8)
        let none = WindowSnapshot(windows: [], time: 0)
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: none, now: 0)
        // Well within the full re-judge's rhythm, so only the map change can cause a judgement.
        for k in 1...400 where p.needsAnotherLook {
            let t = Double(k) * 0.05
            _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: none, now: t)
        }
        #expect(!p.needsAnotherLook)
        let moved = DisplayDescriptor(id: 1, bounds: CGRect(x: 500, y: 0, width: 300, height: 200))
        _ = p.process(Fixtures.frame(img, display: moved, scale: 1, dirty: [], t: 25), snapshot: none, now: 25)
        #expect(p.lastTimings.calls > 0, "judged whole, not taken as nothing changed")
    }

    /// Many small changes (blinking dots) count as everything changed rather than thousands of rectangles; the mailbox
    /// never adds lists beyond the same limit.
    @Test func manySmallChangesCountAsEverything() {
        let a = Fixtures.blank(1024, 768)
        var b = a
        var dots = 0
        for y in stride(from: 5, to: 768, by: 64) { for x in stride(from: 5, to: 1024, by: 64) { b.pixels[(y * 1024 + x) * 4] &+= 50; dots += 1 } }
        #expect(dots > DirtyRegions.maxAreas / 2)
        var c = a
        for y in stride(from: 5, to: 768, by: 32) { for x in stride(from: 5, to: 1024, by: 64) { c.pixels[(y * 1024 + x) * 4] &+= 50 } }
        #expect(DirtyRegions.changedBlocks(old: a, new: c) == nil, "more than \(DirtyRegions.maxAreas) places: judged whole")
        #expect(DirtyRegions.changedBlocks(old: a, new: b) != nil)
        var box = FrameMailbox()
        let many = (0..<200).map { PixelRect(x: ($0 % 30) * 32, y: ($0 / 30) * 32, w: 8, h: 8) }
        let disp = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))
        box.offer(Fixtures.frame(a, display: disp, scale: 1, dirty: many, t: 0))
        box.offer(Fixtures.frame(a, display: disp, scale: 1, dirty: many, t: 0.1))
        #expect(box.peek?.dirty == nil, "400 areas: judged whole")
    }

    /// A cover held across a frame in which nothing changed keeps the cover and its clean count.
    @Test func aCoverHeldAcrossANothingChangedFrameKeepsItsCount() {
        let g = PixelRect(x: 100, y: 60, w: 80, h: 80)
        var flag = true
        let judge = VerdictScript { area in
            FrameVerdict(regions: [RegionVerdict(rect: g, display: flag ? .cover : .clear, reason: flag ? .bothFamilies : .judgedClean, pass: .region),
                                   RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)],
                         coverWindow: false, strike: false, hot: false, judgements: 2, overloaded: 0)
        }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        var img = Fixtures.blank(300, 200)
        Fixtures.paint(&img, g, channel: nil, seed: 4)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        flag = false
        _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0.25), snapshot: snap, now: 0.25)
        let before = p.held.map(\.clean)
        #expect(before == [1])
        // A complete frame with the same pixels: judged as nothing changed, so the cover stays and its count is not
        // started again (it can only go up by its own clean judgement).
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: 0.5), snapshot: snap, now: 0.5)
        #expect(plan.covers(CGRect(x: 100, y: 60, width: 80, height: 80)))
        #expect(p.held.count == 1 && p.held[0].clean >= before[0], "\(p.held.map(\.clean))")
    }

    /// Blank and suspended frames merged with waiting frames always mean the display is covered whole and judged whole
    /// after: they never shrink to "nothing changed".
    @Test(arguments: [FrameStatus.blank, .suspended, .stopped])
    func unjudgeableFramesMergedWithWaitingOnesAreEverything(_ s: FrameStatus) {
        let img = Fixtures.blank(300, 200)
        let r = PixelRect(x: 32, y: 32, w: 32, h: 32)
        var box = FrameMailbox()
        box.offer(Fixtures.frame(img, display: d, scale: 1, dirty: [r], t: 0))
        box.offer(CapturedFrame(display: d, status: s, image: nil, map: nil, dirty: [], time: 0.1))
        #expect(box.peek?.status == s && box.peek?.dirty == nil)
        #expect(FrameQueue.unjudgedAreas(box.peek!) == nil, "covered whole while it waits")
        box.offer(Fixtures.frame(img, display: d, scale: 1, dirty: [r], t: 0.2))
        #expect(box.peek?.status == .complete && box.peek?.dirty == nil, "the next pixels are judged whole")
    }
}
