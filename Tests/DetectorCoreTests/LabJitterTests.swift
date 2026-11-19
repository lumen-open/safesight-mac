// SPDX-License-Identifier: Apache-2.0
// The lab's jitter measurement (lab builds only): it judges the entries the first call would judge, each the
// asked number of times, with every scoring model, and leaves out a model that failed. Synthetic patterns and
// fake models only.
#if KESTREL_LAB
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

final class LabJitterTests: XCTestCase {
    func testTheEntriesAreTheFirstCallsEntries() {
        var img = canvas(900, 400)
        paint(&img, PixelRect(x: 60, y: 60, w: 96, h: 96), channel: nil, seed: 5)
        paint(&img, PixelRect(x: 400, y: 200, w: 40, h: 40), channel: nil, seed: 6)
        let (d, _, _) = detector()
        let entries = d.labEntries(img)
        let v = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false))
        func names(_ a: [(JudgePass, PixelRect)]) -> [String] { a.map { "\($0.0.rawValue) \($0.1.x),\($0.1.y),\($0.1.w)x\($0.1.h)" }.sorted() }
        XCTAssertEqual(names(entries.map { ($0.pass, $0.rect) }), names(v.regions.map { ($0.pass, $0.rect) }), "the same entries")
        XCTAssertTrue(entries.contains { $0.pass == .region } && entries.contains { $0.pass == .whole } && entries.contains { $0.pass == .slice })
        for e in entries { XCTAssertEqual(e.containable, e.pass == .region && e.rect.shortSide < 128) }
    }

    func testEachEntryIsJudgedTheAskedNumberOfTimesWithFreshJitter() {
        var img = canvas(400, 300)
        let r = PixelRect(x: 60, y: 60, w: 96, h: 96), long = PixelRect(x: 20, y: 200, w: 300, h: 60)
        // Red over the picture's left 38 pixels, neutral over the rest: the trims move the edge, so the share moves.
        paint(&img, r, channel: nil, seed: 7); paint(&img, PixelRect(x: r.x, y: r.y, w: 38, h: r.h), channel: 0, seed: 9)
        paint(&img, long, channel: 2, seed: 8)
        let (d, a, b) = detector()
        let out = d.labJitterDraws(img, rects: [r, long], draws: 12)
        XCTAssertEqual(out.count, 2)
        for o in out { XCTAssertEqual(o["fa"]?.count, 12); XCTAssertEqual(o["fb"]?.count, 12) }
        // One judgement per piece per draw (the long picture has several pieces), as `topScore` judges.
        XCTAssertEqual(a.calls, 12 * (1 + Detector.pieces(long).count))
        XCTAssertEqual(b.calls, a.calls)
        // Fresh jitter: the marker share moves between draws of the textured picture.
        XCTAssertGreaterThan(Set(out[0]["fa"]!).count, 1)
        // Batched and one at a time, the same scores.
        XCTAssertEqual(d.labBatchParity(img, rect: r, draws: 6), ["fa": 0, "fb": 0])
    }

    func testAModelThatFailsIsLeftOut() {
        let img = canvas(400, 300)
        let a = FaultyModel(id: "fa", family: .a, score: .nan), b = FaultyModel(id: "fb", family: .b, score: 0.2)
        let c = Cutoffs(cover: 0.5, clean: 0.4, strike: 0.9, gridMember: 0.5, gridLow: 0.5)
        let t = ThresholdTable(schema: "t", models: ["fa": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }),
                                                    "fb": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })])
        let d = Detector(models: ModelSet(models: [a, b], bundleVersion: "lab"), table: t, config: DetectorConfig(), finder: RegionFinder())
        let out = d.labJitterDraws(img, rects: [PixelRect(x: 0, y: 0, w: 100, h: 100)], draws: 4)
        XCTAssertNil(out[0]["fa"], "not a number: left out, never read as a score")
        XCTAssertEqual(out[0]["fb"], [0.2, 0.2, 0.2, 0.2])
        XCTAssertEqual(d.labCutoffs(model: "fb", shortSide: 100).clean, 0.4)
    }
}
#endif
