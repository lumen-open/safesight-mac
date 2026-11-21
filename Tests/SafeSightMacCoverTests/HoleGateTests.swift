// SPDX-License-Identifier: Apache-2.0
// A password prompt's hole opens only once the plain cover behind it has been drawn (HoleGate): first the backing over
// the rectangle with the covers still over it, then the hole. A hole that moves is covered again until its backing has
// moved too.
import CoreGraphics
import Foundation
import Testing
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

/// The frames of prompts standing at `rects` (windows 50, 51, ... of process 900), each with its one hole.
func promptFrames(_ rects: [CGRect], uncut: Bool = false) -> [PromptFrame] {
    rects.enumerated().map { i, r in PromptFrame(number: UInt32(50 + i), ownerPID: 900, frame: r, holes: [r], uncut: uncut ? [r] : []) }
}

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

    /// Around a whole-display cover every hole cuts it, whatever the plan marks as cutting nothing: each still waits for
    /// its backing.
    @Test func aWholeDisplayCoverIsCutByEveryHoleWhateverIsMarkedUncut() {
        let whole = CoverPlan(display: d, items: [], wholeDisplay: .windowAboveCovers, promptHoles: [hole],
                              promptFrames: promptFrames([hole], uncut: true))
        #expect(CoverLayout.cuttingPromptRects(whole) == [hole])
        let first = HoleGate().gate([whole])
        #expect(first.heldBack && first.plans[0].promptHoles.isEmpty && covered(first.plans[0], hole), "closed until its backing is up")
    }

    @Test func plansWithoutHolesAreUntouched() {
        let g = HoleGate()
        let plain = CoverPlan(display: d, items: [CoverItem(rect: hole, kind: .plain)])
        let r = g.gate([plain])
        #expect(!r.heldBack && r.plans == [plain])
    }
}

/// The window server's own view of a backing decides, not AppKit's: a backing still fading or growing into place, or
/// smaller than its hole, does not count. The numbers are a backing caught mid-animation on a test virtual Mac.
@Suite struct BackingCheckTests {
    let hole = CGRect(x: 382, y: 122, width: 260, height: 312)
    func info(alpha: Double = 1, bounds: CGRect? = nil, layer: Int = CoverLevel.behindPrompt, onScreen: Bool = true) -> [String: Any] {
        [kCGWindowAlpha as String: NSNumber(value: alpha), kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowIsOnscreen as String: NSNumber(value: onScreen),
         kCGWindowBounds as String: (bounds ?? hole).dictionaryRepresentation as NSDictionary]
    }

    @Test func onlyAnOpaqueBackingOnScreenAtItsLevelCoveringTheWholeHoleStands() {
        #expect(BackingCheck.stands(info(), covering: hole))
        #expect(BackingCheck.stands(info(bounds: hole.insetBy(dx: -2, dy: -2)), covering: hole), "larger is fine")
        for a in [0.017853617668151855, 0.004860520362854004, 0.6591799855232239, 0.0003571510314941406, 0.999] {
            #expect(!BackingCheck.stands(info(alpha: a), covering: hole), "alpha \(a)")
        }
        for b in [CGRect(x: 384, y: 125, width: 256, height: 306), CGRect(x: 383, y: 123, width: 258, height: 310)] {
            #expect(!BackingCheck.stands(info(bounds: b), covering: hole), "smaller than the hole: \(b)")
        }
        #expect(!BackingCheck.stands(info(onScreen: false), covering: hole))
        #expect(!BackingCheck.stands(info(layer: CoverLevel.canvas), covering: hole))
        #expect(!BackingCheck.stands(nil, covering: hole))
        var missing = info(); missing[kCGWindowAlpha as String] = nil
        #expect(!BackingCheck.stands(missing, covering: hole))
    }

