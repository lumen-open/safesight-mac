// SPDX-License-Identifier: Apache-2.0
// Judging in a faster order (SafeSight Mac): what is still to judge is told early, the fastest model runs
// first and its flags are told at once, and pictures nearest the pointer come first. None of it changes what
// is judged or what the full rule decides. Synthetic marker patterns and fake models only.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

final class FastFirstTests: XCTestCase {
    /// Pair models (red, blue) and a tie-breaker that only ever agrees with green.
    func refereed(rule: DetectorRule = .balanced) -> (Detector, FakeModel, FakeModel, FakeModel) {
        let a = FakeModel(id: "fa", family: .a, channel: 0), b = FakeModel(id: "fb", family: .b, channel: 2)
        let g = FakeModel(id: "fg", family: .b, channel: 1)
        let c = Cutoffs(cover: 0.3, clean: 0.05, strike: 0.8, gridMember: 0.3, gridLow: 0.3)
        var m: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb", "fg"] { m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }) }
        var cfg = DetectorConfig(); cfg.rule = rule
        let d = Detector(models: ModelSet(models: [a, b], referee: g, bundleVersion: "ff"), table: ThresholdTable(schema: "t", models: m),
                         config: cfg, finder: RegionFinder())
        return (d, a, b, g)
    }

    func page() -> (RGBAImage, red: PixelRect, both: PixelRect, clean: PixelRect) {
        var img = canvas(700, 400)
        let red = PixelRect(x: 30, y: 30, w: 100, h: 100), both = PixelRect(x: 250, y: 30, w: 120, h: 120), clean = PixelRect(x: 480, y: 200, w: 140, h: 120)
        paint(&img, red, channel: 0, seed: 1)
        paint(&img, PixelRect(x: both.x, y: both.y, w: 60, h: 120), channel: 0, seed: 2)
        paint(&img, PixelRect(x: both.x + 60, y: both.y, w: 60, h: 120), channel: 2, seed: 3)
        paint(&img, clean, channel: nil, seed: 4)
        return (img, red, both, clean)
    }

    func classes(_ v: FrameVerdict) -> [String] {
        v.regions.map { "\($0.pass.rawValue) \($0.rect.x),\($0.rect.y),\($0.rect.w)x\($0.rect.h) \($0.display.rawValue) \($0.reason.rawValue)" }.sorted()
    }

    func testTheSameVerdictsAndJudgementsWithOrWithoutTheFastPass() {
        let (img, _, _, _) = page()
        let (plain, _, _, _) = refereed(), (fastFirst, _, _, _) = refereed()
        let v1 = plain.judge(img, context: JudgeContext(windowID: 1, startsCovered: false), budget: 400)
        var events = 0
        let v2 = fastFirst.judge(img, context: JudgeContext(windowID: 1, startsCovered: false), budget: 400) { _ in events += 1 }
        XCTAssertGreaterThan(events, 0)
        XCTAssertEqual(classes(v1), classes(v2))
        XCTAssertEqual(v1.judgements, v2.judgements)
        XCTAssertEqual(plain.timings.tiles, fastFirst.timings.tiles, "no model judges any picture twice")
        // And under a tight budget, the same entries are left for later.
        let (p3, _, _, _) = refereed(), (p4, _, _, _) = refereed()
        let v3 = p3.judge(img, context: JudgeContext(windowID: 2, startsCovered: false), budget: 5)
        let v4 = p4.judge(img, context: JudgeContext(windowID: 2, startsCovered: false), budget: 5) { _ in }
        XCTAssertEqual(classes(v3), classes(v4))
    }

