// SPDX-License-Identifier: Apache-2.0
// Model failures (SafeSight Mac). A score that is not a number, infinite, negative or above 1 is a model
// failure for that entry, as a model that throws is: never clear, covered or blurred as an unjudged entry,
// judged again, and counted. Synthetic patterns and set scores only.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

/// A fake model whose scores the test sets: `score` for every tensor, `at[i]` for the i-th tensor of a batch,
/// a failing first `failCalls` calls (NaN), or a throw.
final class FaultyModel: ScoringModel {
    struct Broken: Error {}
    let id: String, family: Family, side: Int
    var score: Float
    var at: [Int: Float] = [:]
    var failCalls = 0
    var throwing = false
    var calls = 0, batches = 0
    init(id: String, family: Family, score: Float, side: Int = 32) { self.id = id; self.family = family; self.score = score; self.side = side }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] {
        calls += tensors.count; batches += 1
        if throwing { throw Broken() }
        if failCalls > 0 { failCalls -= 1; return tensors.map { _ in .nan } }
        return tensors.indices.map { at[$0] ?? score }
    }
}

final class ModelFaultTests: XCTestCase {
    /// A neutral 96 x 96 picture on a 400 x 300 frame: one region (band 64-127) and the whole pass (128+).
    let r = PixelRect(x: 60, y: 60, w: 96, h: 96)
    var img: RGBAImage {
        var i = canvas(400, 300)
        paint(&i, r, channel: nil, seed: 5)
        return i
    }
    let show = JudgeContext(windowID: 1, startsCovered: false)

