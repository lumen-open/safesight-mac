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
