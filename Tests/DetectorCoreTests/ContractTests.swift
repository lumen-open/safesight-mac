// SPDX-License-Identifier: Apache-2.0
// Tests for the contract additions made in SafeSight Mac: the Either rule, the caller's budget,
// the pass of each entry and the separate `find` call (register SD-125, SD-133).
import Foundation
import XCTest
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder

final class ContractTests: XCTestCase {
    func verdict(_ v: FrameVerdict, _ r: PixelRect) -> RegionVerdict? {
        v.regions.filter { $0.rect.intersection(r).map { $0.area * 2 >= r.area } ?? false }.max { $0.display < $1.display }
    }

    /// Under Either, one family's flag covers. Under Balanced with no tie-breaker it covers too, as a
    /// dispute nobody could settle (SD-125, C06-3 c).
    func testEitherCoversOneFamilyAlone() {
        var img = canvas(400, 300)
        let ra = PixelRect(x: 40, y: 40, w: 96, h: 96)
        paint(&img, ra, channel: 0, seed: 1)
        let (balanced, _, _) = detector()
        let b = verdict(balanced.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)), ra)
        XCTAssertEqual(b?.display, .cover)
        XCTAssertEqual(b?.reason, .disputed)
        let (either, _, _) = detector()
        either.setRule(.either)
        let v = either.judge(img, context: JudgeContext(windowID: 2, startsCovered: false))
        XCTAssertEqual(verdict(v, ra)?.display, .cover)
        XCTAssertNotEqual(verdict(v, ra)?.reason, .disputed, "Either never disputes")
    }

    /// Changing the rule empties the cache, so the next call judges again under the new rule.
    func testRuleChangeEmptiesCache() {
        var img = canvas(400, 300)
        paint(&img, PixelRect(x: 40, y: 40, w: 96, h: 96), channel: 0, seed: 1)
        let (d, _, _) = detector()
        _ = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false))
        XCTAssertEqual(d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)).judgements, 0, "cached")
        d.setRule(.either)
        XCTAssertGreaterThan(d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false)).judgements, 0, "cache emptied")
    }

    /// A caller budget of 0 returns every entry as overload, and nothing as clear.
    func testZeroBudgetReturnsOverloadOnly() {
        var img = canvas(600, 400)
        paint(&img, PixelRect(x: 40, y: 40, w: 120, h: 120), channel: nil, seed: 3)
        let (d, _, _) = detector()
        let v = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false), budget: 0)
        XCTAssertEqual(v.judgements, 0)
        XCTAssertFalse(v.regions.isEmpty)
        XCTAssertTrue(v.regions.allSatisfy { $0.reason == .overload && $0.display != .clear })
    }

    func testEveryEntryNamesItsPass() {
        var img = canvas(1200, 700)
        paint(&img, PixelRect(x: 40, y: 40, w: 120, h: 120), channel: nil, seed: 3)
        let (d, _, _) = detector()
        let v = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false))
        let passes = Set(v.regions.map(\.pass))
        XCTAssertEqual(passes, [.region, .whole, .slice])
    }

    func testFindMatchesTheFinder() {
        var img = canvas(400, 300)
        paint(&img, PixelRect(x: 40, y: 40, w: 96, h: 96), channel: nil, seed: 3)
        let (d, _, _) = detector()
        XCTAssertEqual(d.find(img).regions.map(\.rect), RegionFinder().find(img).regions.map(\.rect))
    }
}