    func testWhatIsLeftIsToldAfterTheFinderAndOnlyTheUncachedOnceCached() {
        let (img, red, both, clean) = page()
        let (d, _, _, _) = refereed()
        var pending: [PixelRect] = [], estimate = 0.0
        _ = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)) { e in
            if case let .found(p, _, ms) = e { pending = p; estimate = ms }
        }
        for r in [red, both, clean] { XCTAssertTrue(pending.contains { $0.intersects(r) }) }
        XCTAssertGreaterThan(estimate, 0)
        for _ in 1..<VerdictCache.CLEAN_CHECKS { _ = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)) }   // the other clean checks
        var again: [PixelRect]? = nil, cachedCovers: [PixelRect] = []
        _ = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)) { e in
            if case let .found(p, c, _) = e { again = p; cachedCovers = c }
        }
        // After every clean check everything comes from the cache except the red picture: a dispute the
        // tie-breaker declined is not clearly clean, so it is judged again (the margin rule).
        XCTAssertEqual(again?.isEmpty, false)
        XCTAssertTrue(again?.allSatisfy { $0.intersects(red) } ?? false, "only the declined dispute is left: \(again ?? [])")
        XCTAssertTrue(cachedCovers.contains { $0.intersects(both) }, "cached covers are told at once")
    }

    func testAFastFlagIsToldButNeverDecides() {
        // Red alone: the fast model (family A, the first of equals) flags it; family B does not; the tie-breaker
        // declines. The provisional blur is told, and the full rule's verdict is clear.
        var img = canvas(400, 300)
        let red = PixelRect(x: 40, y: 40, w: 100, h: 100)
        paint(&img, red, channel: 0, seed: 1)
        let (d, _, _, g) = refereed()
        var flags: [RegionVerdict] = []
        let v = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)) { e in
            if case let .fastFlag(r) = e { flags.append(r) }
        }
        XCTAssertTrue(flags.contains { $0.rect.intersects(red) && $0.display == .contain && $0.reason == .provisional })
        XCTAssertGreaterThan(g.calls, 0, "the tie-breaker was still asked")
        XCTAssertFalse(v.regions.contains { $0.rect.intersects(red) && $0.display != .clear })
        XCTAssertFalse(v.regions.contains { $0.reason == .provisional }, "no verdict is provisional")
        // Under Either the same flag covers, and is told as a cover.
        let (e, _, _, _) = refereed(rule: .either)
        var eitherFlags: [RegionVerdict] = []
        let w = e.judge(img, context: JudgeContext(windowID: 2, startsCovered: false)) { ev in
            if case let .fastFlag(r) = ev { eitherFlags.append(r) }
        }
        XCTAssertTrue(eitherFlags.contains { $0.rect.intersects(red) && $0.display == .cover })
        XCTAssertTrue(w.regions.contains { $0.rect.intersects(red) && $0.display == .cover })
    }

    func testPicturesNearestTheFocusComeFirst() {
        // A budget for one picture only: without a focus the smallest is judged; with the focus on the
        // largest, that one is. The other is left unjudged (overload), never shown as clear.
        var img = canvas(700, 400)
        let small = PixelRect(x: 30, y: 30, w: 70, h: 70), large = PixelRect(x: 450, y: 150, w: 150, h: 150)
        paint(&img, small, channel: nil, seed: 5); paint(&img, large, channel: nil, seed: 6)
        func judgedRegion(_ focus: PixelRect?) -> FrameVerdict {
            let (d, _, _) = detector()
            return d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false, focus: focus), budget: 2)
        }
        func state(_ v: FrameVerdict, _ r: PixelRect) -> Reason? { v.regions.first { $0.pass == .region && $0.rect.intersects(r) }?.reason }
        let byDefault = judgedRegion(nil)
        XCTAssertEqual(state(byDefault, small), .judgedClean)
        XCTAssertEqual(state(byDefault, large), .overload)
        let focused = judgedRegion(PixelRect(x: 500, y: 200, w: 2, h: 2))
        XCTAssertEqual(state(focused, large), .judgedClean)
        XCTAssertEqual(state(focused, small), .overload)
        XCTAssertFalse(focused.regions.contains { $0.reason == .overload && $0.display == .clear })
    }
}
