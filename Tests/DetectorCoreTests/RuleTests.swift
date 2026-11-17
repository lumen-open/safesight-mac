// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

/// Fake model: score = share of "marker" pixels (red for family A, blue for family B) in the tensor.
final class FakeModel: ScoringModel {
    let id: String, family: Family, side = 32
    let channel: Int
    var calls = 0
    init(id: String, family: Family, channel: Int) { self.id = id; self.family = family; self.channel = channel }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] {
        calls += tensors.count
        let n = side * side
        return tensors.map { t in
            var hit = 0
            for i in 0..<n {
                let c = [Int(t[i]), Int(t[n + i]), Int(t[2 * n + i])]
                let others = (0..<3).filter { $0 != channel }.map { c[$0] }
                if c[channel] > 170 && others.allSatisfy({ $0 < 90 }) { hit += 1 }
            }
            return Float(hit) / Float(n)
        }
    }
}

func canvas(_ w: Int, _ h: Int) -> RGBAImage {
    RGBAImage(width: w, height: h, pixels: [UInt8](repeating: 0, count: w * h * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : 240 })
}

/// Paints a textured (photo-like) patch whose dominant colour is the given channel, or neutral if nil.
func paint(_ img: inout RGBAImage, _ r: PixelRect, channel: Int?, seed: UInt32) {
    var g = XorShift32(seed: seed)
    for y in r.y..<r.maxY { for x in r.x..<r.maxX {
        let p = (y * img.width + x) * 4
        for c in 0..<3 {
            let n = Int(g.next() % 60)
            img.pixels[p + c] = UInt8(channel == nil ? 70 + n * 2 : (c == channel ? 195 + n : n))
        }
    } }
}

func table(_ cover: Float = 0.5) -> ThresholdTable {
    let c = Cutoffs(cover: cover, clean: 0.05, strike: 0.8, gridMember: 0.3, gridLow: 0.2)
    var m: [String: [String: Cutoffs]] = [:]
    for id in ["fa", "fb"] { m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }) }
    return ThresholdTable(schema: "test", models: m)
}

func detector(budget: Int = 400, cover: Float = 0.5) -> (Detector, FakeModel, FakeModel) {
    let a = FakeModel(id: "fa", family: .a, channel: 0), b = FakeModel(id: "fb", family: .b, channel: 2)
    var cfg = DetectorConfig(); cfg.maxJudgementsPerCall = budget
    let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "t1"), table: table(cover), config: cfg, finder: RegionFinder())
    return (d, a, b)
}

final class RuleTests: XCTestCase {
    let ctxShow = JudgeContext(windowID: 1, startsCovered: false)

    func verdict(_ v: FrameVerdict, _ r: PixelRect) -> RegionVerdict? {
        v.regions.filter { $0.rect.intersection(r).map { $0.area * 2 >= r.area } ?? false }.max { $0.display < $1.display }
    }

    /// Agreement policy: a picture only one family flags is covered when nobody can referee it (SD-125,
    /// C06-3 c). It never strikes and never makes the window hot.
    func testUnansweredDisputeIsCovered() {
        var img = canvas(400, 300)
        let ra = PixelRect(x: 40, y: 40, w: 96, h: 96), rb = PixelRect(x: 240, y: 40, w: 96, h: 96)
        paint(&img, ra, channel: 0, seed: 1); paint(&img, rb, channel: 2, seed: 2)
        let (d, _, _) = detector()
        let v = d.judge(img, context: ctxShow)
        XCTAssertEqual(verdict(v, ra)?.display, .cover)
        XCTAssertEqual(verdict(v, ra)?.reason, .disputed)
        XCTAssertEqual(verdict(v, rb)?.display, .cover)
        XCTAssertEqual(verdict(v, rb)?.reason, .disputed)
        XCTAssertFalse(v.strike, "one family alone never strikes")
        XCTAssertFalse(v.hot, "a dispute never makes the window hot")
    }

    func testBothFamiliesAgreeingCovers() {
        var img = canvas(400, 300)
        let r = PixelRect(x: 40, y: 40, w: 120, h: 120)
        paint(&img, PixelRect(x: 40, y: 40, w: 60, h: 120), channel: 0, seed: 1)
        paint(&img, PixelRect(x: 100, y: 40, w: 60, h: 120), channel: 2, seed: 2)
        let (d, _, _) = detector(cover: 0.3)
        let rv = verdict(d.judge(img, context: ctxShow), r)
        XCTAssertEqual(rv?.display, .cover)
        XCTAssertEqual(rv?.reason, .bothFamilies)
    }

