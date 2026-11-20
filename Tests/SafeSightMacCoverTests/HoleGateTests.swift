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

/// The order of drawing, with stand-in panels and canvas: at no moment is a hole cut in the covers without a backing
/// standing at exactly its place, when a hole opens, closes, moves, or two holes trade places.
@MainActor @Suite struct BackingOrderTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))

    /// What is on screen: the holes cut in the covers, and where each backing stands.
    @MainActor final class World {
        var cut: Set<HoleGate.Hole> = []
        var panels: [FakePanel] = []
        var turns: [BehindPrompt.Turn] = []
        var violations: [String] = []
        func check(_ when: String) {
            for h in cut where !panels.contains(where: { $0.shown && $0.frame == h.rect }) {
                violations.append("\(when): hole \(h.rect) cut with no backing there")
            }
        }
    }
    final class FakePanel: BackingPanel {
        let world: World
        var frame: CGRect = .null
        var shown = false
        init(_ w: World) { world = w }
        func place(_ f: CGRect, theme: CoverTheme) -> Bool {
            if frame != f { frame = f; world.check("moved a backing") }
            shown = true
            return true
        }
        func hide() { shown = false; world.check("took a backing down") }
    }

    func setUp() -> (World, BehindPrompt) {
        let w = World()
        let b = BehindPrompt(make: { let p = FakePanel(w); w.panels.append(p); return p },
                             nextTurn: { w.turns.append($0) }, toCocoa: { $0 })
        return (w, b)
    }

    /// Draws `holes` through the backings, the canvas recording what it cuts, then runs the main loop's next turns.
    func show(_ holes: [CGRect], _ w: World, _ b: BehindPrompt) {
        let plan = CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: holes)
        func draw(_ plans: [CoverPlan]) {
            // A hole is cut when no plain cover was put back over exactly it.
            w.cut = Set(plans.flatMap { p in p.promptHoles.filter { r in !p.items.contains { $0.rect == r } }.map { HoleGate.Hole(display: p.display.id, rect: $0) } })
            w.check("drew the covers")
        }
        func apply(_ plans: [CoverPlan]) { b.apply(plans, theme: .light, draw: draw, again: apply) }
        apply([plan])
        while !w.turns.isEmpty { w.turns.removeFirst()() }
    }

    @Test func openingClosingMovingAndTradingPlacesNeverCutAHoleWithoutItsBacking() {
        let (w, b) = setUp()
        let a = CGRect(x: 100, y: 100, width: 150, height: 120), c = CGRect(x: 320, y: 100, width: 150, height: 120)
        show([a], w, b)
        #expect(w.cut == [HoleGate.Hole(display: 1, rect: a)], "opens after its backing")
        show([a.offsetBy(dx: 20, dy: 0)], w, b)                         // moved
        #expect(w.cut == [HoleGate.Hole(display: 1, rect: a.offsetBy(dx: 20, dy: 0))])
        show([a, c], w, b)                                              // two holes
        show([c.offsetBy(dx: -220, dy: 0), a.offsetBy(dx: 220, dy: 0)], w, b)  // the two trade places
        show([CGRect(x: 10, y: 10, width: 100, height: 100)], w, b)     // both go, a new one comes
        show([], w, b)                                                  // closed
        #expect(w.cut.isEmpty)
        #expect(w.violations.isEmpty, "\(w.violations)")
        #expect(w.panels.allSatisfy { !$0.shown }, "every backing taken down once its hole is gone")
    }

    @Test func aBackingThatCannotBeDrawnKeepsItsHoleClosed() {
        let w = World()
        final class Broken: BackingPanel {
            func place(_ f: CGRect, theme: CoverTheme) -> Bool { false }
            func hide() {}
        }
        let b = BehindPrompt(make: { Broken() }, nextTurn: { w.turns.append($0) }, toCocoa: { $0 })
        show([CGRect(x: 100, y: 100, width: 150, height: 120)], w, b)
        #expect(w.cut.isEmpty)
    }
}
