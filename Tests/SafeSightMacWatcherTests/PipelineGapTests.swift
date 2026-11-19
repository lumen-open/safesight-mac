// SPDX-License-Identifier: Apache-2.0
// Gaps in the cover layer found in review. Synthetic marker patterns only; the real detector runs on fake models.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

/// A judge that answers with a verdict a test writes, for the cover layer's side of the contract.
final class VerdictScript: Judging {
    var answer: (PixelRect) -> FrameVerdict
    var calls: [PixelRect] = []
    init(_ answer: @escaping (PixelRect) -> FrameVerdict) { self.answer = answer }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        calls.append(area)
        return answer(area)
    }
    func setRule(_ rule: DetectorRule) {}

    static func clean(_ area: PixelRect) -> FrameVerdict {
        FrameVerdict(regions: [RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)],
                     coverWindow: false, strike: false, hot: false, judgements: 2, overloaded: 0)
    }
}

@Suite struct PipelineGapTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let win = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    var snap: WindowSnapshot { WindowSnapshot(windows: [win], time: 0) }

    func pipeline() -> DisplayPipeline { DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity) }

    func idle(_ t: TimeInterval) -> CapturedFrame { CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t) }

    // MARK: Hot

    @Test func aWindowThatTurnsHotIsJudgedAgainWhereItShows() {
        let p = pipeline()
        var img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        // A small picture that is not clean (a fifth of it red, under the cut-off) appears and is shown.
        let small = PixelRect(x: 40, y: 40, w: 40, h: 40)
        Fixtures.paint(&img, small, channel: nil, seed: 3)
        Fixtures.paint(&img, PixelRect(x: 40, y: 40, w: 40, h: 8), channel: 0, seed: 5)
        let g = CGRect(x: 40, y: 40, width: 40, height: 40)
        let first = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 32, y: 32, w: 56, h: 56)], t: 0.1), snapshot: snap, now: 0.1)
        #expect(!first.covers(g), "not hot yet: shown")
        // Then a picture both families flag appears elsewhere in the window: it turns hot.
        Fixtures.paintFlagged(&img, PixelRect(x: 300, y: 150, w: 120, h: 120))
        let second = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 296, y: 144, w: 128, h: 128)], t: 0.2), snapshot: snap, now: 0.2)
        #expect(second.covers(CGRect(x: 300, y: 150, width: 120, height: 120)))
        // Nothing else changes: the small picture is judged again under the hot rule and blurred.
        let third = p.process(idle(0.3), snapshot: snap, now: 0.3)
        #expect(third.covers(g, kind: .blur(BlurTile(columns: 1, rows: 1, rgba: [0, 0, 0, 255]))), "\(third.items.map(\.rect))")
    }

    // MARK: Whole-pass flag

    @Test func aFlaggedWholePassCoversTheCallAreaEvenWithARegionCover() {
        // The changed area is part of the window. The whole pass over it flags, and one small region in it is covered
        // too: the rest of the changed area must not be left showing.
        let changed = PixelRect(x: 100, y: 100, w: 200, h: 160)
        let region = PixelRect(x: 110, y: 110, w: 40, h: 40)
        var flagNext = false
        let judge = VerdictScript { area in
            guard flagNext else { return VerdictScript.clean(area) }
            return FrameVerdict(regions: [RegionVerdict(rect: region, display: .cover, reason: .bothFamilies, pass: .region),
                                          RegionVerdict(rect: area, display: .cover, reason: .bothFamilies, pass: .whole)],
                                coverWindow: true, strike: false, hot: false, judgements: 4, overloaded: 0)
        }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        var img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        flagNext = true
        img.pixels[(150 * 600 + 150) * 4] = 9
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [changed], t: 0.1), snapshot: snap, now: 0.1)
        #expect(plan.covers(CGRect(x: 100, y: 100, width: 200, height: 160)), "\(plan.items.map(\.rect))")
    }

    // MARK: The window list

    func flaggedAt(_ r: PixelRect) -> RGBAImage {
        var img = Fixtures.blank(600, 400)
        Fixtures.paintFlagged(&img, r)
        return img
    }

    func touched(_ img: RGBAImage, _ v: UInt8) -> RGBAImage {
        var i = img; i.pixels[(395 * 600 + 595) * 4] = v; return i
    }
    let corner = [PixelRect(x: 584, y: 384, w: 16, h: 16)]

    @Test func anUnreadableWindowListCoversTheDisplayAndKeepsEveryCover() {
        let p = pipeline()
        let w = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 300, y: 150, width: 280, height: 240))
        let img = flaggedAt(PixelRect(x: 400, y: 250, w: 100, h: 100))
        let g = CGRect(x: 400, y: 250, width: 100, height: 100)
        let list = WindowSnapshot(windows: [w], time: 0)
        #expect(p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: list, now: 0).covers(g))
        let lost = p.process(Fixtures.frame(touched(img, 7), display: d, scale: 1, dirty: corner, t: 0.1), snapshot: .unreadable(time: 0.1), now: 0.1)
        #expect(lost.wholeDisplay == .windowListUnreadable)
        #expect(!p.held.isEmpty, "the covers are kept")
        let back = p.process(Fixtures.frame(touched(img, 8), display: d, scale: 1, dirty: corner, t: 0.2), snapshot: list, now: 0.2)
        #expect(back.wholeDisplay == nil && back.covers(g))
    }

    @Test func aCoverStaysWhereItStoodWhenItsWindowIsMissingFromTheList() {
        // The window is far from the display's origin: the cover must stay over the picture, not move to the corner.
        let p = pipeline()
        let w = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 300, y: 150, width: 280, height: 240))
        let img = flaggedAt(PixelRect(x: 400, y: 250, w: 100, h: 100))
        let g = CGRect(x: 400, y: 250, width: 100, height: 100)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: WindowSnapshot(windows: [w], time: 0), now: 0)
        // The list leaves the window out, the picture is still on screen, frame after frame.
        for k in 1...8 {
            let t = 0.3 * Double(k)
            var next = img; next.pixels[(5 * 600 + 5) * 4] = UInt8(k)
            let plan = p.process(Fixtures.frame(next, display: d, scale: 1, dirty: [PixelRect(x: 0, y: 0, w: 16, h: 16)], t: t), snapshot: .empty, now: t)
            #expect(plan.covers(g), "frame \(k): \(plan.items.map(\.rect))")
            #expect(p.held.contains { $0.target == .window(number: 1, ownerPID: 500) }, "the window's own cover is kept")
        }
    }

    @Test func aCoverOfAClosedWindowLiftsOnceItsPlaceIsJudgedClean() {
        let p = pipeline()
        let w = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 300, y: 150, width: 280, height: 240))
        let g = CGRect(x: 400, y: 250, width: 100, height: 100)
        _ = p.process(Fixtures.frame(flaggedAt(PixelRect(x: 400, y: 250, w: 100, h: 100)), display: d, scale: 1, t: 0),
                      snapshot: WindowSnapshot(windows: [w], time: 0), now: 0)
        // The window closes: its place now shows the plain desktop.
        let empty = Fixtures.blank(600, 400)
        let shut = p.process(Fixtures.frame(empty, display: d, scale: 1, dirty: [PixelRect(x: 300, y: 150, w: 280, h: 240)], t: 0.1),
                             snapshot: .empty, now: 0.1)
        #expect(shut.covers(g), "not lifted on one list read")
        var t = 0.1, plan = shut
        while t < 3 && !plan.items.isEmpty {
            t += 0.3
            plan = p.process(Fixtures.frame(touched(empty, UInt8(t * 10)), display: d, scale: 1, dirty: corner, t: t), snapshot: .empty, now: t)
        }
        #expect(plan.items.isEmpty, "lifted once the place was judged clean")
    }

    @Test func judgementsFromBeforeAWindowWentNeverLiftItsCover() {
        let p = DisplayPipeline(display: d, judger: VerdictScript { VerdictScript.clean($0) }, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let w = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 300, y: 150, width: 280, height: 240))
        let img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: WindowSnapshot(windows: [w], time: 0), now: 0)
        let g = CGRect(x: 400, y: 250, width: 100, height: 100)
        // A cover three clean judgements from lifting, while its window was there.
        p.held = [DisplayPipeline.Held(target: .window(number: 1, ownerPID: 500), rel: CGRect(x: 100, y: 100, width: 100, height: 100),
                                       whole: false, kind: .plain, clean: 3, lastGlobal: g)]
        let gone = p.process(Fixtures.frame(touched(img, 1), display: d, scale: 1, dirty: corner, t: 0.1), snapshot: .empty, now: 0.1)
        #expect(gone.covers(g), "one fresh judgement and old ones do not lift it")
        let later = p.process(Fixtures.frame(touched(img, 2), display: d, scale: 1, dirty: corner, t: 0.6), snapshot: .empty, now: 0.6)
        #expect(later.covers(g), "gone under WINDOW_GONE")
        let after = p.process(Fixtures.frame(touched(img, 3), display: d, scale: 1, dirty: corner, t: 1.2), snapshot: .empty, now: 1.2)
        #expect(!after.covers(g), "gone long enough and judged clean since")
    }

    // MARK: Windows in front

    @Test func aWindowInFrontNeverDropsAWholeWindowCover() {
        let p = pipeline()
        let back = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 40, y: 40, width: 400, height: 300))
        let img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: WindowSnapshot(windows: [back], time: 0), now: 0)
        p.held = [DisplayPipeline.Held(target: .window(number: 1, ownerPID: 500), rel: .null, whole: true, kind: .plain, clean: 0)]
        let body = CGRect(x: 40, y: 140, width: 400, height: 200)
        // A see-through window the size of the display comes in front; then one over the lower half only.
        let all = WindowInfo(number: 9, ownerPID: 900, layer: 0, bounds: d.bounds)
        let a = p.process(Fixtures.frame(touched(img, 1), display: d, scale: 1, dirty: corner, t: 0.1),
                          snapshot: WindowSnapshot(windows: [all, back], time: 0.1), now: 0.1)
        #expect(a.covers(body), "whole window, under a window in front")
        let half = WindowInfo(number: 9, ownerPID: 900, layer: 0, bounds: CGRect(x: 0, y: 240, width: 600, height: 160))
        let b = p.process(Fixtures.frame(touched(img, 2), display: d, scale: 1, dirty: corner, t: 0.2),
                          snapshot: WindowSnapshot(windows: [half, back], time: 0.2), now: 0.2)
        #expect(b.covers(CGRect(x: 40, y: 250, width: 400, height: 80)), "the part under the window in front")
        let idle = p.process(idle(0.3), snapshot: WindowSnapshot(windows: [all, back], time: 0.3), now: 0.3)
        #expect(idle.covers(body))
    }

    @Test func aRegionCoverIsDrawnInFullOverAWindowInFront() {
        let p = pipeline()
        let back = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        let img = flaggedAt(PixelRect(x: 60, y: 60, w: 120, h: 120))
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: WindowSnapshot(windows: [back], time: 0), now: 0)
        let front = WindowInfo(number: 2, ownerPID: 600, layer: 0, bounds: CGRect(x: 150, y: 0, width: 450, height: 400))
        let plan = p.process(Fixtures.frame(touched(img, 3), display: d, scale: 1, dirty: corner, t: 0.1),
                             snapshot: WindowSnapshot(windows: [front, back], time: 0.1), now: 0.1)
        #expect(plan.covers(CGRect(x: 60, y: 60, width: 120, height: 120)))
        #expect(p.held.contains { $0.target == .window(number: 1, ownerPID: 500) })
    }

    @Test func aCoverUnderAWindowInFrontLiftsOnlyWhenAllOfItIsClean() {
        // The picture's right part lies under a see-through window in front, and stays flagged there.
        let p = pipeline()
        let back = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        let front = WindowInfo(number: 2, ownerPID: 600, layer: 0, bounds: CGRect(x: 150, y: 0, width: 450, height: 400))
        let list = WindowSnapshot(windows: [front, back], time: 0)
        var img = flaggedAt(PixelRect(x: 60, y: 60, w: 120, h: 120))
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: list, now: 0)
        #expect(p.held.contains { $0.target == .window(number: 1, ownerPID: 500) })
        // The visible part turns clean; the part under the front window does not.
        for y in 60..<180 { for x in 60..<150 { let q = (y * 600 + x) * 4; img.pixels[q] = 240; img.pixels[q + 1] = 240; img.pixels[q + 2] = 240 } }
        for k in 1...8 {
            let t = 0.1 * Double(k)
            _ = p.process(Fixtures.frame(touched(img, UInt8(k)), display: d, scale: 1, dirty: [PixelRect(x: 56, y: 56, w: 96, h: 128)] + corner, t: t),
                          snapshot: list, now: t)
        }
        #expect(p.held.contains { $0.target == .window(number: 1, ownerPID: 500) }, "not lifted while part of it is still flagged")
    }

    @Test func aFullyTransparentWindowHidesNothing() {
        let clear = WindowInfo(number: 9, ownerPID: 900, layer: 0, bounds: d.bounds, alpha: 0)
        let back = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 40, y: 40, width: 400, height: 300))
        let vis = WindowSnapshot(windows: [clear, back], time: 0).visibleAreas(on: d.bounds, ignoring: [])
        #expect(vis.first?.0 == .window(number: 1, ownerPID: 500))
        #expect(!vis.contains { $0.0 == .window(number: 9, ownerPID: 900) })
    }

    // MARK: Moved windows and moving content

    @Test func aMovedWindowsCoversAreRedrawnBeforeAnythingIsJudged() {
        final class Watch: Judging {
            let inner = Fixtures.detector()
            var early: [CoverPlan] = []
            var earlyBeforeFirstCall: [CoverPlan]?
            func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                           progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
                if earlyBeforeFirstCall == nil { earlyBeforeFirstCall = early }
                return inner.judgeArea(frame, context: context, within: area, budget: budget, progress: progress)
            }
            func setRule(_ rule: DetectorRule) {}
        }
        let j = Watch()
        let p = DisplayPipeline(display: d, judger: j, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        p.coverGoalMs = 1e9
        _ = p.process(Fixtures.frame(flaggedAt(PixelRect(x: 60, y: 60, w: 100, h: 100)), display: d, scale: 1, t: 0),
                      snapshot: Fixtures.oneWindow(CGRect(x: 40, y: 40, width: 300, height: 300)), now: 0)
        j.earlyBeforeFirstCall = nil; j.early = []
        // The window moves and its content changes too, so nothing is found to have scrolled.
        var movedImg = Fixtures.blank(600, 400)
        Fixtures.paintFlagged(&movedImg, PixelRect(x: 160, y: 60, w: 100, h: 100), seed: 9)
        Fixtures.paint(&movedImg, PixelRect(x: 280, y: 200, w: 120, h: 100), channel: nil, seed: 21)
        _ = p.process(Fixtures.frame(movedImg, display: d, scale: 1, dirty: [PixelRect(x: 40, y: 40, w: 400, h: 300)], t: 0.1),
                      snapshot: Fixtures.oneWindow(CGRect(x: 140, y: 40, width: 300, height: 300)), now: 0.1) { j.early.append($0) }
        let early = j.earlyBeforeFirstCall ?? []
        #expect(early.contains { $0.covers(CGRect(x: 160, y: 60, width: 100, height: 100)) }, "new place, before judging")
        #expect(early.contains { $0.covers(CGRect(x: 60, y: 60, width: 100, height: 100)) }, "old place too")
    }

    @Test func theWindowListTravelsWithThePixels() {
        var box = FrameMailbox()
        let a = WindowSnapshot(windows: [win], time: 1)
        let b = WindowSnapshot(windows: [WindowInfo(number: 2, ownerPID: 600, layer: 0, bounds: d.bounds)], time: 2)
        let img = Fixtures.blank(600, 400)
        box.offer(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: 1).with(windows: a))
        box.offer(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: 2).with(windows: b))
        box.offer(idle(3))
        #expect(box.take()?.windows == b, "the list read with the newest pixels")
    }

    @Test func onlyThePartOfACoverThatMovedGoesWithTheContent() {
        // Textured content in one column scrolls up 16 points; the rest of the window stays still. A cover reaching
        // beyond the column must not move with it.
        let p = pipeline()
        p.coverGoalMs = 1e9
        var tall = Fixtures.blank(600, 432)
        Fixtures.paint(&tall, PixelRect(x: 64, y: 0, w: 200, h: 432), channel: nil, seed: 11)
        func view(_ off: Int) -> RGBAImage {
            var img = Fixtures.blank(600, 400)
            for y in 0..<400 { for x in 64..<264 { for c in 0..<4 { img.pixels[(y * 600 + x) * 4 + c] = tall.pixels[((y + off) * 600 + x) * 4 + c] } } }
            return img
        }
        _ = p.process(Fixtures.frame(view(0), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let wide = CGRect(x: 100, y: 100, width: 300, height: 100)
        p.held = [DisplayPipeline.Held(target: .window(number: 1, ownerPID: 500), rel: wide, whole: false, kind: .plain, clean: 0)]
        let plan = p.process(Fixtures.frame(view(16), display: d, scale: 1, dirty: [PixelRect(x: 64, y: 0, w: 200, h: 400)], t: 0.1),
                             snapshot: snap, now: 0.1)
        // The part in the column goes with its content; the part outside it, where nothing moved, stays.
        #expect(plan.covers(CGRect(x: 264, y: 100, width: 136, height: 100)), "\(plan.items.map(\.rect))")
        #expect(plan.covers(CGRect(x: 100, y: 84, width: 164, height: 100)), "\(plan.items.map(\.rect))")
    }

    @Test func coversNeverMultiplyWhileContentScrolls() {
        // A cover straddles the edge of a column that keeps scrolling, 16 points a frame, for twelve frames.
        let p = pipeline()
        p.coverGoalMs = 1e9
        var tall = Fixtures.blank(600, 400 + 16 * 14)
        Fixtures.paint(&tall, PixelRect(x: 64, y: 0, w: 200, h: tall.height), channel: nil, seed: 11)
        func view(_ off: Int) -> RGBAImage {
            var img = Fixtures.blank(600, 400)
            for y in 0..<400 { for x in 64..<264 { for c in 0..<4 { img.pixels[(y * 600 + x) * 4 + c] = tall.pixels[((y + off) * 600 + x) * 4 + c] } } }
            return img
        }
        _ = p.process(Fixtures.frame(view(0), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let wide = CGRect(x: 100, y: 200, width: 300, height: 100)
        p.held = [DisplayPipeline.Held(target: .window(number: 1, ownerPID: 500), rel: wide, whole: false, kind: .plain, clean: 0)]
        var t = 0.0
        for k in 1...12 {
            t += 0.1
            let plan = p.process(Fixtures.frame(view(16 * k), display: d, scale: 1, dirty: [PixelRect(x: 64, y: 0, w: 200, h: 400)], t: t),
                                 snapshot: snap, now: t)
            #expect(p.held.count <= 4, "frame \(k): \(p.held.count) covers")
            // Until it has earned its clean judgements (the content under it is harmless), the part outside stays.
            if k < Register.VIDEO_VOTE { #expect(plan.covers(CGRect(x: 264, y: 200, width: 136, height: 100)), "the part outside the column stays") }
        }
        // The scrolling stops; every place is judged clean: nothing is left behind.
        let still = view(16 * 12)
        for k in 1...8 {
            t += 0.1
            var f = still; f.pixels[(395 * 600 + 595) * 4] = UInt8(k)
            _ = p.process(Fixtures.frame(f, display: d, scale: 1, dirty: corner, t: t), snapshot: snap, now: t)
        }
        #expect(p.held.isEmpty, "\(p.held.map(\.rel))")
    }

    // MARK: Windows above the covers

    @Test func anotherAppsWindowAboveTheCoversCoversTheDisplay() {
        let p = pipeline()
        let img = flaggedAt(PixelRect(x: 100, y: 100, w: 100, h: 100))
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        // A window of another app at the canvas level, over the cover.
        let high = WindowInfo(number: 5, ownerPID: 700, layer: CoverLevel.canvas, bounds: CGRect(x: 120, y: 120, width: 200, height: 200))
        let plan = p.process(Fixtures.frame(touched(img, 1), display: d, scale: 1, dirty: corner, t: 0.1),
                             snapshot: WindowSnapshot(windows: [high, win], time: 0.1), now: 0.1)
        #expect(plan.wholeDisplay == .windowAboveCovers)
        // One that overlaps no cover, the app's own, or a fully transparent one changes nothing.
        for w in [WindowInfo(number: 5, ownerPID: 700, layer: CoverLevel.canvas + 5, bounds: CGRect(x: 400, y: 300, width: 100, height: 50)),
                  WindowInfo(number: 6, ownerPID: 42, layer: CoverLevel.appAbove, bounds: d.bounds),
                  WindowInfo(number: 7, ownerPID: 700, layer: CoverLevel.canvas, bounds: d.bounds, alpha: 0)] {
            let q = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [42], callWallMs: .infinity)
            let r = q.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: WindowSnapshot(windows: [w, win], time: 0), now: 0)
            #expect(r.wholeDisplay == nil && r.covers(CGRect(x: 100, y: 100, width: 100, height: 100)), "\(w)")
        }
    }

    // MARK: Time to cover under load

    @Test func theAppJudgesAFrameForAtMostAQuarterOfASecond() {
        let p = DisplayPipeline(display: d, judger: VerdictScript { VerdictScript.clean($0) }, budgetShare: 40, ignoredPIDs: [])
        #expect(p.callWallMs == 250)
        #expect(Register.JUDGE_CALL_WALL == 0.25)
    }

    /// A judge that takes `ms` per call and finds everything clean.
    final class SlowJudge: Judging {
        let ms: Double, spendAll: Bool
        var calls = 0, budgets: [Int] = []
        init(ms: Double, spendAll: Bool = false) { self.ms = ms; self.spendAll = spendAll }
        func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                       progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
            calls += 1; budgets.append(budget)
            usleep(useconds_t(ms * 1000))
            return FrameVerdict(regions: [RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)],
                                coverWindow: false, strike: false, hot: false, judgements: spendAll ? budget : min(budget, 20), overloaded: 0)
        }
        func setRule(_ rule: DetectorRule) {}
    }

    /// Six windows side by side, each 200 x 200 points.
    var six: WindowSnapshot {
        WindowSnapshot(windows: (0..<6).map { i in
            WindowInfo(number: UInt32(i + 1), ownerPID: 500, layer: 0, bounds: CGRect(x: (i % 3) * 200, y: (i / 3) * 200, width: 200, height: 200))
        }, time: 0)
    }

    @Test func oneFrameIsJudgedForAtMostTheTimeLimitAndTheRestIsBlurredMeanwhile() {
        let j = SlowJudge(ms: 30)
        let p = DisplayPipeline(display: d, judger: j, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: six, now: 0)
        p.callWallMs = 70
        j.calls = 0
        let all = PixelRect(x: 0, y: 0, w: 600, h: 400)
        let plan = p.process(Fixtures.frame(touched(img, 1), display: d, scale: 1, dirty: [all], t: 0.1), snapshot: six, now: 0.1)
        #expect(j.calls < 6, "stopped at the time limit")
        #expect(p.lastTimings.leftForLater > 0)
        // What was not reached is blurred in this plan, and judged next time.
        #expect(plan.covers(CGRect(x: 400, y: 200, width: 200, height: 200), kind: .blur(BlurTile(columns: 1, rows: 1, rgba: [0, 0, 0, 255]))))
        j.calls = 0
        _ = p.process(idle(0.2), snapshot: six, now: 0.2)
        #expect(j.calls > 0)
    }

    @Test func theFirstFrameIsJudgedWithinOneCallsWorthInAll() {
        let j = SlowJudge(ms: 0, spendAll: true)
        let p = DisplayPipeline(display: d, judger: j, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        p.callWallMs = .infinity
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: six, now: 0)
        #expect(j.budgets.count == 6)
        #expect(p.lastTimings.judgements <= Register.DETECTOR_CALL_CAP, "\(j.budgets)")
    }

    @Test func whenFramesRunLongEveryChangeIsBlurredBeforeJudging() {
        final class Watch: Judging {
            var early: [CoverPlan] = [], seen: [CoverPlan]?
            func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                           progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
                if seen == nil { seen = early }
                usleep(150_000)
                return VerdictScript.clean(area)
            }
            func setRule(_ rule: DetectorRule) {}
        }
        let j = Watch()
        let p = DisplayPipeline(display: d, judger: j, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        p.callWallMs = .infinity
        let img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)   // 150 ms: over the goal
        j.seen = nil
        let changed = PixelRect(x: 100, y: 100, w: 200, h: 120)
        _ = p.process(Fixtures.frame(touched(img, 1), display: d, scale: 1, dirty: [changed], t: 0.2), snapshot: snap, now: 0.2) { j.early.append($0) }
        #expect((j.seen ?? []).contains { $0.covers(CGRect(x: 100, y: 100, width: 200, height: 120)) }, "blurred before the first judge call")
    }

    @Test func aFrameLeftWaitingHasItsChangesCovered() {
        let q = FrameQueue()
        q.open()
        let img = Fixtures.blank(600, 400)
        _ = q.offer(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 100, y: 100, w: 50, h: 50)], t: 0), now: 0)
        #expect(q.waitingChanges(now: 0.3, after: Register.WAITING_FRAME_COVER).isEmpty)
        let w = q.waitingChanges(now: 0.6, after: Register.WAITING_FRAME_COVER)
        #expect(w.areas[1] == [CGRect(x: 96, y: 96, width: 56, height: 56)])
        let other = DisplayDescriptor(id: 2, bounds: CGRect(x: 600, y: 0, width: 600, height: 400))
        _ = q.offer(Fixtures.frame(img, display: other, scale: 1, dirty: nil, t: 0), now: 0)
        #expect(q.waitingChanges(now: 0.6, after: Register.WAITING_FRAME_COVER).whole == [2], "changed everywhere: covered whole")

        // The display rule draws them over the display's plan until the frame is judged.
        let c = DisplayCoverage()
        c.reset(DisplayList(displays: [d], main: 1))
        let g = c.newRequest()
        #expect(c.accept(.clear(d), generation: g))
        let shown = c.shown(unjudged: w.areas).first { $0.display.id == 1 }
        #expect(shown?.covers(CGRect(x: 100, y: 100, width: 50, height: 50)) == true)
    }

    // MARK: Trusting what capture reports

    @Test func aChangeOutsideTheReportedAreasIsFound() {
        let a = Fixtures.blank(600, 400)
        var b = a
        #expect(!DirtyRegions.changedOutside(old: a, new: b, reported: []))
        b.pixels[(50 * 600 + 50) * 4] = 1
        #expect(!DirtyRegions.changedOutside(old: a, new: b, reported: [PixelRect(x: 40, y: 40, w: 20, h: 20)]))
        #expect(DirtyRegions.changedOutside(old: a, new: b, reported: [PixelRect(x: 60, y: 40, w: 20, h: 20)]))
        #expect(DirtyRegions.changedOutside(old: a, new: b, reported: []))
    }

    @Test func aPictureOutsideTheReportedChangeIsStillJudged() {
        let p = pipeline()
        let img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        // A flagged picture appears, but the frame reports only a change in the corner.
        var lie = touched(img, 1)
        Fixtures.paintFlagged(&lie, PixelRect(x: 300, y: 150, w: 120, h: 120))
        let plan = p.process(Fixtures.frame(lie, display: d, scale: 1, dirty: corner, t: 1.1), snapshot: snap, now: 1.1)
        #expect(plan.covers(CGRect(x: 300, y: 150, width: 120, height: 120)))
        #expect(p.dirtyMismatches == 1)
    }

    @Test func noStreamStartsWithoutTheAppsOwnWindowsLeftOut() {
        #expect(CaptureExclusion.own([Int32(10), 11], pid: { $0 }, ownPID: 42) == nil)
        #expect(CaptureExclusion.own([Int32](), pid: { $0 }, ownPID: 42) == nil)
        #expect(CaptureExclusion.own([Int32(10), 42], pid: { $0 }, ownPID: 42) == [42])
    }

    @Test func aPlaceShowingTheCoversOwnColourNeverCountsAsClean() {
        // As if capture saw the covers: the covered place shows the light cover colour, and every judgement is clean.
        let p = DisplayPipeline(display: d, judger: VerdictScript { VerdictScript.clean($0) }, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        var img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let r = CGRect(x: 100, y: 100, width: 80, height: 80)
        p.held = [DisplayPipeline.Held(target: .window(number: 1, ownerPID: 500), rel: r, whole: false, kind: .plain, clean: 0)]
        for y in 100..<180 { for x in 100..<180 { let q = (y * 600 + x) * 4; img.pixels[q] = 0xE5; img.pixels[q + 1] = 0xE7; img.pixels[q + 2] = 0xE1 } }
        for k in 1...8 {
            _ = p.process(Fixtures.frame(touched(img, UInt8(k)), display: d, scale: 1, dirty: [PixelRect(x: 96, y: 96, w: 88, h: 88)], t: 0.1 * Double(k)),
                          snapshot: snap, now: 0.1 * Double(k))
        }
        #expect(p.held.count == 1 && p.held[0].clean == 0)
        #expect(OwnCoverColours.shown(in: img, PixelRect(x: 100, y: 100, w: 80, h: 80)))
        #expect(!OwnCoverColours.shown(in: img, PixelRect(x: 300, y: 100, w: 80, h: 80)))
    }
}

extension CapturedFrame {
    func with(windows w: WindowSnapshot) -> CapturedFrame { var f = self; f.windows = w; return f }
}