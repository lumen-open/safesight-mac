// SPDX-License-Identifier: Apache-2.0
// The cover layer end to end on synthetic frames: real detector (fake marker models), real pipeline,
// real cover geometry. No screen is captured and no explicit material exists anywhere in these tests.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

@Suite struct CoverLayerTests {
    // A 2x display to the right of a 1440 x 900 primary display.
    let display = DisplayDescriptor(id: 2, bounds: CGRect(x: 1440, y: 0, width: 400, height: 300))
    var window: WindowSnapshot { Fixtures.oneWindow(CGRect(x: 1440, y: 0, width: 400, height: 300)) }

    func pipeline(_ rule: DetectorRule = .balanced) -> DisplayPipeline {
        DisplayPipeline(display: display, judger: Fixtures.detector(rule: rule), budgetShare: 40, ignoredPIDs: [1])
    }

    @Test func aFlaggedRegionProducesACoverWindowFrame() throws {
        var img = Fixtures.blank(800, 600)
        let picture = PixelRect(x: 200, y: 100, w: 160, h: 160)   // detail pixels on the 2x display
        Fixtures.paintFlagged(&img, picture)
        let p = pipeline()
        let plan = p.process(Fixtures.frame(img, display: display, scale: 2, t: 0), snapshot: window, now: 0)
        #expect(plan.wholeDisplay == nil)
        // The picture, in global points: (1440 + 100, 50), 80 x 80.
        let g = CGRect(x: 1540, y: 50, width: 80, height: 80)
        #expect(plan.covers(g, kind: .plain), "the flagged picture is covered whole")
        // The cover's window frame in Cocoa points (overlay form) and its layer frame on the canvas.
        let overlay = CoverLayout.overlayFrames(plan, primaryHeight: 900).map(\.0)
        #expect(overlay.contains { $0.contains(CGRect(x: 1540, y: 900 - 130, width: 80, height: 80)) })
        let layers = CoverLayout.layerFrames(plan).map(\.0)
        #expect(layers.contains { $0.contains(CGRect(x: 100, y: 300 - 130, width: 80, height: 80)) })
        #expect(CoverLayout.canvasFrame(display: display.bounds, primaryHeight: 900) == CGRect(x: 1440, y: 600, width: 400, height: 300))
        // The cover is the picture, not the whole display.
        let area = plan.items.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        #expect(area < 400 * 300 / 2)
    }

    @Test func aPictureAppearingInAChangedAreaDoesNotCoverTheWholeWindow() {
        let p = pipeline()
        let base = Fixtures.blank(800, 600)
        _ = p.process(Fixtures.frame(base, display: display, scale: 2, t: 0), snapshot: window, now: 0)
        var img = base
        let picture = PixelRect(x: 200, y: 100, w: 160, h: 160)
        Fixtures.paintFlagged(&img, picture)
        let plan = p.process(Fixtures.frame(img, display: display, scale: 2, dirty: [picture], t: 0.1), snapshot: window, now: 0.1)
        #expect(plan.covers(CGRect(x: 1540, y: 50, width: 80, height: 80), kind: .plain))
        #expect(!plan.covers(CGRect(x: 1440, y: 200, width: 400, height: 100)), "the rest of the window stays visible")
    }

    @Test func aWindowFilledByAFlaggedPictureIsCoveredWhole() {
        // The whole pass over the whole window flags: the window is covered whole.
        let d = DisplayDescriptor(id: 4, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        var img = Fixtures.blank(300, 200)
        Fixtures.paintFlagged(&img, PixelRect(x: 0, y: 0, w: 300, h: 200))
        let w = Fixtures.oneWindow(CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: w, now: 0).covers(d.bounds, kind: .plain))
    }

    @Test func aCleanScreenDrawsNothing() {
        var img = Fixtures.blank(800, 600)
        Fixtures.paint(&img, PixelRect(x: 200, y: 100, w: 160, h: 160), channel: nil, seed: 4)
        let plan = pipeline().process(Fixtures.frame(img, display: display, scale: 2, t: 0), snapshot: window, now: 0)
        #expect(plan.wholeDisplay == nil)
        #expect(plan.items.isEmpty)
    }

    @Test func aDisplayStartsCoveredUntilItsFirstJudgedFrame() {
        let p = pipeline()
        #expect(p.lastPlan.wholeDisplay == .notYetJudged)
        let started = p.process(CapturedFrame(display: display, status: .started, image: nil, map: nil, dirty: [], time: 0), snapshot: window, now: 0)
        #expect(started.wholeDisplay == .notYetJudged)
    }

