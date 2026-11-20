// SPDX-License-Identifier: Apache-2.0
// A password prompt's hole opens only once the plain cover behind it has been drawn (HoleGate): first the backing over
// the rectangle with the covers still over it, then the hole. A hole that moves is covered again until its backing has
// moved too.
import CoreGraphics
import Testing
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@Suite struct HoleGateTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let hole = CGRect(x: 200, y: 120, width: 200, height: 160)
    var around: CoverPlan {
        CoverPlan(display: d, items: [CoverItem(rect: CGRect(x: 0, y: 0, width: 600, height: 120), kind: .plain)], promptHoles: [hole])
    }
    func covered(_ plan: CoverPlan, _ r: CGRect) -> Bool {
        if plan.wholeDisplay != nil {
            let pieces = CoverLayout.layerPieces(plan).map(\.frame)
            let layer = CoordinateSpace.toCanvasLayer(r.insetBy(dx: 1, dy: 1), display: d.bounds)
            return pieces.reduce([layer]) { $0.subtracting($1) }.isEmpty
        }
        return plan.items.contains { $0.rect.contains(r) }
    }

    @Test func theHoleOpensOnlyAfterItsBackingWasDrawn() {
        var g = HoleGate()
        let first = g.gate([around])
        #expect(first.heldBack && covered(first.plans[0], hole), "first drawing: backing only, the hole still covered")
        g.drew(Set(HoleGate.holes([around])))
        let second = g.gate([around])
        #expect(!second.heldBack && !covered(second.plans[0], hole), "its backing is up: the hole opens")
    }

    @Test func aMovedHoleIsCoveredUntilItsBackingMoved() {
        var g = HoleGate()
        g.drew(Set(HoleGate.holes([around])))
        var moved = around
        moved.promptHoles = [hole.offsetBy(dx: 30, dy: 0)]
        let m = g.gate([moved])
        #expect(m.heldBack && covered(m.plans[0], hole.offsetBy(dx: 30, dy: 0)))
        g.drew([])
        #expect(g.gate([around]).heldBack, "a backing taken down counts no more")
    }

    @Test func aWholeDisplayCoverKeepsTheHoleClosedUntilItsBackingWasDrawn() {
        var g = HoleGate()
        let whole = CoverPlan(display: d, items: [], wholeDisplay: .windowAboveCovers, promptHoles: [hole])
        let first = g.gate([whole])
        #expect(first.heldBack && first.plans[0].promptHoles.isEmpty && covered(first.plans[0], hole))
        g.drew(Set(HoleGate.holes([whole])))
        let second = g.gate([whole])
        #expect(second.plans[0].promptHoles == [hole] && !covered(second.plans[0], hole))
    }

    @Test func plansWithoutHolesAreUntouched() {
        let g = HoleGate()
        let plain = CoverPlan(display: d, items: [CoverItem(rect: hole, kind: .plain)])
        let r = g.gate([plain])
        #expect(!r.heldBack && r.plans == [plain])
    }
}