    func table() -> ThresholdTable {
        let c = Cutoffs(cover: 0.5, clean: 0.4, strike: 0.95, gridMember: 0.5, gridLow: 0.5)
        var m: [String: [String: Cutoffs]] = [:]
        for id in ["fa", "fb", "fr"] { m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }) }
        return ThresholdTable(schema: "test", models: m)
    }

    func detector(_ a: FaultyModel, _ b: FaultyModel, referee: FaultyModel? = nil) -> Detector {
        Detector(models: ModelSet(models: [a, b], referee: referee, bundleVersion: "faults"), table: table(), config: DetectorConfig(), finder: RegionFinder())
    }

    func over(_ v: FrameVerdict) -> RegionVerdict? { v.regions.first { $0.pass == .region && $0.rect == r } }

    func testAnUnusableScoreIsAModelFailureAndNeverClear() {
        for bad: Float in [.nan, -.nan, .infinity, -.infinity, -0.2, -Float.leastNonzeroMagnitude, 1.5, 1.01, .greatestFiniteMagnitude] {
            let a = FaultyModel(id: "fa", family: .a, score: bad), b = FaultyModel(id: "fb", family: .b, score: 0)
            let d = detector(a, b)
            let v = d.judge(img, context: show)
            XCTAssertEqual(over(v)?.display, .contain, "\(bad): the picture is blurred as unjudged, never shown sharp")
            XCTAssertFalse(v.regions.contains { $0.display == .clear }, "\(bad): nothing is clear")
            XCTAssertTrue(v.regions.allSatisfy { $0.reason == .overload }, "\(bad): every entry is unjudged")
            XCTAssertTrue(v.regions.filter { $0.pass != .region }.allSatisfy { $0.display == .cover }, "\(bad): the whole pass is covered")
            XCTAssertEqual(v.overloaded, v.regions.count)
            XCTAssertEqual(v.modelFaults, v.regions.count, "\(bad): one failure per entry, counted")
            XCTAssertEqual(d.modelFaults["fa"], v.regions.count)
            XCTAssertNil(d.modelFaults["fb"])
            XCTAssertEqual(d.timings.modelFaults["fa"], v.regions.count)
            // Nothing was cached: the same pixels are judged again, and are shown once the model works.
            a.score = 0.1
            let again = d.judge(img, context: show)
            XCTAssertGreaterThan(again.judgements, 0, "\(bad): judged again")
            XCTAssertEqual(again.modelFaults, 0)
            XCTAssertEqual(over(again)?.display, .clear)
        }
    }

    func testAFailureCoversInACoveredStartContext() {
        let d = detector(FaultyModel(id: "fa", family: .a, score: 0), FaultyModel(id: "fb", family: .b, score: .nan))
        let v = d.judge(img, context: JudgeContext(windowID: 2, startsCovered: true))
        XCTAssertEqual(over(v)?.display, .cover)
        XCTAssertEqual(over(v)?.reason, .overload)
        XCTAssertGreaterThan(d.modelFaults["fb"] ?? 0, 0)
    }

    func testAModelThatThrowsIsCountedAsAFailure() {
        let a = FaultyModel(id: "fa", family: .a, score: 0)
        a.throwing = true
        let d = detector(a, FaultyModel(id: "fb", family: .b, score: 0))
        let v = d.judge(img, context: show)
        XCTAssertFalse(v.regions.contains { $0.display == .clear })
        XCTAssertEqual(v.modelFaults, v.regions.count)
        XCTAssertEqual(d.modelFaults["fa"], v.regions.count)
    }

    func testAScoreJustAboveOneFromRoundingIsAFlagNotAFailure() {
        let d = detector(FaultyModel(id: "fa", family: .a, score: 1 + Detector.scoreSlack), FaultyModel(id: "fb", family: .b, score: 1))
        let v = d.judge(img, context: show)
        XCTAssertEqual(over(v)?.display, .cover)
        XCTAssertEqual(over(v)?.reason, .bothFamilies)
        XCTAssertEqual(v.modelFaults, 0)
        XCTAssertTrue(d.modelFaults.isEmpty)
        XCTAssertTrue(Detector.usable(0) && Detector.usable(-0.0) && Detector.usable(1) && Detector.usable(1 + Detector.scoreSlack))
        XCTAssertFalse(Detector.usable(.nan) || Detector.usable(.infinity) || Detector.usable(-0.001) || Detector.usable(1.002))
    }

    func testOneUnusableScoreAmongAnEntrysPiecesFailsTheEntry() {
        // A blank 900 x 300 frame: the whole pass is judged in two pieces (2:1 at most), each slice in one.
        // The second piece's score is not a number. The highest of the rest (0.1) must not make it look clean.
        let a = FaultyModel(id: "fa", family: .a, score: 0.1), b = FaultyModel(id: "fb", family: .b, score: 0)
        a.at = [1: .nan]
        let d = detector(a, b)
        let frame = canvas(900, 300)
        XCTAssertEqual(Detector.pieces(PixelRect(x: 0, y: 0, w: 900, h: 300)).count, 2)
        let v = d.judge(frame, context: show)
        let whole = v.regions.first { $0.pass == .whole }
        XCTAssertEqual(whole?.display, .cover)
        XCTAssertEqual(whole?.reason, .overload)
        XCTAssertEqual(v.modelFaults, 1)
        XCTAssertTrue(v.regions.filter { $0.pass == .slice }.allSatisfy { $0.display == .clear }, "single-piece slices are judged as usual")
    }

    func testAFailedTieBreakerLeavesTheDisputeUnansweredSoItIsCovered() {
        // Family A flags, family B does not; the tie-breaker's score is not a number. Before, that read as
        // "declined" and the picture was shown.
        for bad: Float in [.nan, .infinity, -1, 7] {
            let fr = FaultyModel(id: "fr", family: .b, score: bad)
            let d = detector(FaultyModel(id: "fa", family: .a, score: 0.9), FaultyModel(id: "fb", family: .b, score: 0), referee: fr)
            let v = d.judge(img, context: show)
            XCTAssertEqual(over(v)?.display, .cover, "\(bad)")
            XCTAssertEqual(over(v)?.reason, .disputed, "\(bad): unanswered, as when no tie-breaker can be asked")
            XCTAssertGreaterThan(fr.calls, 0)
            XCTAssertEqual(d.refereeCalls, 0, "no answer was taken from it")
            XCTAssertEqual(d.modelFaults["fr"], v.modelFaults)
            XCTAssertGreaterThan(v.modelFaults, 0)
        }
    }

    func testAFailureOfTheFastestModelIsNotRetriedInTheSameCall() {
        // With `progress`, the fastest model judges the picture regions first. If it fails on a picture, that
        // picture stays unjudged in this call (blurred), even though a second try would have worked.
        let a = FaultyModel(id: "fa", family: .a, score: 0, side: 32), b = FaultyModel(id: "fb", family: .b, score: 0, side: 64)
        a.failCalls = 1
        let d = detector(a, b)
        XCTAssertEqual(d.fastestModel?.id, "fa")
        var heard: [JudgeProgress] = []
        let v = d.judge(img, context: show) { heard.append($0) }
        XCTAssertFalse(heard.isEmpty)
        XCTAssertEqual(over(v)?.display, .contain)
        XCTAssertEqual(over(v)?.reason, .overload)
        XCTAssertEqual(v.regions.first { $0.pass == .whole }?.display, .clear, "the other entries are judged as usual")
        XCTAssertEqual(v.modelFaults, 1)
        // The next call judges it, with the model working, and shows it.
        let next = d.judge(img, context: show) { _ in }
        XCTAssertEqual(over(next)?.display, .clear)
        XCTAssertEqual(next.modelFaults, 0)
        XCTAssertEqual(d.modelFaults["fa"], 1)
    }
}
