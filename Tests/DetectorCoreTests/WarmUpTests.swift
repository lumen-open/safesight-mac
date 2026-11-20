// SPDX-License-Identifier: Apache-2.0
// The warm-up before anything is judged (`Detector.warmUp(limit:)`): every model must give a usable score, within the
// time limit. One failed first call is asked again; a second failure, or running past the limit, is a fault, counted,
// and the caller keeps every display covered. Set scores only.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

/// A model that sleeps before it answers.
final class SlowModel: ScoringModel {
    let id: String, family: Family, side = 32
    let seconds: TimeInterval
    init(id: String, family: Family, seconds: TimeInterval) { self.id = id; self.family = family; self.seconds = seconds }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] { Thread.sleep(forTimeInterval: seconds); return tensors.map { _ in 0 } }
}

final class WarmUpTests: XCTestCase {
    func detector(_ a: ScoringModel, _ b: ScoringModel, referee: ScoringModel? = nil) -> Detector {
        Detector(models: ModelSet(models: [a, b], referee: referee, bundleVersion: "warm"), table: ThresholdTable(schema: "t", models: [:]),
                 config: DetectorConfig(), finder: RegionFinder())
    }

    func testWorkingModelsWarmUp() {
        let d = detector(FaultyModel(id: "fa", family: .a, score: 0), FaultyModel(id: "fb", family: .b, score: 0.2),
                         referee: FaultyModel(id: "fr", family: .b, score: 0))
        XCTAssertTrue(d.warmUp(limit: 5))
        XCTAssertEqual(d.modelFaults, [:])
    }

    func testOneFailedFirstCallIsAskedAgain() {
        let a = FaultyModel(id: "fa", family: .a, score: 0)
        a.failCalls = 1
        let d = detector(a, FaultyModel(id: "fb", family: .b, score: 0))
        XCTAssertTrue(d.warmUp(limit: 5))
        XCTAssertEqual(d.modelFaults["fa"], 1, "the failed first call is still counted")
    }

    func testAModelThatKeepsFailingFailsTheWarmUp() {
        let b = FaultyModel(id: "fb", family: .b, score: 0)
        b.throwing = true
        let d = detector(FaultyModel(id: "fa", family: .a, score: 0), b)
        XCTAssertFalse(d.warmUp(limit: 5))
        XCTAssertEqual(d.modelFaults["fb"], 2)
        let nan = FaultyModel(id: "fr", family: .b, score: .nan)
        XCTAssertFalse(detector(FaultyModel(id: "fa", family: .a, score: 0), FaultyModel(id: "fb", family: .b, score: 0), referee: nan).warmUp(limit: 5),
                       "a tie-breaker giving no usable score fails it too")
    }

    func testRunningPastTheLimitFailsTheWarmUp() {
        let d = detector(SlowModel(id: "fa", family: .a, seconds: 0.2), SlowModel(id: "fb", family: .b, seconds: 0.2))
        XCTAssertFalse(d.warmUp(limit: 0.1))
        XCTAssertTrue(d.warmUp(limit: 5))
    }

    func testTheWarmUpJudgesNothingAndCachesNothing() {
        let a = FaultyModel(id: "fa", family: .a, score: 0), b = FaultyModel(id: "fb", family: .b, score: 0)
        let d = detector(a, b)
        XCTAssertTrue(d.warmUp(limit: 5))
        var img = canvas(400, 300)
        paint(&img, PixelRect(x: 40, y: 40, w: 96, h: 96), channel: nil, seed: 2)
        XCTAssertGreaterThan(d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)).judgements, 0)
    }
}
