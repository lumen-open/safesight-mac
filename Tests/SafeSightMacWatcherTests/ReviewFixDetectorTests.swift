// SPDX-License-Identifier: Apache-2.0
// What the independent review of the live-run fixes found, each as a test that fails without its fix: a model failure
// shown clear on an old judgement, and a small picture shown on an old judgement in the call where its window turns hot.
// Synthetic patterns and fake models only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import RegionFinder
@testable import SafeSightMacWatcher

/// A model with a fixed score, or not-a-number while broken.
final class FixedScoreModel: ScoringModel {
    let id: String, family: Family, side = 32
    var score: Float
    var broken = false
    init(id: String, family: Family, score: Float) { self.id = id; self.family = family; self.score = score }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] { tensors.map { _ in broken ? .nan : score } }
}

@Suite struct ReviewFixDetectorTests {
    let r = PixelRect(x: 60, y: 60, w: 96, h: 96)

    func detector(_ a: FixedScoreModel, _ b: FixedScoreModel) -> Detector {
        let c = Cutoffs(cover: 0.5, clean: 0.4, strike: 0.95, gridMember: 0.5, gridLow: 0.5)
        var m: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb"] { m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }) }
        return Detector(models: ModelSet(models: [a, b], bundleVersion: "review"), table: ThresholdTable(schema: "t", models: m),
                        config: DetectorConfig(), finder: RegionFinder())
    }

    /// A borderline-clean picture judged once; then a model breaks. Budget for everything: the failure is unjudged
    /// (blurred, counted), never shown clear on the old judgement, and the old judgement is forgotten.
    @Test(arguments: [false, true])
    func aModelFailureIsNeverShownAsJudgedEarlier(_ withProgress: Bool) {
        let a = FixedScoreModel(id: "fa", family: .a, score: 0.3), b = FixedScoreModel(id: "fb", family: .b, score: 0.3)
        let d = detector(a, b)
        var img = Fixtures.blank(400, 300)
        Fixtures.paint(&img, r, channel: nil, seed: 5)
        let ctx = JudgeContext(windowID: 1, startsCovered: false)
        let first = d.judge(img, context: ctx).regions.first { $0.pass == .region && $0.rect == r }
        #expect(first?.display == .clear)
        a.broken = true
        // With a progress listener the fastest model runs first and may be the one that fails.
        let v = withProgress ? d.judge(img, context: ctx) { _ in } : d.judge(img, context: ctx)
        let e = v.regions.first { $0.pass == .region && $0.rect == r }
        #expect(e?.display != .clear, "a model fault covers more, never less: \(String(describing: e))")
        #expect(e?.reason == .overload)
        #expect(v.overloaded > 0, "a fault is counted as unjudged, so `TIME_TO_COVER` can cover the window")
        a.broken = false; b.broken = true
        let again = d.judge(img, context: ctx, budget: 0)
        #expect(!again.regions.contains { [.judgedEarlier, .rejudgeDue].contains($0.reason) && $0.rect == r },
                "what was seen of it before was forgotten at the failure")
    }

    /// The window turns hot in this call; a small borderline picture judged clear earlier, not reached by the budget, is
    /// not shown on that old judgement: under the hot rule it is blurred until judged.
    @Test func aSmallPictureIsNotShownOnAnOldJudgementWhenItsWindowTurnsHot() {
        let small = PixelRect(x: 20, y: 20, w: 44, h: 44)
        func page() -> RGBAImage {
            var i = Fixtures.blank(600, 400)
            Fixtures.paint(&i, small, channel: nil, seed: 3)
            Fixtures.paint(&i, PixelRect(x: small.x, y: small.y, w: small.w, h: small.h / 5), channel: 0, seed: 903)
            return i
        }
        var hot = page()
        Fixtures.paintFlagged(&hot, PixelRect(x: 300, y: 200, w: 120, h: 120))
        let ctx = JudgeContext(windowID: 7, startsCovered: false)
        var cases = 0
        // The picture that turns the window hot is new, so it is judged first; a budget just big enough for it leaves the
        // small picture (judged before) unreached.
        for budget in 0...16 where cases < 2 {
            let d = Fixtures.detector()
            _ = d.judge(page(), context: ctx)
            let v = d.judge(hot, context: ctx, budget: budget)
            guard v.hot, let s = v.regions.first(where: { $0.pass == .region && $0.rect == small }), s.reason != .judgedClean else { continue }
            cases += 1
            #expect(s.display != .clear, "budget \(budget): \(s.reason)")
            #expect(![.judgedEarlier, .rejudgeDue].contains(s.reason))
        }
        #expect(cases > 0, "some budget turns the window hot without reaching the small picture")
    }
}

