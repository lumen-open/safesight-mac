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

@Suite struct VerdictCacheInThePipelineTests {
    let display = DisplayDescriptor(id: 5, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    var window: WindowSnapshot { Fixtures.oneWindow(display.bounds) }

    @Test func aReloadedPageIsNotJudgedAgainAndStaysCovered() {
        let d = Fixtures.detector()
        let p = DisplayPipeline(display: display, judger: d, budgetShare: 1e9, ignoredPIDs: [])
        var page = Fixtures.blank(600, 400)
        Fixtures.paint(&page, PixelRect(x: 40, y: 40, w: 120, h: 90), channel: nil, seed: 3)
        Fixtures.paint(&page, PixelRect(x: 300, y: 200, w: 100, h: 100), channel: nil, seed: 4)
        let flagged = PixelRect(x: 420, y: 40, w: 120, h: 120)
        Fixtures.paintFlagged(&page, flagged)
        let whole = [PixelRect(x: 0, y: 0, w: 600, h: 400)]
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        #expect(p.lastTimings.judgements > 0)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: display, scale: 1, dirty: whole, t: 1), snapshot: window, now: 1)
        d.resetTimings()
        let again = p.process(Fixtures.frame(page, display: display, scale: 1, dirty: whole, t: 2), snapshot: window, now: 2)
        #expect(p.lastTimings.judgements == 0, "every verdict and the finder's proposals come from the exact-match caches")
        #expect(d.timings.finderCacheHits == 1)
        #expect(again.covers(CGRect(x: 420, y: 40, width: 120, height: 120), kind: .plain), "a cached flag covers as before")
    }
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
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 1e9, ignoredPIDs: [])
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
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 1e9, ignoredPIDs: [])
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
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 1e9, ignoredPIDs: [])
        _ = p.process(Fixtures.frame(page, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        var changed = page
        Fixtures.paint(&changed, PixelRect(x: 20, y: 20, w: 50, h: 50), channel: nil, seed: 8)
        var early: [CoverPlan] = []
        let plan = p.process(Fixtures.frame(changed, display: display, scale: 1, dirty: [PixelRect(x: 16, y: 16, w: 64, h: 64)], t: 0.1), snapshot: window, now: 0.1) { early.append($0) }
        #expect(early.isEmpty)
        #expect(plan.covers(CGRect(x: 380, y: 200, width: 120, height: 120)))
    }
}
