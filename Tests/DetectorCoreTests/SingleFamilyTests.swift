// SPDX-License-Identifier: Apache-2.0
// Single-family mode (spec/detector-contract.md): a bundle that declares one family covers on that family's flag
// alone, under every rule, so fewer models never means less covering. And the set checks: a set the rule cannot run
// with is refused, never trapped. Synthetic marker patterns only.
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

/// A model that never flags (scores 0).
final class QuietModel: ScoringModel {
    let id: String, family: Family, side = 32
    init(id: String, family: Family) { self.id = id; self.family = family }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] { tensors.map { _ in 0 } }
}

final class SingleFamilyTests: XCTestCase {
    let show = JudgeContext(windowID: 1, startsCovered: false)
    let red = PixelRect(x: 40, y: 40, w: 96, h: 96)

    func cutoffs(_ ids: [String]) -> ThresholdTable {
        let c = Cutoffs(cover: 0.5, clean: 0.05, strike: 0.8, gridMember: 0.3, gridLow: 0.2)
        return ThresholdTable(schema: "test", models: Dictionary(uniqueKeysWithValues: ids.map { ($0, Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })) }))
    }

    func single(_ rule: DetectorRule = .balanced, family: Family = .a) -> Detector {
        var cfg = DetectorConfig(); cfg.rule = rule
        let set = try! ModelSet(scorers: [FakeModel(id: "fa", family: family, channel: 0)], singleFamily: true, bundleVersion: "one")
        return Detector(models: set, table: cutoffs(["fa"]), config: cfg, finder: RegionFinder())
    }

    /// The same red family model with a second family that never flags, and a tie-breaker that always declines.
    func twoFamilies(_ rule: DetectorRule, declining: Bool) -> Detector {
        var cfg = DetectorConfig(); cfg.rule = rule
        let set = ModelSet(models: [FakeModel(id: "fa", family: .a, channel: 0), QuietModel(id: "fb", family: .b)],
                           referee: declining ? QuietModel(id: "fr", family: .b) : nil, bundleVersion: "two")
        return Detector(models: set, table: cutoffs(["fa", "fb", "fr"]), config: cfg, finder: RegionFinder())
    }

    func verdict(_ v: FrameVerdict, _ r: PixelRect) -> RegionVerdict? {
        v.regions.filter { $0.rect.intersection(r).map { $0.area * 2 >= r.area } ?? false }.max { $0.display < $1.display }
    }

    func scene(seed: UInt32 = 1) -> RGBAImage {
        var img = canvas(400, 300)
        paint(&img, red, channel: 0, seed: seed)
        paint(&img, PixelRect(x: 220, y: 120, w: 120, h: 120), channel: nil, seed: seed + 7)
        return img
    }

    func testItsFlagAloneCoversUnderEveryRule() {
        for rule in DetectorRule.allCases {
            for family in [Family.a, .b] {
                let v = single(rule, family: family).judge(scene(), context: show)
                XCTAssertEqual(verdict(v, red)?.display, .cover, "\(rule) \(family)")
                XCTAssertEqual(verdict(v, red)?.reason, .oneFamily, "\(rule) \(family)")
                XCTAssertTrue(v.hot, "its hit makes the window hot, as both families' agreement would (\(rule))")
            }
        }
    }

    func testAHarmlessPictureIsShown() {
        let harmless = PixelRect(x: 220, y: 120, w: 120, h: 120)
        let v = single().judge(scene(), context: JudgeContext(windowID: 2, startsCovered: false))
        XCTAssertEqual(verdict(v, harmless)?.display, .clear)
    }

    /// Fewer models never means less covering: wherever two families (with the same family-A model) cover, under
    /// either rule, with or without a tie-breaker that declines, the single family covers too.
    func testFewerModelsNeverCoverLess() {
        for seed in UInt32(1)...6 {
            let img = scene(seed: seed)
            let one = single().judge(img, context: JudgeContext(windowID: UInt64(seed), startsCovered: false))
            for rule in DetectorRule.allCases {
                for declining in [false, true] {
                    let two = twoFamilies(rule, declining: declining).judge(img, context: JudgeContext(windowID: UInt64(seed), startsCovered: false))
                    for r in two.regions where r.display != .clear {
                        XCTAssertGreaterThanOrEqual(verdict(one, r.rect)?.display ?? .clear, r.display, "seed \(seed) \(rule) declining \(declining) \(r.rect)")
                    }
                }
            }
            // And where a declining tie-breaker clears the red picture under Balanced, the single family covers it.
            let declined = twoFamilies(.balanced, declining: true).judge(img, context: JudgeContext(windowID: 99, startsCovered: false))
            XCTAssertEqual(verdict(declined, red)?.display, .clear)
            XCTAssertEqual(verdict(one, red)?.display, .cover)
        }
    }

    func testItsFastFlagCovers() {
        var flags: [RegionVerdict] = []
        _ = single().judge(scene(), context: show) { p in if case .fastFlag(let r) = p { flags.append(r) } }
        XCTAssertFalse(flags.isEmpty)
        XCTAssertTrue(flags.allSatisfy { $0.display == .cover })
    }

    func testFaultsAndOverloadStillCover() {
        let z = single().judge(scene(), context: show, budget: 0)
        XCTAssertTrue(z.regions.allSatisfy { $0.reason == .overload && $0.display != .clear })
        let broken = FaultyModel(id: "fa", family: .a, score: 0)
        broken.throwing = true
        let d = Detector(models: try! ModelSet(scorers: [broken], singleFamily: true, bundleVersion: "one"), table: cutoffs(["fa"]),
                         config: DetectorConfig(), finder: RegionFinder())
        let v = d.judge(scene(), context: show)
        XCTAssertGreaterThan(v.modelFaults, 0)
        XCTAssertTrue(v.regions.allSatisfy { $0.display != .clear }, "a failed model shows nothing as clean")
    }

    func testTwoFamilyBundlesAreUnchanged() {
        // Off unless declared: a two-family set never takes the single-family path.
        let v = twoFamilies(.balanced, declining: false).judge(scene(), context: show)
        XCTAssertEqual(verdict(v, red)?.reason, .disputed)
        XCTAssertFalse(v.hot)
    }

    func testSetsTheRuleCannotRunWithAreRefused() {
        let a = QuietModel(id: "a", family: .a), b = QuietModel(id: "b", family: .b), s = QuietModel(id: "s", family: .student)
        XCTAssertThrowsError(try ModelSet(scorers: [a], bundleVersion: "x")) { XCTAssertEqual($0 as? ModelSetFailure, .needsTwoFamilies) }
        XCTAssertThrowsError(try ModelSet(scorers: [a, b], singleFamily: true, bundleVersion: "x")) { XCTAssertEqual($0 as? ModelSetFailure, .needsOneFamily) }
        XCTAssertThrowsError(try ModelSet(scorers: [], singleFamily: true, bundleVersion: "x")) { XCTAssertEqual($0 as? ModelSetFailure, .needsOneFamily) }
        XCTAssertThrowsError(try ModelSet(scorers: [a], tieBreaker: b, singleFamily: true, bundleVersion: "x")) {
            XCTAssertEqual($0 as? ModelSetFailure, .tieBreakerWithOneFamily)
        }
        XCTAssertThrowsError(try ModelSet(scorers: [a, b, s], bundleVersion: "x")) { XCTAssertEqual($0 as? ModelSetFailure, .studentAsFamily) }
        XCTAssertNoThrow(try ModelSet(scorers: [a, b], tieBreaker: QuietModel(id: "t", family: .b), bundleVersion: "x"))
        XCTAssertNoThrow(try ModelSet(scorers: [a, QuietModel(id: "a2", family: .a)], singleFamily: true, bundleVersion: "x"))
    }

    func testASingleFamilyManifestBuildsASingleFamilySet() throws {
        func manifest(_ families: Int, _ slots: [String]) -> Data {
            let models = slots.enumerated().map { i, slot in
                #"{"id": "m\#(i)", "slot": "\#(slot)", "runtime": "coreml", "package": "m\#(i)/m\#(i).mlpackage", "inputSide": 224, "classCount": 2, "#
                    + #""flagClasses": [0], "computeUnits": "cpuAndNeuralEngine", "files": [{"path": "m\#(i)/m\#(i).mlpackage/x", "sha256": "\#(String(repeating: "a", count: 64))"}]}"#
            }
            return Data(#"{"schema": "kestrel-models/1", "families": \#(families), "models": [\#(models.joined(separator: ","))]}"#.utf8)
        }
        let one = try ModelSet.bundle(ModelManifest.decode(manifest(1, ["B"])), bundleVersion: "x") { QuietModel(id: $0.id, family: $0.family) }
        XCTAssertTrue(one.singleFamily)
        let two = try ModelSet.bundle(ModelManifest.decode(manifest(2, ["A", "B", "tie-breaker"])), bundleVersion: "x") { QuietModel(id: $0.id, family: $0.family) }
        XCTAssertFalse(two.singleFamily)
        XCTAssertEqual(two.referee?.id, "m2")
        XCTAssertThrowsError(try ModelManifest.decode(manifest(1, ["A", "tie-breaker"])))
    }
}
