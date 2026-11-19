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
