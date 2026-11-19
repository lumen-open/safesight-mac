// SPDX-License-Identifier: Apache-2.0
// The way out: a whole-window cover leaves the window's control band (title bar, tab strip, toolbar) in
// sight, while any picture in the band is still judged and covered. Synthetic frames and fake marker
// models only; no screen is captured.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

/// A judge that returns a set verdict, so the cover layer's drawing can be checked on its own.
final class ScriptedJudge: Judging {
    var verdict: (PixelRect) -> FrameVerdict
    init(_ v: @escaping (PixelRect) -> FrameVerdict) { verdict = v }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict { verdict(area) }
    func setRule(_ rule: DetectorRule) {}
}

extension CoverPlan {
    /// True when any cover or blur reaches into `g` (its interior, one point in from each edge).
    func touches(_ g: CGRect) -> Bool {
        let inner = g.insetBy(dx: 1, dy: 1)
        return wholeDisplay != nil ? display.bounds.intersects(inner) : items.contains { $0.rect.intersects(inner) }
    }
}

@Suite struct ControlBandTests {
    // A 2x display, 600 x 400 points; a browser-sized window that does not fill it.
    let display = DisplayDescriptor(id: 7, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let windowBounds = CGRect(x: 50, y: 30, width: 500, height: 340)
    var band: CGRect { CGRect(x: 50, y: 30, width: 500, height: WayOut.controlBand) }
    var snapshot: WindowSnapshot { Fixtures.oneWindow(windowBounds) }

    @Test func theBandIsANamedWorkingValue() {
        #expect(WayOut.controlBand == 92)
        #expect(WayOut.bandHeight(windowHeight: 900) == 92)
        #expect(WayOut.bandHeight(windowHeight: 150) == 50, "never more than a third of a short window")
        #expect(WayOut.bandHeight(windowHeight: 60) == 28, "a short window keeps its title bar")
        #expect(WayOut.bandHeight(windowHeight: 40) == 20, "and never more than half of it")
        #expect(WayOut.bandHeight(windowHeight: 0) == 0)
    }

    @Test func onlyOrdinaryWindowsThatDoNotFillTheirDisplayHaveABand() {
        let d = display.bounds
        #expect(WayOut.controlBand(of: WindowInfo(number: 1, ownerPID: 9, layer: 0, bounds: windowBounds), display: d) == band)
        #expect(WayOut.controlBand(of: WindowInfo(number: 1, ownerPID: 9, layer: 0, bounds: d), display: d) == nil, "full screen: no band")
        for layer in [-2147483624, 3, 20, 24, 101] {
            #expect(WayOut.controlBand(of: WindowInfo(number: 1, ownerPID: 9, layer: layer, bounds: windowBounds), display: d) == nil,
                    "layer \(layer): the desktop picture, floating windows, the Dock, the menu bar and menus have no band")
        }
    }

    @Test func aWholeWindowCoverNeverCoversTheControlBand() {
        // The whole pass flags; nothing else. The window is covered whole, apart from its control band.
        let p = DisplayPipeline(display: display, judger: ScriptedJudge { area in
            FrameVerdict(regions: [RegionVerdict(rect: area, display: .cover, reason: .bothFamilies, pass: .whole)],
                         coverWindow: true, strike: false, hot: false, judgements: 1, overloaded: 0)
        }, budgetShare: 40, ignoredPIDs: [])
        let plan = p.process(Fixtures.frame(Fixtures.blank(1200, 800), display: display, scale: 2, t: 0), snapshot: snapshot, now: 0)
        #expect(!plan.touches(band), "the title bar, tab strip and toolbar stay in sight")
        let below = CGRect(x: windowBounds.minX, y: band.maxY, width: windowBounds.width, height: windowBounds.maxY - band.maxY)
        #expect(plan.covers(below, kind: .plain), "everything below the band is covered")
    }