    /// The real backing panel asks the window server about itself, and AppKit's word is not enough: with the window
    /// server's entry saying it is still fading in (or missing), `place` says it is not up. Run on a real panel, ordered
    /// in far off every display (it needs a window server session, as `swift test` on a Mac has), its entry stood in.
    @MainActor @Test func theRealBackingPanelTrustsOnlyTheWindowServer() {
        let off = CGRect(x: -30000, y: -30000, width: 40, height: 30)
        let p = CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { p.hide() }
        let holeHere = CGRect(x: -30000, y: 30000 - 30, width: 40, height: 30)
        func entry(_ alpha: Double) -> [String: Any] {
            [kCGWindowAlpha as String: NSNumber(value: alpha), kCGWindowLayer as String: NSNumber(value: CoverLevel.behindPrompt),
             kCGWindowIsOnscreen as String: NSNumber(value: true), kCGWindowBounds as String: holeHere.dictionaryRepresentation as NSDictionary]
        }
        var asked = 0
        p.serverInfo = { _ in asked += 1; return entry(0.0178) }
        #expect(!p.place(off, covering: holeHere, theme: .light), "fading in: not up")
        #expect(asked > 0, "the window server was asked")
        p.serverInfo = { _ in nil }
        #expect(!p.place(off, covering: holeHere, theme: .light), "not listed: not up")
        p.serverInfo = { _ in entry(1) }
        #expect(p.place(off, covering: holeHere, theme: .light) == p.isVisible, "in place and opaque: up (when AppKit shows it)")
        #expect(p.animationBehavior == .none && p.alphaValue == 1 && p.isOpaque)
    }

    /// Every cover window, the backing included, is never animated in or out by AppKit.
    @MainActor @Test func coverWindowsAreNeverAnimated() {
        let p = CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(p.animationBehavior == .none)
        #expect(p.alphaValue == 1)
    }
}

