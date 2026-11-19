// SPDX-License-Identifier: Apache-2.0
// Gaps found in review: a model that gives unusable scores, the order in which a window turns hot, and thin strips.
// Synthetic marker patterns only.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

/// A model whose scores come from a closure, for models that misbehave.
final class ScriptedModel: ScoringModel {
    let id: String, family: Family, side = 32
    let scores: ([[UInt8]]) -> [Float]
    init(id: String, family: Family, scores: @escaping ([[UInt8]]) -> [Float]) { self.id = id; self.family = family; self.scores = scores }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] { scores(tensors) }
}

final class CoverGapTests: XCTestCase {
    let ctx = JudgeContext(windowID: 7, startsCovered: false)

    func cutoffs(_ ids: [String], cover: Float = 0.3) -> ThresholdTable {
        let c = Cutoffs(cover: cover, clean: 0.05, strike: 0.8, gridMember: 0.3, gridLow: 0.2)
        var m: [String: [String: Cutoffs]] = [:]
        for id in ids { m[id] = Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }) }
        return ThresholdTable(schema: "test", models: m)
    }

    func scripted(_ a: @escaping ([[UInt8]]) -> [Float], _ b: @escaping ([[UInt8]]) -> [Float]) -> Detector {
        Detector(models: ModelSet(models: [ScriptedModel(id: "fa", family: .a, scores: a), ScriptedModel(id: "fb", family: .b, scores: b)],
                                  bundleVersion: "scripted"), table: cutoffs(["fa", "fb"]), config: DetectorConfig(), finder: RegionFinder())
    }

    func picturePage() -> RGBAImage {
        var img = canvas(400, 100)
        paint(&img, PixelRect(x: 40, y: 20, w: 60, h: 60), channel: nil, seed: 4)
        return img
    }

    // MARK: Unusable scores

    func testANaNScoreNeverReadsAsClean() {
        let nan: ([[UInt8]]) -> [Float] = { $0.map { _ in .nan } }
        let v = scripted(nan, nan).judge(picturePage(), context: ctx)
        XCTAssertFalse(v.regions.contains { $0.display == .clear }, "\(v.regions)")
        XCTAssertGreaterThan(v.overloaded, 0)
    }

    func testNoScoresAtAllNeverReadAsClean() {
        let none: ([[UInt8]]) -> [Float] = { _ in [] }
        let v = scripted(none, none).judge(picturePage(), context: ctx)
        XCTAssertFalse(v.regions.contains { $0.display == .clear }, "\(v.regions)")
    }

    func testANaNThatIsNotTheFirstScoreIsNotHidden() {
        // Clean first piece, NaN after it: the whole pass (several pieces on a 4:1 page) must not read as clean.
        let late: ([[UInt8]]) -> [Float] = { t in t.indices.map { $0 == 0 ? 0 : .nan } }
        let zero: ([[UInt8]]) -> [Float] = { $0.map { _ in 0 } }
        let v = scripted(late, zero).judge(picturePage(), context: ctx)
        let whole = v.regions.first { $0.pass == .whole }
        XCTAssertEqual(whole?.display, .cover)
        XCTAssertEqual(whole?.reason, .overload)
    }

    func testTooFewScoresNeverReadAsClean() {
        let short: ([[UInt8]]) -> [Float] = { t in Array(repeating: 0, count: max(0, t.count - 1)) }
        let v = scripted(short, short).judge(picturePage(), context: ctx)
        XCTAssertEqual(v.regions.first { $0.pass == .whole }?.display, .cover)
    }

    func testATieBreakerThatGivesNoUsableScoreLeavesTheDisputeCovered() {
        var img = canvas(400, 300)
        let red = PixelRect(x: 40, y: 40, w: 96, h: 96)
        paint(&img, red, channel: 0, seed: 1)
        for bad in [{ (t: [[UInt8]]) -> [Float] in t.map { _ in .nan } }, { _ in [] }, { t in t.map { _ in .infinity } }] {
            let a = FakeModel(id: "fa", family: .a, channel: 0), b = FakeModel(id: "fb", family: .b, channel: 2)
            let ref = ScriptedModel(id: "fr", family: .b, scores: bad)
            let d = Detector(models: ModelSet(models: [a, b], referee: ref, bundleVersion: "ref"), table: cutoffs(["fa", "fb", "fr"], cover: 0.5),
                             config: DetectorConfig(), finder: RegionFinder())
            let v = d.judge(img, context: ctx)
            let rv = v.regions.filter { $0.pass == .region && $0.rect.intersects(red) }
            XCTAssertFalse(rv.isEmpty)
            XCTAssertTrue(rv.allSatisfy { $0.display == .cover }, "\(rv)")
        }
    }
}
