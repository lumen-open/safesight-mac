// SPDX-License-Identifier: Apache-2.0
// No score and no cut-off leaves DetectorCore (spec/detector-contract.md). Scores come in through `ScoringModel` and
// stop there: every verdict and every progress report is classes, rectangles, counts and times. Here: what a judge
// call hands back holds no Float anywhere. tools/check-no-score-api.sh checks the public API itself.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

final class NoScoreLeaksTests: XCTestCase {
    /// Every value reachable from `v`, by reflection: no Float may be among them. Doubles are times (`estimatedMs`).
    func floats(in v: Any, path: String = "") -> [String] {
        if v is Float { return [path] }
        return Mirror(reflecting: v).children.flatMap { c in floats(in: c.value, path: path + "." + (c.label ?? "?")) }
    }

    func testWhatAJudgeCallHandsBackHoldsNoScore() {
        var img = canvas(900, 600)
        paint(&img, PixelRect(x: 40, y: 40, w: 96, h: 96), channel: 0, seed: 1)
        paint(&img, PixelRect(x: 300, y: 60, w: 160, h: 160), channel: 2, seed: 2)
        paint(&img, PixelRect(x: 520, y: 300, w: 200, h: 140), channel: nil, seed: 3)
        let a = FakeModel(id: "fa", family: .a, channel: 0), b = FakeModel(id: "fb", family: .b, channel: 2)
        for single in [false, true] {
            let set = single ? try! ModelSet(scorers: [a], singleFamily: true, bundleVersion: "s")
                             : try! ModelSet(scorers: [a, b], tieBreaker: FakeModel(id: "fr", family: .b, channel: 1), bundleVersion: "s")
            let d = Detector(models: set, table: table(), config: DetectorConfig(), finder: RegionFinder())
            var reports: [JudgeProgress] = []
            let v = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)) { reports.append($0) }
            XCTAssertFalse(v.regions.isEmpty)
            XCTAssertEqual(floats(in: v), [], "a verdict holds classes only")
            XCTAssertEqual(floats(in: reports), [], "progress holds classes only")
            XCTAssertEqual(floats(in: d.secondChecks(img, context: JudgeContext(windowID: 1, startsCovered: false), within: PixelRect(x: 0, y: 0, w: 900, h: 600), budget: 400)), [])
            XCTAssertEqual(floats(in: d.modelFaults), [])
            XCTAssertEqual(floats(in: d.timings), [])
            XCTAssertEqual(floats(in: d.config), [])
        }
    }

    // The module's public API is checked from the compiler's symbol graph by tools/check-no-score-api.sh, which CI runs:
    // no public or open declaration names a floating-point type except the reviewed ones in tools/no-score-api-allow.txt.
}
