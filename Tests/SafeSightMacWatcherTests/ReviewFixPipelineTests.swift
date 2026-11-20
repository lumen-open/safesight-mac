// SPDX-License-Identifier: Apache-2.0
// What the independent review of the live-run fixes found, each as a test that fails without its fix: clean judgements
// that outlived a change under (or touching) a cover. Synthetic patterns and fake models only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import RegionFinder
@testable import SafeSightMacWatcher

@Suite struct ReviewFixPipelineTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let g = PixelRect(x: 100, y: 100, w: 80, h: 80)

    func verdict(_ regions: [RegionVerdict], overloaded: Int = 0) -> FrameVerdict {
        FrameVerdict(regions: regions, coverWindow: false, strike: false, hot: false, judgements: 2, overloaded: overloaded)
    }

    /// A held cover with three clean judgements; the content under it changes (reported changed). Its count starts
    /// again: four clean judgements of the new content are needed, the first possibly in the frame that brought it.
    @Test(arguments: [true, false])
    func aChangeUnderACoverStartsItsCountAgain(_ newContentLeftUnjudged: Bool) {
        var mode = "flag"
        let g = self.g
        let judge = VerdictScript { area in
            switch mode {
            case "flag":
                return self.verdict([RegionVerdict(rect: g, display: .cover, reason: .bothFamilies, pass: .region),
                                     RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)])
            case "overload":
                return self.verdict([RegionVerdict(rect: g, display: .contain, reason: .overload, pass: .region),
                                     RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)], overloaded: 1)
            default:
                return self.verdict([RegionVerdict(rect: g, display: .clear, reason: .judgedClean, pass: .region),
                                     RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)])
            }
        }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, g, channel: nil, seed: 4)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        mode = "clean"
        var t = 0.0
        func idle() { t += 0.25; _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t) }
        while (p.held.first?.clean ?? 0) < 3 && t < 10 { idle() }
        #expect(p.held.first?.clean == 3)
        mode = newContentLeftUnjudged ? "overload" : "clean"
        Fixtures.paint(&img, g, channel: nil, seed: 99)
        t += 0.25
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [g], t: t), snapshot: snap, now: t)
        #expect(!p.held.isEmpty, "not lifted by the frame that changed what it hides")
        mode = "clean"
        var n = 0
        while !p.held.isEmpty && n < 20 { idle(); n += 1 }
        // Four clean judgements of the new content: four more frames if the change was left unjudged, three if the
        // frame that brought it judged it clean.
        #expect(n == (newContentLeftUnjudged ? 4 : 3), "lifted after \(n) more frames")
    }

    /// A clean judgement of an entry made before a change that touched that entry (here a slice reaching outside the cover)
    /// no longer counts towards the cover's next clean judgement.
    @Test func anEntryTouchedByAChangeNoLongerCounts() {
        let slice = PixelRect(x: 100, y: 100, w: 300, h: 80)
        var mode = "flag"
        let g = self.g
        let judge = VerdictScript { area in
            // Calls over the picture (the frame that shows it, its own recheck); anything else is clean.
            guard area.x <= g.x, area.y <= g.y, area.maxX >= g.maxX, area.maxY >= g.maxY, area.w <= 120 else { return VerdictScript.clean(area) }
            switch mode {
            case "flag":
                return self.verdict([RegionVerdict(rect: g, display: .cover, reason: .bothFamilies, pass: .region)])
            case "sliceNow":
                return self.verdict([RegionVerdict(rect: g, display: .contain, reason: .overload, pass: .region),
                                     RegionVerdict(rect: slice, display: .clear, reason: .judgedClean, pass: .slice)], overloaded: 1)
            default:
                return self.verdict([RegionVerdict(rect: g, display: .clear, reason: .judgedClean, pass: .region),
                                     RegionVerdict(rect: slice, display: .clear, reason: .judgedEarlier, pass: .slice)])
            }
        }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, g, channel: nil, seed: 4)
        // The cover is made by a call over exactly its picture.
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [g], t: 0), snapshot: snap, now: 0)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [g], t: 0.25), snapshot: snap, now: 0.25)
        #expect(p.held.count == 1 && p.held.first?.clean == 0, "\(p.heldLines)")
        // Its own call judges the slice clean, and leaves the picture.
        mode = "sliceNow"
        _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0.5), snapshot: snap, now: 0.5)
        #expect(p.held.first?.round.count == 1, "\(p.heldLines)")
        // Something changes inside the slice, outside the cover; then the picture is judged clean.
        mode = "regionNow"
        var changed = img
        Fixtures.paint(&changed, PixelRect(x: 300, y: 110, w: 40, h: 40), channel: nil, seed: 7)
        _ = p.process(Fixtures.frame(changed, display: d, scale: 1, dirty: [PixelRect(x: 300, y: 110, w: 40, h: 40)], t: 0.75), snapshot: snap, now: 0.75)
        #expect(p.held.count == 1 && p.held.first?.clean == 0, "the slice's judgement from before the change does not complete a clean judgement")
    }

    /// The content under a cover changes but the capture reports no changed area there (the reported areas can miss a
    /// change). The pixels are compared anyway: the count starts again, and one clean judgement of the new content does
    /// not lift it.
    @Test func aChangeTheCaptureDidNotReportStillStartsTheCountAgain() {
        var mode = "flag"
        let g = self.g
        let judge = VerdictScript { area in
            mode == "flag"
                ? self.verdict([RegionVerdict(rect: g, display: .cover, reason: .bothFamilies, pass: .region),
                                RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)])
                : self.verdict([RegionVerdict(rect: g, display: .clear, reason: .judgedClean, pass: .region),
                                RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)])
        }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, g, channel: nil, seed: 4)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        mode = "clean"
        var t = 0.0
        while (p.held.first?.clean ?? 0) < 3 && t < 10 {
            t += 0.25
            _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t)
        }
        #expect(p.held.first?.clean == 3)
        Fixtures.paint(&img, g, channel: nil, seed: 77)   // new content; the frame reports nothing changed
        t += 0.1
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [], t: t), snapshot: snap, now: t)
        #expect(!p.held.isEmpty && p.held.allSatisfy { $0.clean < 2 }, "\(p.heldLines)")
        // A frame that reports a change where nothing changed keeps the count.
        let before = p.held.first?.clean
        t += 0.1
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [g], t: t), snapshot: snap, now: t)
        #expect(p.held.isEmpty || (p.held.first?.clean ?? 0) >= (before ?? 0), "a reported change with the same pixels starts nothing again")
    }
}