    /// The referee (asked only on disputes) can confirm a cover; when it declines, the picture shows.
    func testRefereeSettlesDisputes() {
        let a = FakeModel(id: "fa", family: .a, channel: 0), b = FakeModel(id: "fb", family: .b, channel: 2)
        let refRed = FakeModel(id: "fr", family: .b, channel: 0)     // agrees with family A on red pictures
        let c = Cutoffs(cover: 0.5, clean: 0.05, strike: 0.8, gridMember: 0.5, gridLow: 0.5)
        var m: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb", "fr"] { m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }) }
        let d = Detector(models: ModelSet(models: [a, b], referee: refRed, bundleVersion: "ref"), table: ThresholdTable(schema: "t", models: m),
                         config: DetectorConfig(), finder: RegionFinder())
        // Separate windows: a confirmed hit makes its own window hot, which would blur the other picture.
        var redImg = canvas(400, 300), blueImg = canvas(400, 300)
        let red = PixelRect(x: 40, y: 40, w: 96, h: 96), blue = PixelRect(x: 240, y: 40, w: 96, h: 96)
        paint(&redImg, red, channel: 0, seed: 1); paint(&blueImg, blue, channel: 2, seed: 2)
        let v = d.judge(redImg, context: JudgeContext(windowID: 31, startsCovered: false))
        XCTAssertEqual(verdict(v, red)?.display, .cover, "referee confirms family A")
        XCTAssertEqual(verdict(v, red)?.reason, .referee)
        let w = d.judge(blueImg, context: JudgeContext(windowID: 32, startsCovered: false))
        XCTAssertEqual(verdict(w, blue)?.display, .clear, "referee declines family B's lone flag")
        XCTAssertGreaterThan(d.refereeCalls, 0)
        XCTAssertEqual(refRed.calls, d.refereeCalls, "the referee is asked only about disputes")
    }