    @Test func aCoverLiftsOnlyAfterFourCleanJudgementsInARow() {
        var hit = Fixtures.blank(800, 600)
        let picture = PixelRect(x: 200, y: 100, w: 160, h: 160)
        Fixtures.paintFlagged(&hit, picture)
        let p = pipeline()
        let g = CGRect(x: 1540, y: 50, width: 80, height: 80)
        #expect(p.process(Fixtures.frame(hit, display: display, scale: 2, t: 0), snapshot: window, now: 0).covers(g))
        // The picture is replaced by a harmless one. The changed area is judged clean each frame.
        var covered: [Bool] = []
        for i in 1...6 {
            var clean = Fixtures.blank(800, 600)
            Fixtures.paint(&clean, picture, channel: nil, seed: 50)
            clean.pixels[0] = UInt8(i)   // a new frame each time
            let plan = p.process(Fixtures.frame(clean, display: display, scale: 2, dirty: [picture], t: Double(i) * 0.05),
                                 snapshot: window, now: Double(i) * 0.05)
            covered.append(plan.covers(g))
        }
        #expect(covered == [true, true, true, false, false, false], "lifts on the 4th clean judgement (VIDEO_VOTE)")
    }

    @Test func aFlagAgainResetsTheCount() {
        var hit = Fixtures.blank(800, 600)
        let picture = PixelRect(x: 200, y: 100, w: 160, h: 160)
        Fixtures.paintFlagged(&hit, picture)
        var clean = Fixtures.blank(800, 600)
        Fixtures.paint(&clean, picture, channel: nil, seed: 50)
        let p = pipeline()
        let g = CGRect(x: 1540, y: 50, width: 80, height: 80)
        let seq = [hit, clean, clean, hit, clean, clean, clean]
        var last = CoverPlan.clear(display)
        for (i, img) in seq.enumerated() {
            var f = img; f.pixels[0] = UInt8(i)
            last = p.process(Fixtures.frame(f, display: display, scale: 2, dirty: i == 0 ? nil : [picture], t: Double(i)), snapshot: window, now: Double(i) * 0.05)
        }
        #expect(last.covers(g), "three clean judgements after the second flag are not enough")
    }

    @Test func aContainedPictureIsBlurredNotShownSharp() throws {
        // One family only, no tie-breaker, under Balanced: a dispute nobody could settle is contained.
        var img = Fixtures.blank(800, 600)
        let picture = PixelRect(x: 200, y: 100, w: 160, h: 160)
        Fixtures.paint(&img, picture, channel: 0, seed: 3)
        let plan = pipeline(.balanced).process(Fixtures.frame(img, display: display, scale: 2, t: 0), snapshot: window, now: 0)
        let g = CGRect(x: 1540, y: 50, width: 80, height: 80)
        #expect(plan.covers(g))
        let blurs = plan.items.compactMap { item -> BlurTile? in if case let .blur(t) = item.kind { return t }; return nil }
        #expect(!blurs.isEmpty)
        #expect(blurs.allSatisfy { max($0.columns, $0.rows) <= ContainBlur.maxCells })
        // Under Either, the same picture is covered.
        let either = pipeline(.either).process(Fixtures.frame(img, display: display, scale: 2, t: 0), snapshot: window, now: 0)
        #expect(either.covers(g, kind: .plain))
    }

    @Test func overloadNeverShowsANewPictureUnjudged() throws {
        let p = pipeline()
        let base = Fixtures.blank(800, 600)
        _ = p.process(Fixtures.frame(base, display: display, scale: 2, t: 0), snapshot: window, now: 0)
        p.bucket = TokenBucket(rate: 0, depth: 0)   // nothing left to spend
        var img = base
        let picture = PixelRect(x: 200, y: 100, w: 160, h: 160)
        Fixtures.paint(&img, picture, channel: nil, seed: 9)   // harmless, but unjudged
        let g = CGRect(x: 1540, y: 50, width: 80, height: 80)
        let first = p.process(Fixtures.frame(img, display: display, scale: 2, dirty: [picture], t: 0.1), snapshot: window, now: 0.1)
        #expect(first.covers(g), "an unjudged picture is blurred or covered, never shown sharp")
        // Still unjudged after TIME_TO_COVER: the whole window is covered.
        var later = img; later.pixels[0] = 1
        let second = p.process(Fixtures.frame(later, display: display, scale: 2, dirty: [picture], t: 0.7), snapshot: window, now: 0.7)
        #expect(second.covers(CGRect(x: 1440, y: 0, width: 400, height: 300), kind: .plain))
    }

