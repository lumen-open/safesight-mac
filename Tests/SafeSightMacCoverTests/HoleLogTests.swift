// SPDX-License-Identifier: Apache-2.0
// What the lab log is told about password-prompt holes: every drawing says which holes it cut and which it kept
// covered, the presenter's own redraws included (a hole opens on the drawing after its backing is up). Lab builds
// only, and logging only: nothing here changes what is drawn.
#if SAFESIGHTMAC_LAB
import CoreGraphics
import Foundation
import Testing
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@MainActor @Suite struct HoleLogTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let a = CGRect(x: 100, y: 100, width: 150, height: 120)

    @Test func eachDrawingSaysWhetherItsHoleWasCut() {
        let w = BackingOrderTests.World()
        let b = BehindPrompt(make: { let p = BackingOrderTests.FakePanel(w); w.panels.append(p); return p },
                             nextTurn: { w.turns.append($0) }, toCocoa: { $0 },
                             windows: { BackingOrderTests.prompts(w.promptsAt) }, watchLater: { _, _ in }, flush: {})
        var told: [HolesDrawn] = []
        b.onDrew = { told.append($0) }
        w.promptsAt = [a]
        let plan = CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: [a], promptFrames: promptFrames([a]))
        func apply(_ plans: [CoverPlan]) { b.apply(plans, theme: .light, draw: { _ in }, again: apply) }
        apply([plan])
        let hole = HoleGate.Hole(display: 1, rect: a)
        // First drawing: the backing goes up, the hole stays covered.
        #expect(told == [HolesDrawn(cut: [], shut: [hole])])
        #expect(told[0].field(display: 1) == "shut@100,100,150,120")
        // The next turn draws again by itself and cuts it.
        while !w.turns.isEmpty { w.turns.removeFirst()() }
        #expect(told.last == HolesDrawn(cut: [hole], shut: []))
        #expect(told.last?.field(display: 1) == "cut@100,100,150,120")
        #expect(told.last?.field(display: 2) == "-")
        // The prompt goes: the next drawing, with a plan made before, keeps the hole covered and says so.
        w.promptsAt = []
        apply([plan])
        #expect(told.last == HolesDrawn(cut: [], shut: [hole]))
        b.removeAll()
        #expect(told.last == HolesDrawn())
    }

    /// Stands in for a canvas: its holes are whatever the test says, told after each drawing.
    @MainActor final class Inner: CoverPresenter {
        var notice: CoverNotice?
        var onHolesDrawn: ((HolesDrawn) -> Void)?
        var next = HolesDrawn()
        func apply(_ plans: [CoverPlan]) { onHolesDrawn?(next) }
        func keepUp() { onHolesDrawn?(next) }
        func removeAll() { onHolesDrawn?(HolesDrawn()) }
    }

    @Test func drawingsOutsideApplyAreReportedOnlyWhenTheHolesChange() {
        let inner = Inner()
        let watched = WatchedPresenter(inner)
        var redrawn: [HolesDrawn] = []
        watched.onHolesRedrawn = { redrawn.append($0) }
        let hole = HoleGate.Hole(display: 1, rect: a)
        let plan = CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: [a])
        // Through apply: kept for the draw line, not reported again.
        inner.next = HolesDrawn(shut: [hole])
        watched.apply([plan])
        #expect(watched.lastHoles == HolesDrawn(shut: [hole]))
        #expect(redrawn.isEmpty)
        // The presenter's own redraw opens it: reported once.
        inner.next = HolesDrawn(cut: [hole])
        inner.onHolesDrawn?(inner.next)
        #expect(redrawn == [HolesDrawn(cut: [hole])])
        // The same again (keepUp, four times a second): nothing more.
        watched.keepUp(); watched.keepUp()
        #expect(redrawn.count == 1)
        #expect(watched.lastHoles == HolesDrawn(cut: [hole]))
    }
}
#endif
