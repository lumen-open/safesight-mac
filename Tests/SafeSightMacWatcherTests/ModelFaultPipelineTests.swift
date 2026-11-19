// SPDX-License-Identifier: Apache-2.0
// A model that fails at run time, through the real cover layer: a score that is not a number is a model
// failure, never "not flagged". The picture is blurred or covered, never shown sharp; a window still failing
// after TIME_TO_COVER is covered whole; the failures are counted; it lifts only once the model works again
// and the usual clean judgements are in. Synthetic patterns only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import RegionFinder
@testable import SafeSightMacWatcher

/// Gives a score that is not a number for every tensor while `broken`, otherwise 0.
final class BreakableModel: ScoringModel {
    let id: String, family: Family, side = 32
    var broken = true
    init(id: String, family: Family) { self.id = id; self.family = family }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] { tensors.map { _ in broken ? .nan : 0 } }
}

@Suite struct ModelFaultPipelineTests {
    let display = DisplayDescriptor(id: 3, bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
    var window: WindowSnapshot { Fixtures.oneWindow(display.bounds) }

    @Test func aModelGivingScoresThatAreNotNumbersNeverShowsAPictureSharp() {
        let a = BreakableModel(id: "fa", family: .a), b = MarkerModel(id: "fb", family: .b, channel: 2)
        let c = Cutoffs(cover: 0.3, clean: 0.05, strike: 0.8, gridMember: 0.3, gridLow: 0.3)
        let bands = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })
        let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "faults"), table: ThresholdTable(schema: "test", models: ["fa": bands, "fb": bands]),
                         config: DetectorConfig(), finder: RegionFinder())
        let p = DisplayPipeline(display: display, judger: d, budgetShare: 1e9, ignoredPIDs: [], callWallMs: .infinity)
        var img = Fixtures.blank(400, 300)
        Fixtures.paint(&img, PixelRect(x: 100, y: 120, w: 120, h: 120), channel: nil, seed: 4)   // harmless
        let picture = CGRect(x: 100, y: 120, width: 120, height: 120)
        let first = p.process(Fixtures.frame(img, display: display, scale: 1, t: 0), snapshot: window, now: 0)
        #expect(first.covers(picture), "a picture a model failed on is blurred or covered, never shown sharp")
        #expect(p.lastTimings.modelFaults > 0)
        #expect(p.lastTimings.overloaded > 0)
        #expect(d.modelFaults["fa", default: 0] > 0)
        // Still failing, frame after frame: the picture stays covered, and so does the window.
        var t = 0.0
        var plan = first
        while t < Register.TIME_TO_COVER + 0.05 {
            t += 0.1
            plan = p.process(CapturedFrame(display: display, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: window, now: t)
            #expect(plan.covers(picture), "at \(t) s")
        }
        #expect(plan.covers(CGRect(x: 0, y: 100, width: 400, height: 200), kind: .plain), "the window is covered")
        // The model works again: nothing lifts before VIDEO_VOTE clean judgements, then everything does.
        a.broken = false
        var shown: [Bool] = []
        for _ in 0..<(Register.VIDEO_VOTE + 2) {
            t += 0.1
            plan = p.process(CapturedFrame(display: display, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: window, now: t)
            shown.append(plan.items.isEmpty)
            #expect(p.lastTimings.modelFaults == 0)
        }
        #expect(shown.prefix(Register.VIDEO_VOTE - 1).allSatisfy { !$0 }, "\(shown)")
        #expect(shown.last == true, "\(shown)")
    }
}