    @Test func aCoverMovesWithItsWindowAndCoversTheOldPlaceOnce() {
        // A 1x display; the window holds a flagged picture and then moves 100 points right.
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        var img = Fixtures.blank(600, 400)
        Fixtures.paintFlagged(&img, PixelRect(x: 60, y: 60, w: 100, h: 100))
        let before = Fixtures.oneWindow(CGRect(x: 40, y: 40, width: 300, height: 300))
        #expect(p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: before, now: 0).covers(CGRect(x: 60, y: 60, width: 100, height: 100)))
        var moved = Fixtures.blank(600, 400)
        Fixtures.paintFlagged(&moved, PixelRect(x: 160, y: 60, w: 100, h: 100))
        let after = Fixtures.oneWindow(CGRect(x: 140, y: 40, width: 300, height: 300))
        let plan = p.process(Fixtures.frame(moved, display: d, scale: 1, dirty: [PixelRect(x: 40, y: 40, w: 400, h: 300)], t: 0.1),
                             snapshot: after, now: 0.1)
        #expect(plan.covers(CGRect(x: 160, y: 60, width: 100, height: 100)), "new place")
        #expect(plan.covers(CGRect(x: 60, y: 60, width: 80, height: 100)), "old place, for this update")
    }

    @Test func coversAreClippedToTheVisiblePartOfTheirWindow() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        var img = Fixtures.blank(600, 400)
        Fixtures.paintFlagged(&img, PixelRect(x: 60, y: 60, w: 120, h: 120))
        // A front window hides the right half of the picture's window, and the picture's right part.
        let snap = WindowSnapshot(windows: [
            WindowInfo(number: 2, ownerPID: 600, layer: 0, bounds: CGRect(x: 150, y: 0, width: 450, height: 400)),
            WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 400)),
        ], time: 0)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        #expect(plan.covers(CGRect(x: 60, y: 60, width: 90, height: 120)))
    }

    @Test func theAppsOwnWindowsAreNeverJudgingTargets() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let snap = WindowSnapshot(windows: [WindowInfo(number: 3, ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 300))], time: 0)
        let parts = snap.split(changed: [CGRect(x: 0, y: 0, width: 600, height: 400)], display: d, ignoring: [42])
        #expect(!parts.contains { $0.target == .window(number: 3, ownerPID: 42) })
    }
}

@Suite struct FaultToCoverTests {
    let display = DisplayDescriptor(id: 3, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))

    func judgedPipeline() -> DisplayPipeline {
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        _ = p.process(Fixtures.frame(Fixtures.blank(300, 200), display: display, scale: 1, t: 0), snapshot: .empty, now: 0)
        return p
    }

    @Test(arguments: [FrameStatus.blank, .suspended, .stopped])
    func anUnjudgeableFrameCoversTheWholeDisplay(_ status: FrameStatus) {
        let p = judgedPipeline()
        #expect(p.lastPlan.wholeDisplay == nil)
        let plan = p.process(CapturedFrame(display: display, status: status, image: nil, map: nil, dirty: [], time: 1), snapshot: .empty, now: 1)
        #expect(plan.wholeDisplay == .frameNotJudgeable)
        #expect(CoverLayout.layerFrames(plan).map(\.0) == [CGRect(x: 0, y: 0, width: 300, height: 200)])
    }

    @Test func missingMetadataCoversTheWholeDisplay() {
        let p = judgedPipeline()
        let plan = p.process(CapturedFrame(display: display, status: .complete, image: Fixtures.blank(300, 200), map: nil, dirty: nil, time: 1),
                             snapshot: .empty, now: 1)
        #expect(plan.wholeDisplay == .badFrameMetadata)
    }

    @Test func aMapThatDoesNotMatchThePixelsCoversTheWholeDisplay() {
        let p = judgedPipeline()
        let plan = p.process(Fixtures.frame(Fixtures.blank(300, 200), display: display, scale: 2, t: 1), snapshot: .empty, now: 1)
        // scale 2 on a 300-point display expects 600 pixels; the frame has 300: no trustworthy map.
        #expect(plan.wholeDisplay == .badFrameMetadata)
    }

    @Test func aStoppedStreamOrAFailedDetectorCoversTheWholeDisplay() {
        for cause in [FaultCause.streamStopped, .detectorUnavailable, .judgingBehind, .tooManyDisplays] {
            let p = judgedPipeline()
            #expect(p.cover(because: cause).wholeDisplay == cause)
            #expect(p.judged == false, "it stays covered until a frame is judged again")
        }
    }

    @Test func aJudgedFrameAfterAFaultLowersTheWholeDisplayCover() {
        let p = judgedPipeline()
        p.cover(because: .streamStopped)
        let plan = p.process(Fixtures.frame(Fixtures.blank(300, 200), display: display, scale: 1, t: 2), snapshot: .empty, now: 2)
        #expect(plan.wholeDisplay == nil)
    }

    @Test func faultsOnlyEverAddCovering() {
        // Every cause maps to a whole-display cover; none maps to anything else.
        for cause in FaultCause.allCases {
            let plan = CoverPlan.covered(display, because: cause)
            #expect(CoverLayout.layerFrames(plan).count == 1)
            #expect(!cause.plainWords.isEmpty)
        }
    }
}