    func testStrikeNeedsBothFamiliesAndSize() {
        // Purple-ish patch flags both fakes: red and blue high, green low.
        var img = canvas(400, 300)
        let r = PixelRect(x: 40, y: 40, w: 128, h: 128)
        var g = XorShift32(seed: 9)
        for y in r.y..<r.maxY { for x in r.x..<r.maxX {
            let p = (y * img.width + x) * 4
            let left = (x - r.x) < r.w / 2
            img.pixels[p] = UInt8(left ? 200 + Int(g.next() % 50) : Int(g.next() % 60))
            img.pixels[p + 1] = UInt8(g.next() % 60)
            img.pixels[p + 2] = UInt8(left ? Int(g.next() % 60) : 200 + Int(g.next() % 50))
        } }
        let c = Cutoffs(cover: 0.3, clean: 0.05, strike: 0.4, gridMember: 0.3, gridLow: 0.2)
        let t = ThresholdTable(schema: "t", models: ["fa": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }),
                                                     "fb": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })])
        let a = FakeModel(id: "fa", family: .a, channel: 0), b = FakeModel(id: "fb", family: .b, channel: 2)
        let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "t"), table: t, config: DetectorConfig(), finder: RegionFinder())
        XCTAssertTrue(d.judge(img, context: ctxShow).strike)
        // The same picture at 40 px never strikes (small-picture rules never create strikes).
        var small = canvas(200, 200)
        var sm = XorShift32(seed: 3)
        for y in 50..<90 { for x in 50..<90 {
            let p = (y * small.width + x) * 4, left = x < 70
            small.pixels[p] = UInt8(left ? 200 + Int(sm.next() % 50) : Int(sm.next() % 60)); small.pixels[p + 1] = UInt8(sm.next() % 60)
            small.pixels[p + 2] = UInt8(left ? Int(sm.next() % 60) : 200 + Int(sm.next() % 50))
        } }
        let d2 = Detector(models: ModelSet(models: [a, b], bundleVersion: "t2"), table: t, config: DetectorConfig(), finder: RegionFinder())
        let v2 = d2.judge(small, context: ctxShow)
        XCTAssertFalse(v2.strike)
    }

    /// Below 32 px an agreed flag still covers (SD-125, C06-3 b), but it never makes the window hot.
    func testTinyConfirmedFlagCoversAndMakesNothingHot() {
        var img = canvas(300, 200)
        let r = PixelRect(x: 60, y: 60, w: 24, h: 24)
        paint(&img, PixelRect(x: 60, y: 60, w: 12, h: 24), channel: 0, seed: 1)
        paint(&img, PixelRect(x: 72, y: 60, w: 12, h: 24), channel: 2, seed: 2)
        let (d, _, _) = detector(cover: 0.3)
        let v = d.judge(img, context: ctxShow)
        let tiny = v.regions.filter { $0.pass == .region && $0.rect.intersects(r) && $0.rect.shortSide < 32 }
        XCTAssertFalse(tiny.isEmpty, "the finder proposes the tiny picture")
        let rv = tiny.max { $0.display < $1.display }
        XCTAssertEqual(rv?.display, .cover)
        XCTAssertEqual(rv?.reason, .bothFamilies)
        XCTAssertFalse(v.strike)
        XCTAssertFalse(v.hot, "a tiny hit never makes the window hot")
    }

    func testSmallPicturesContainedOnlyWhereAppsStartCovered() {
        var img = canvas(300, 200)
        let r = PixelRect(x: 60, y: 60, w: 40, h: 40)
        paint(&img, r, channel: nil, seed: 5)   // neutral, not flagged, not confidently clean? fake clean = score <= 0.05 -> clean
        let (d, _, _) = detector()
        // Neutral content scores 0 on the fakes, so it is cleared even in a covered-start app.
        XCTAssertEqual(verdict(d.judge(img, context: JudgeContext(windowID: 2, startsCovered: true)), r)?.display, .clear)
        // A faintly marked tile (below cover, above clean) stays blurred in covered-start apps only.
        var faint = canvas(300, 200)
        paint(&faint, r, channel: nil, seed: 6)
        paint(&faint, PixelRect(x: r.x, y: r.y, w: r.w, h: 6), channel: 0, seed: 61)
        let (d2, _, _) = detector()
        XCTAssertEqual(verdict(d2.judge(faint, context: JudgeContext(windowID: 3, startsCovered: true)), r)?.display, .contain)
        let (d3, _, _) = detector()
        XCTAssertEqual(verdict(d3.judge(faint, context: JudgeContext(windowID: 4, startsCovered: false)), r)?.display, .clear)
        // Untrusted displays (TVs, projectors) contain like covered-start apps.
        let (d4, _, _) = detector()
        XCTAssertEqual(verdict(d4.judge(faint, context: JudgeContext(windowID: 5, startsCovered: false, display: .untrusted)), r)?.display, .contain)
    }

    func testHotContextAfterConfirmedHit() {
        // Family-A and family-B hits in one window make it hot; a later faint small tile is then blurred even in a show-first app.
        // One picture both families flag: red left half, blue right half.
        var img = canvas(500, 300)
        paint(&img, PixelRect(x: 20, y: 20, w: 60, h: 120), channel: 0, seed: 1)
        paint(&img, PixelRect(x: 80, y: 20, w: 60, h: 120), channel: 2, seed: 2)
        // Each half fills ~50% of the picture; a 0.3 cut-off keeps the test clear of jitter at the boundary.
        let (d, _, _) = detector(cover: 0.3)
        var whole = d.judge(img, context: ctxShow)
        // a both-family hit needs both flags on one task: the whole pass sees both colours
        XCTAssertTrue(whole.hot, "a both-family hit makes the window hot")
        var later = canvas(300, 200)
        let r = PixelRect(x: 60, y: 60, w: 90, h: 90)
        paint(&later, r, channel: nil, seed: 7)
        paint(&later, PixelRect(x: r.x, y: r.y, w: r.w, h: 10), channel: 0, seed: 71)
        whole = d.judge(later, context: JudgeContext(windowID: 1, startsCovered: false, now: Date().addingTimeInterval(60)))
        XCTAssertEqual(verdict(whole, r)?.display, .contain)
        let after = d.judge(later, context: JudgeContext(windowID: 1, startsCovered: false, now: Date().addingTimeInterval(16 * 60)))
        XCTAssertEqual(verdict(after, r)?.display, .clear, "hot context lasts 15 minutes")
    }

    func testGridOfLowTilesMakesWindowHot() {
        var img = canvas(600, 200)
        for i in 0..<5 {
            let r = PixelRect(x: 20 + i * 100, y: 40, w: 90, h: 90)
            paint(&img, r, channel: nil, seed: UInt32(10 + i))
            // a stripe gives each tile a low (gridLow) score without reaching cover
            paint(&img, PixelRect(x: r.x, y: r.y, w: r.w, h: 22), channel: 0, seed: UInt32(30 + i))
        }
        let (d, _, _) = detector()
        let v = d.judge(img, context: ctxShow)
        XCTAssertTrue(v.hot)
        XCTAssertFalse(v.strike, "group evidence never strikes")
    }

    func testOverloadNeverShowsUnjudgedPictures() {
        var img = canvas(1200, 800)
        for i in 0..<12 { paint(&img, PixelRect(x: 20 + (i % 6) * 190, y: 30 + (i / 6) * 300, w: 150, h: 150), channel: nil, seed: UInt32(i + 1)) }
        let (d, _, _) = detector(budget: 4)
        let v = d.judge(img, context: ctxShow)
        XCTAssertGreaterThan(v.overloaded, 0)
        for r in v.regions where r.reason == .overload { XCTAssertNotEqual(r.display, .clear) }
        let (d2, _, _) = detector(budget: 0)
        let v2 = d2.judge(img, context: JudgeContext(windowID: 9, startsCovered: true))
        XCTAssertTrue(v2.regions.allSatisfy { $0.display == .cover }, "covered-start apps stay covered when nothing could be judged")
    }

    func testCacheSkipsRepeatedPixels() {
        var img = canvas(400, 300)
        paint(&img, PixelRect(x: 40, y: 40, w: 96, h: 96), channel: nil, seed: 4)
        let (d, a, _) = detector()
        let first = d.judge(img, context: ctxShow)
        let callsAfterFirst = a.calls
        let second = d.judge(img, context: ctxShow)
        XCTAssertGreaterThan(first.judgements, 0)
        XCTAssertEqual(second.judgements, 0)
        XCTAssertEqual(a.calls, callsAfterFirst)
    }

    func testVideoHoldsCoverAcrossCleanFrames() {
        let r = PixelRect(x: 40, y: 40, w: 96, h: 96)
        let (d, _, _) = detector(cover: 0.3)
        var hit = canvas(300, 200)
        paint(&hit, PixelRect(x: r.x, y: r.y, w: r.w / 2, h: r.h), channel: 0, seed: 1)
        paint(&hit, PixelRect(x: r.x + r.w / 2, y: r.y, w: r.w / 2, h: r.h), channel: 2, seed: 3)
        let ctx = JudgeContext(windowID: 7, startsCovered: false, isVideo: true)
        XCTAssertEqual(verdict(d.judge(hit, context: ctx), r)?.display, .cover)
        var clean = canvas(300, 200); paint(&clean, r, channel: nil, seed: 2)
        var displays: [DisplayClass] = []
        for i in 0..<6 {
            var f = clean; f.pixels[0] = UInt8(i)  // a new frame each time (no cache hit)
            displays.append(verdict(d.judge(f, context: ctx), r)?.display ?? .clear)
        }
        XCTAssertEqual(Array(displays.prefix(3)), [.cover, .cover, .cover], "cover is held for a few clean frames")
        XCTAssertEqual(displays.last, .clear)
    }

    func testPiecesKeepAspectAtMostTwo() {
        for r in [PixelRect(x: 0, y: 0, w: 1000, h: 50), PixelRect(x: 3, y: 5, w: 40, h: 333), PixelRect(x: 0, y: 0, w: 100, h: 60)] {
            let ps = Detector.pieces(r)
            for p in ps { XCTAssertLessThanOrEqual(max(p.w, p.h), 2 * min(p.w, p.h)) }
            XCTAssertEqual(ps.first!.x, r.x); XCTAssertEqual(ps.last!.maxX, r.maxX); XCTAssertEqual(ps.last!.maxY, r.maxY)
        }
    }
}
