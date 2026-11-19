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

    func pipeline() -> DisplayPipeline { DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: []) }

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
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [])
        var img = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        flagNext = true
        img.pixels[(150 * 600 + 150) * 4] = 9
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [changed], t: 0.1), snapshot: snap, now: 0.1)
        #expect(plan.covers(CGRect(x: 100, y: 100, width: 200, height: 160)), "\(plan.items.map(\.rect))")
    }
}