/// Just before drawing, a hole stays open only while the window list read then still holds it.
@Suite struct HoleConfirmTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let hole = CGRect(x: 200, y: 120, width: 200, height: 160)
    let app = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    func prompt(_ r: CGRect? = nil, verified: Bool = true, alpha: Double = 1) -> WindowInfo {
        WindowInfo(number: 50, ownerPID: 900, layer: PasswordPrompt.level, bounds: r ?? hole, alpha: alpha, passwordPrompt: verified)
    }
    var plan: CoverPlan {
        CoverPlan(display: d, items: [CoverItem(rect: CGRect(x: 0, y: 0, width: 600, height: 120), kind: .plain)],
                  promptHoles: [hole], promptFrames: promptFrames([hole]))
    }
    func list(_ w: [WindowInfo]) -> WindowSnapshot { WindowSnapshot(windows: w, time: 0) }
    func closed(_ p: CoverPlan) -> Bool {
        p.promptHoles.isEmpty && (p.wholeDisplay != nil || p.items.contains { $0.rect == hole && $0.kind == .plain })
    }

    @Test func aHoleStaysOpenWhileItsPromptStandsWhereThePlanSawIt() {
        let out = HoleGate.confirm([plan], windows: list([prompt(), app]), ignoring: [42])
        #expect(out == [plan])
        // This app's own windows (the covers over everything, the backing behind) never count.
        let own = [WindowInfo(number: 7, ownerPID: 42, layer: CoverLevel.canvas, bounds: d.bounds), prompt(),
                   WindowInfo(number: 8, ownerPID: 42, layer: CoverLevel.behindPrompt, bounds: hole), app]
        #expect(HoleGate.confirm([plan], windows: list(own), ignoring: [42]) == [plan])
    }

    @Test func aHoleClosesWhenItsPromptWentMovedOrChangedOrTheListCannotBeRead() {
        let cases: [(String, WindowSnapshot?)] = [
            ("went", list([app])),
            ("moved", list([prompt(hole.offsetBy(dx: 4, dy: 0)), app])),
            ("grew", list([prompt(hole.insetBy(dx: -10, dy: -10)), app])),
            ("fading out", list([prompt(alpha: 0.4), app])),
            ("owner not checked", list([prompt(verified: false), app])),
            ("a window came in front", list([WindowInfo(number: 9, ownerPID: 600, layer: 3, bounds: CGRect(x: 250, y: 150, width: 50, height: 50)), prompt(), app])),
            ("a window behind at the backing's level", list([prompt(), WindowInfo(number: 9, ownerPID: 600, layer: CoverLevel.behindPrompt, bounds: d.bounds), app])),
            ("unreadable", .unreadable(time: 0)),
            ("not read", nil),
        ]
        for (why, w) in cases {
            let out = HoleGate.confirm([plan], windows: w, ignoring: [42])
            #expect(closed(out[0]), "\(why): \(out[0])")
        }
        // Another window at exactly the same place (a new request, say) was never judged: closed.
        let other = WindowInfo(number: 51, ownerPID: 900, layer: PasswordPrompt.level, bounds: hole, passwordPrompt: true)
        #expect(closed(HoleGate.confirm([plan], windows: list([other, app]), ignoring: [42])[0]), "same place, another window")
        let otherOwner = WindowInfo(number: 50, ownerPID: 901, layer: PasswordPrompt.level, bounds: hole, passwordPrompt: true)
        #expect(closed(HoleGate.confirm([plan], windows: list([otherOwner, app]), ignoring: [42])[0]), "same number, another process")
        // Prompt B, larger, contains closed prompt A's place: A's hole does not live on in B.
        let bigger = hole.insetBy(dx: -20, dy: -20)
        var two = plan
        two.promptFrames = [PromptFrame(number: 50, ownerPID: 900, frame: hole, holes: [hole]),
                            PromptFrame(number: 60, ownerPID: 900, frame: bigger, holes: [])]
        let b = WindowInfo(number: 60, ownerPID: 900, layer: PasswordPrompt.level, bounds: bigger, passwordPrompt: true)
        #expect(closed(HoleGate.confirm([two], windows: list([b, app]), ignoring: [42])[0]), "A went, B covers its place")
        // A plan with a hole but no frame for it never opens.
        var noFrame = plan; noFrame.promptFrames = []
        #expect(closed(HoleGate.confirm([noFrame], windows: list([prompt(), app]), ignoring: [42])[0]))
        // Around a whole-display cover the hole is taken out, so the whole cover covers it.
        var whole = plan; whole.wholeDisplay = .windowAboveCovers; whole.items = []
        let w = HoleGate.confirm([whole], windows: list([app]), ignoring: [42])[0]
        #expect(w.promptHoles.isEmpty && w.wholeDisplay != nil)
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
        /// Where the window list shows a password prompt.
        var promptsAt: [CGRect] = []
        /// Whether what was drawn last has been sent to the screen (`CATransaction.flush`) yet.
        var flushed = true
        /// How often the window list was read.
        var reads = 0
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
        /// What the window server would say: false while the backing is still fading or growing into place.
        var serverShowsIt = true
        init(_ w: World) { world = w }
        func place(_ f: CGRect, covering hole: CGRect, theme: CoverTheme) -> Bool {
            if frame != f { frame = f; world.check("moved a backing") }
            shown = true
            return stands(covering: hole)
        }
        func stands(covering hole: CGRect) -> Bool { shown && serverShowsIt && frame.contains(hole) }
        func hide() {
            if !world.flushed { world.violations.append("took a backing down before the covers drawn over it reached the screen") }
            shown = false; world.check("took a backing down")
        }
    }

    /// A password prompt standing at each of `rects` in the window list.
    static func prompts(_ rects: [CGRect]) -> WindowSnapshot {
        WindowSnapshot(windows: rects.enumerated().map { i, r in
            WindowInfo(number: UInt32(50 + i), ownerPID: 900, layer: PasswordPrompt.level, bounds: r, passwordPrompt: true)
        } + [WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))], time: 0)
    }

    func setUp() -> (World, BehindPrompt) {
        let w = World()
        let b = BehindPrompt(make: { let p = FakePanel(w); w.panels.append(p); return p },
                             nextTurn: { w.turns.append($0) }, toCocoa: { $0 }, windows: { w.reads += 1; return Self.prompts(w.promptsAt) },
                             watchLater: { _, _ in }, flush: { w.flushed = true })
        return (w, b)
    }

    /// Draws `holes` through the backings, the canvas recording what it cuts, then runs the main loop's next turns.
    /// The window list shows a prompt at each hole.
    func show(_ holes: [CGRect], _ w: World, _ b: BehindPrompt) {
        w.promptsAt = holes
        let plan = CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: holes, promptFrames: promptFrames(holes))
        func draw(_ plans: [CoverPlan]) {
            // A hole is cut when no plain cover was put back over exactly it.
            w.cut = Set(plans.flatMap { p in p.promptHoles.filter { r in !p.items.contains { $0.rect == r } }.map { HoleGate.Hole(display: p.display.id, rect: $0) } })
            w.flushed = false
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

    /// A plan is made from a window list read before judging began. If the prompt went since, the drawing never cuts its
    /// hole, and its backing comes down only after the covers are back over its place.
    @Test func aPlanMadeBeforeThePromptWentNeverCutsItsHole() {
        let (w, b) = setUp()
        let a = CGRect(x: 100, y: 100, width: 150, height: 120)
        show([a], w, b)
        #expect(w.cut == [HoleGate.Hole(display: 1, rect: a)])
        // The prompt goes; a plan from before that still has its hole arrives.
        w.promptsAt = []
        let stale = CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: [a], promptFrames: promptFrames([a]))
        func draw(_ plans: [CoverPlan]) {
            w.cut = Set(plans.flatMap { p in p.promptHoles.filter { r in !p.items.contains { $0.rect == r } }.map { HoleGate.Hole(display: p.display.id, rect: $0) } })
            w.flushed = false
            w.check("drew the covers")
        }
        func apply(_ plans: [CoverPlan]) { b.apply(plans, theme: .light, draw: draw, again: apply) }
        apply([stale])
        #expect(w.cut.isEmpty, "covered in the same drawing")
        while !w.turns.isEmpty { w.turns.removeFirst()() }
        #expect(w.violations.isEmpty, "\(w.violations)")
        #expect(w.panels.allSatisfy { !$0.shown })
    }

    /// With no new plan at all, a cut hole is closed within one look of the window list after its prompt goes, and a
    /// backing that stops standing (still fading in, say) closes it the same way.
    @Test func aCutHoleIsWatchedAndClosesWhenItsPromptGoesOrItsBackingFails() {
        for failure in ["prompt went", "backing fading"] {
            let w = World()
            var watches: [(TimeInterval, BehindPrompt.Turn)] = []
            let b = BehindPrompt(make: { let p = FakePanel(w); w.panels.append(p); return p },
                                 nextTurn: { w.turns.append($0) }, toCocoa: { $0 }, windows: { Self.prompts(w.promptsAt) },
                                 watchLater: { d, f in watches.append((d, f)) }, flush: { w.flushed = true })
            let a = CGRect(x: 100, y: 100, width: 150, height: 120)
            var draws = 0
            func draw(_ plans: [CoverPlan]) {
                draws += 1
                w.cut = Set(plans.flatMap { p in p.promptHoles.filter { r in !p.items.contains { $0.rect == r } }.map { HoleGate.Hole(display: p.display.id, rect: $0) } })
                w.flushed = false
                w.check("drew the covers")
            }
            func apply(_ plans: [CoverPlan]) { b.apply(plans, theme: .light, draw: draw, again: apply) }
            w.promptsAt = [a]
            apply([CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: [a], promptFrames: promptFrames([a]))])
            while !w.turns.isEmpty { w.turns.removeFirst()() }
            #expect(w.cut == [HoleGate.Hole(display: 1, rect: a)])
            // Nothing changed yet: the watch looks, finds all well, and looks again; nothing is drawn.
            #expect(watches.count == 1 && watches[0].0 <= 0.05)
            let before = draws
            watches.removeFirst().1()
            #expect(draws == before && watches.count == 1)
            if failure == "prompt went" { w.promptsAt = [] } else { w.panels.forEach { $0.serverShowsIt = false } }
            watches.removeFirst().1()
            #expect(w.cut.isEmpty, "\(failure): closed by the watch itself")
            while !w.turns.isEmpty { w.turns.removeFirst()() }
            #expect(w.violations.isEmpty, "\(w.violations)")
            // Once nothing is cut, the watch stops.
            for (_, f) in watches { f() }
            #expect(w.cut.isEmpty)
        }
    }

    /// A backing the window server does not show yet as opaque and in place (AppKit said it is up) keeps its hole closed.
    @Test func aBackingTheWindowServerDoesNotShowInPlaceKeepsItsHoleClosed() {
        let w = World()
        let a = CGRect(x: 100, y: 100, width: 150, height: 120)
        var fading: FakePanel?
        let b2 = BehindPrompt(make: { let p = FakePanel(w); p.serverShowsIt = false; fading = p; w.panels.append(p); return p },
                              nextTurn: { w.turns.append($0) }, toCocoa: { $0 }, later: { _, f in w.turns.append(f) },
                              windows: { Self.prompts(w.promptsAt) }, watchLater: { _, _ in })
        w.promptsAt = [a]
        var cuts: [Set<HoleGate.Hole>] = []
        func draw(_ plans: [CoverPlan]) {
            let cut = Set(plans.flatMap { p in p.promptHoles.filter { r in !p.items.contains { $0.rect == r } }.map { HoleGate.Hole(display: p.display.id, rect: $0) } })
            cuts.append(cut)
        }
        func apply(_ plans: [CoverPlan]) { b2.apply(plans, theme: .light, draw: draw, again: apply) }
        apply([CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: [a], promptFrames: promptFrames([a]))])
        var turns = 0
        while !w.turns.isEmpty && turns < 50 { w.turns.removeFirst()(); turns += 1 }
        #expect(cuts.allSatisfy { $0.isEmpty }, "\(cuts)")
        // Once the window server shows it in place, the hole opens on a later drawing.
        fading?.serverShowsIt = true
        apply([CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: [a], promptFrames: promptFrames([a]))])
        while !w.turns.isEmpty && turns < 100 { w.turns.removeFirst()(); turns += 1 }
        #expect(cuts.last == [HoleGate.Hole(display: 1, rect: a)])
    }

    /// A prompt on a screen with nothing covered around it: its backing goes up, but nothing waits on it. The prompt is
    /// never covered (not while its backing goes up, not when the backing fails, not on any check), the window list is not
    /// read for it, and nothing watches it. When a cover then arrives that its hole cuts, that hole goes through the full
    /// gate: cut at once only if its backing already stood in place, held covered otherwise.
    @Test func aHoleThatCutsNothingIsNeverCoveredOrWatchedAndAHoleThatStartsCuttingIsGated() {
        for backingStands in [true, false] {
            let w = World()
            var watches = 0
            var made: [FakePanel] = []
            let b = BehindPrompt(make: { let p = FakePanel(w); p.serverShowsIt = backingStands; made.append(p); w.panels.append(p); return p },
                                 nextTurn: { w.turns.append($0) }, toCocoa: { $0 }, later: { _, _ in },
                                 windows: { w.reads += 1; return Self.prompts(w.promptsAt) },
                                 watchLater: { _, _ in watches += 1 }, flush: { w.flushed = true })
            let a = CGRect(x: 100, y: 100, width: 150, height: 120)
            var drawn: [CoverPlan] = []
            func draw(_ plans: [CoverPlan]) { drawn += plans; w.flushed = false }
            func apply(_ plans: [CoverPlan]) { b.apply(plans, theme: .light, draw: draw, again: apply) }
            w.promptsAt = [a]
            // Nothing covered around the prompt: the hole cuts nothing.
            let clean = CoverPlan(display: d, items: [], promptHoles: [a], promptFrames: promptFrames([a], uncut: true))
            for _ in 0..<3 { apply([clean]); while !w.turns.isEmpty { w.turns.removeFirst()() } }
            #expect(drawn.allSatisfy { $0 == clean }, "the prompt is never covered: \(drawn)")
            #expect(made.count == 1 && made[0].shown, "its backing is up")
            #expect(w.reads == 0 && watches == 0, "nothing reads the window list or watches for it")
            // A cover arrives that the hole now cuts.
            drawn = []
            let cutting = CoverPlan(display: d, items: [CoverItem(rect: CGRect(x: 0, y: 0, width: 600, height: 100), kind: .plain, source: .window(number: 1, ownerPID: 500))],
                                    promptHoles: [a], promptFrames: promptFrames([a]))
            apply([cutting])
            let first = drawn[0]
            let coveredOver = first.items.contains { $0.rect == a }
            #expect(coveredOver == !backingStands, "backing stands \(backingStands): \(first.items.map(\.rect))")
            #expect(w.reads >= 1, "a cutting hole is checked against the window list")
            #expect((watches > 0) == backingStands, "watched only while it actually cuts")
            while !w.turns.isEmpty { w.turns.removeFirst()() }
            #expect(w.violations.isEmpty, "\(w.violations)")
        }
    }

    /// When a hole closes, the covers drawn over it are sent to the screen before its backing is taken down.
    @Test func theCoversOverAClosedHoleReachTheScreenBeforeItsBackingComesDown() {
        let (w, b) = setUp()
        let a = CGRect(x: 100, y: 100, width: 150, height: 120)
        show([a], w, b)
        show([], w, b)
        #expect(w.panels.allSatisfy { !$0.shown })
        #expect(w.violations.isEmpty, "\(w.violations)")
    }

    final class Flaky: BackingPanel {
        var failuresLeft: Int
        init(_ n: Int) { failuresLeft = n }
        func place(_ f: CGRect, covering hole: CGRect, theme: CoverTheme) -> Bool {
            if failuresLeft > 0 { failuresLeft -= 1; return false }
            return true
        }
        func stands(covering hole: CGRect) -> Bool { failuresLeft == 0 }
        func hide() {}
    }

    /// A backing that cannot be drawn keeps its hole covered; it is tried again a few times, further apart, so an idle
    /// screen recovers on its own; one that never works stops being tried. No turn loops.
    @Test func aBackingThatCannotBeDrawnKeepsItsHoleClosedAndRecovers() {
        for (failures, recovers) in [(1, true), (2, true), (100, false)] {
            let w = World()
            var delays: [TimeInterval] = []
            let panel = Flaky(failures)
            let hole = CGRect(x: 100, y: 100, width: 150, height: 120)
            let b = BehindPrompt(make: { panel }, nextTurn: { w.turns.append($0) }, toCocoa: { $0 },
                                 later: { d, f in delays.append(d); w.turns.append(f) }, windows: { Self.prompts([hole]) },
                                 watchLater: { _, _ in })
            let plan = CoverPlan(display: d, items: [CoverItem(rect: d.bounds, kind: .plain)], promptHoles: [hole], promptFrames: promptFrames([hole]))
            var cuts: [Set<HoleGate.Hole>] = []
            func draw(_ plans: [CoverPlan]) {
                let cut = Set(plans.flatMap { p in p.promptHoles.filter { r in !p.items.contains { $0.rect == r } }.map { HoleGate.Hole(display: p.display.id, rect: $0) } })
                cuts.append(cut)
            }
            func apply(_ plans: [CoverPlan]) { b.apply(plans, theme: .light, draw: draw, again: apply) }
            apply([plan])
            #expect(cuts.first == [], "covered while its backing cannot be drawn")
            var turns = 0
            while !w.turns.isEmpty && turns < 50 { w.turns.removeFirst()(); turns += 1 }
            #expect(turns < 50, "no turn loops")
            #expect(delays.count <= BehindPrompt.retries, "\(delays)")
            #expect(delays == delays.sorted(), "further apart each time")
            #expect((cuts.last == [HoleGate.Hole(display: 1, rect: hole)]) == recovers, "failures \(failures): \(cuts)")
        }
    }
}