    @Test func aFlaggedPictureInsideTheBandIsStillCovered() {
        // The real detector (fake marker models) on a real frame: a big flagged picture fills the page, so the
        // whole pass flags and the window is covered whole; a small flagged picture sits in the tab strip.
        var img = Fixtures.blank(1200, 800)
        let page = PixelRect(x: 100, y: 2 * Int(band.maxY) + 8, w: 1000, h: 2 * 370 - 2 * Int(band.maxY) - 16)
        Fixtures.paintFlagged(&img, page)
        let inBand = PixelRect(x: 700, y: 2 * 30 + 24, w: 128, h: 128)   // 64 x 64 points at (350, 42)
        Fixtures.paintFlagged(&img, inBand, seed: 9)
        let p = DisplayPipeline(display: display, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        let plan = p.process(Fixtures.frame(img, display: display, scale: 2, t: 0), snapshot: snapshot, now: 0)
        #expect(plan.covers(CGRect(x: 350, y: 42, width: 64, height: 64), kind: .plain), "the picture in the band is covered")
        #expect(plan.covers(CGRect(x: 50, y: band.maxY, width: 500, height: 370 - band.maxY), kind: .plain), "the page is covered whole")
        #expect(!plan.touches(CGRect(x: 60, y: 32, width: 200, height: 88)), "the rest of the band stays in sight")
    }

    @Test func aFlaggedSliceInsideTheBandStaysCoveredWhenTheWindowIsCoveredWhole() {
        // A slice flagged where no picture region was found covers the whole window; that cover leaves the band,
        // so the slice itself is covered as well.
        let slice = PixelRect(x: 100, y: 60, w: 512, h: 512)   // reaches into the band (points 30 to 122)
        let p = DisplayPipeline(display: display, judger: ScriptedJudge { _ in
            FrameVerdict(regions: [RegionVerdict(rect: slice, display: .cover, reason: .bothFamilies, pass: .slice)],
                         coverWindow: false, strike: false, hot: false, judgements: 1, overloaded: 0)
        }, budgetShare: 40, ignoredPIDs: [])
        let plan = p.process(Fixtures.frame(Fixtures.blank(1200, 800), display: display, scale: 2, t: 0), snapshot: snapshot, now: 0)
        #expect(plan.covers(CGRect(x: 50, y: 30, width: 256, height: 256), kind: .plain), "the slice, band part included")
        #expect(plan.covers(CGRect(x: 50, y: band.maxY, width: 500, height: 370 - band.maxY), kind: .plain), "the window below the band")
        #expect(!plan.touches(CGRect(x: 310, y: 30, width: 240, height: WayOut.controlBand)), "the band beside the slice stays in sight")
    }

    @Test func aFullScreenWindowIsCoveredWholeWithNoBand() {
        let p = DisplayPipeline(display: display, judger: ScriptedJudge { area in
            FrameVerdict(regions: [], coverWindow: true, strike: false, hot: false, judgements: 1, overloaded: 0)
        }, budgetShare: 40, ignoredPIDs: [])
        let plan = p.process(Fixtures.frame(Fixtures.blank(1200, 800), display: display, scale: 2, t: 0),
                             snapshot: Fixtures.oneWindow(display.bounds), now: 0)
        #expect(plan.covers(display.bounds, kind: .plain))
    }

    @Test func theLargestPieceOfAWholeWindowCoverCarriesTheWayOutLine() {
        // A front window hides the covered window's right part: the whole cover comes in pieces, and only the
        // largest carries the line. A picture cover never does.
        let flagWhole = ScriptedJudge { area in
            FrameVerdict(regions: [RegionVerdict(rect: PixelRect(x: 200, y: 400, w: 100, h: 100), display: .cover, reason: .bothFamilies, pass: .region)],
                         coverWindow: true, strike: false, hot: false, judgements: 1, overloaded: 0)
        }
        let snap = WindowSnapshot(windows: [
            WindowInfo(number: 2, ownerPID: 600, layer: 3, bounds: CGRect(x: 400, y: 200, width: 200, height: 100)),
            WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: windowBounds),
        ], time: 0)
        let p = DisplayPipeline(display: display, judger: flagWhole, budgetShare: 40, ignoredPIDs: [])
        let plan = p.process(Fixtures.frame(Fixtures.blank(1200, 800), display: display, scale: 2, t: 0), snapshot: snap, now: 0)
        let marked = plan.items.filter(\.wayOut)
        #expect(marked.count == 1, "one line for the window; the floating window (layer 3) and the desktop carry none")
        let windowPieces = plan.items.filter { windowBounds.contains($0.rect) && $0.rect.height > 100 }
        #expect(marked.first.map { m in windowPieces.allSatisfy { $0.rect.width * $0.rect.height <= m.rect.width * m.rect.height } } == true)
        #expect(!plan.items.contains { $0.wayOut && $0.rect.width <= 50 }, "the picture cover is wordless")
    }

    @Test func aFullScreenWindowCoveredWholeStillCarriesTheLine() {
        let p = DisplayPipeline(display: display, judger: ScriptedJudge { _ in
            FrameVerdict(regions: [], coverWindow: true, strike: false, hot: false, judgements: 1, overloaded: 0)
        }, budgetShare: 40, ignoredPIDs: [])
        let plan = p.process(Fixtures.frame(Fixtures.blank(1200, 800), display: display, scale: 2, t: 0),
                             snapshot: Fixtures.oneWindow(display.bounds), now: 0)
        #expect(plan.items.filter(\.wayOut).count == 1)
        #expect(CoverLayout.layerPieces(plan).filter { $0.wayOut == .centre }.count == 1)
    }

    @Test func aWholeDisplayCoverPlacesTheLineBelowTheCard() {
        let pieces = CoverLayout.layerPieces(.covered(display, because: .notYetJudged))
        #expect(pieces.count == 1 && pieces[0].wayOut == .belowCard)
    }

    @Test func aWindowCoveredWholeForSlownessKeepsItsBandAndItsUnjudgedPicturesCovered() {
        // Unjudged for longer than TIME_TO_COVER: the window is covered whole, apart from its band; the band's
        // unjudged entries stay covered or blurred on their own.
        var calls = 0
        let picture = PixelRect(x: 700, y: 84, w: 128, h: 128)
        let p = DisplayPipeline(display: display, judger: ScriptedJudge { _ in
            calls += 1
            return FrameVerdict(regions: calls == 1 ? [] : [RegionVerdict(rect: picture, display: .contain, reason: .overload, pass: .region)],
                                coverWindow: false, strike: false, hot: false, judgements: 0, overloaded: calls == 1 ? 0 : 1)
        }, budgetShare: 40, ignoredPIDs: [])
        _ = p.process(Fixtures.frame(Fixtures.blank(1200, 800), display: display, scale: 2, t: 0), snapshot: snapshot, now: 0)
        _ = p.process(Fixtures.frame(Fixtures.blank(1200, 800), display: display, scale: 2, dirty: [picture], t: 0.1), snapshot: snapshot, now: 0.1)
        let plan = p.process(Fixtures.frame(Fixtures.blank(1200, 800), display: display, scale: 2, dirty: [picture], t: 0.7), snapshot: snapshot, now: 0.7)
        #expect(plan.covers(CGRect(x: 50, y: band.maxY, width: 500, height: 370 - band.maxY), kind: .plain), "covered whole below the band")
        #expect(plan.covers(CGRect(x: 350, y: 42, width: 64, height: 64)), "the unjudged picture in the band is blurred")
        #expect(!plan.touches(CGRect(x: 60, y: 32, width: 200, height: 88)))
    }
}
