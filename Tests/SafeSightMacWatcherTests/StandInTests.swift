// SPDX-License-Identifier: Apache-2.0
// Lab builds only (SAFESIGHTMAC_LAB=1): the lab stand-in, a synthetic magenta-and-green checker, drives the
// real detector and the real cover layer with no model file. It can only force a cover.
#if SAFESIGHTMAC_LAB
import CoreGraphics
import Foundation
import LabStandIn
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

@Suite struct StandInTests {
    let display = DisplayDescriptor(id: 9, bounds: CGRect(x: -800, y: -500, width: 400, height: 250))

    func pipeline() throws -> DisplayPipeline {
        let d = try Detector(models: .labNull(), thresholdsJSON: WatcherModels.committedThresholds)
        d.standIn = CheckerStandIn()
        return DisplayPipeline(display: display, judger: d, budgetShare: 40, ignoredPIDs: [], callWallMs: .infinity)
    }

    @Test func theStandInIsCoveredAndPlacedOnScreen() throws {
        var img = Fixtures.blank(800, 500)
        let spot = PixelRect(x: 100, y: 120, w: 128, h: 128)
        CheckerStandIn.paint(&img, spot)
        let plan = try pipeline().process(Fixtures.frame(img, display: display, scale: 2, t: 0), snapshot: .empty, now: 0)
        // 2x display at (-800, -500): the spot is at (-750, -440), 64 x 64 points.
        #expect(plan.covers(CGRect(x: -750, y: -440, width: 64, height: 64), kind: .plain))
        let overlay = CoverLayout.overlayFrames(plan, primaryHeight: 900).map(\.0)
        #expect(overlay.contains { $0.contains(CGRect(x: -750, y: 900 + 440 - 64, width: 64, height: 64)) })
    }

    @Test func nullModelsAloneCoverNothing() throws {
        var img = Fixtures.blank(800, 500)
        Fixtures.paint(&img, PixelRect(x: 100, y: 120, w: 128, h: 128), channel: nil, seed: 2)
        let plan = try pipeline().process(Fixtures.frame(img, display: display, scale: 2, t: 0), snapshot: .empty, now: 0)
        #expect(plan.items.isEmpty && plan.wholeDisplay == nil)
    }
}
#endif
