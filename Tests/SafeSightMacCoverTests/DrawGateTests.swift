// SPDX-License-Identifier: Apache-2.0
// An update exactly like the last one drawn is not drawn again; every other update is drawn at once. The judging hands
// over a plan for every frame the capture sends (about 30 a second in the virtual Mac), most of them the same.
import CoreGraphics
import Testing
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@MainActor @Suite struct DrawGateTests {
    let a = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))

    func judged() -> (Rig, Int) {
        let r = Rig(DisplayList(displays: [a], main: 1))
        r.coordinator.start()
        r.coordinator.restartNow()
        let g = r.os.lastRestart
        r.coordinator.deliver(.clear(a), generation: g)
        return (r, g)
    }

    func with(_ rects: [CGRect]) -> CoverPlan { CoverPlan(display: a, items: rects.map { CoverItem(rect: $0, kind: .plain) }) }

    /// Thirty identical empty updates in a second: drawn once.
    @Test func identicalEmptyUpdatesAreDrawnOnce() {
        let (r, g) = judged()
        let before = r.presenter.applied.count
        for _ in 0..<30 { r.os.now += 1.0 / 30; r.coordinator.deliver(.clear(a), generation: g) }
        #expect(r.presenter.applied.count == before, "nothing new to draw: \(r.presenter.applied.count - before) drawn")
    }

    /// An update that adds a cover, moves one, changes its kind or lifts one is drawn at once, however soon after the last.
    @Test func everyChangeIsDrawnAtOnce() {
        let (r, g) = judged()
        let one = CGRect(x: 10, y: 10, width: 40, height: 40)
        r.coordinator.deliver(.clear(a), generation: g)
        r.coordinator.deliver(with([one]), generation: g)
        #expect(r.presenter.last.first?.items.map(\.rect) == [one], "a cover added is drawn at once")
        r.coordinator.deliver(with([one.offsetBy(dx: 1, dy: 0)]), generation: g)
        #expect(r.presenter.last.first?.items.map(\.rect) == [one.offsetBy(dx: 1, dy: 0)], "a cover moved by one point is drawn at once")
        var blurred = with([one.offsetBy(dx: 1, dy: 0)])
        blurred.items[0].kind = .blur(BlurTile(columns: 1, rows: 1, rgba: [1, 2, 3, 255]))
        r.coordinator.deliver(blurred, generation: g)
        #expect(r.presenter.last.first == blurred, "a change of kind is drawn at once")
        r.coordinator.deliver(with([one.offsetBy(dx: 1, dy: 0), one.offsetBy(dx: 100, dy: 0)]), generation: g)
        #expect(r.presenter.last.first?.items.count == 2, "a second cover is drawn at once")
        r.coordinator.deliver(.clear(a), generation: g)
        #expect(r.presenter.last.first?.items.isEmpty == true, "and so is lifting them")
    }

    /// An identical update with covers on screen is still drawn every quarter second (the canvases are brought to the front
    /// of their level then), never more often than the updates come.
    @Test func identicalCoversAreDrawnAgainEveryQuarterSecond() {
        let (r, g) = judged()
        let plan = with([CGRect(x: 10, y: 10, width: 40, height: 40)])
        r.coordinator.deliver(plan, generation: g)
        let before = r.presenter.applied.count
        for _ in 0..<60 { r.os.now += 1.0 / 30; r.coordinator.deliver(plan, generation: g) }
        let drawn = r.presenter.applied.count - before
        #expect(drawn >= 7 && drawn <= 9, "about four a second over two seconds: \(drawn)")
    }

    /// A plan with a password prompt's hole is drawn every time: the hole is checked against the window list at every drawing.
    @Test func aPlanWithAPromptsHoleIsAlwaysDrawn() {
        let (r, g) = judged()
        var plan = with([CGRect(x: 0, y: 0, width: 300, height: 200)])
        plan.promptHoles = [CGRect(x: 100, y: 50, width: 80, height: 60)]
        let before = r.presenter.applied.count
        for _ in 0..<10 { r.os.now += 0.01; r.coordinator.deliver(plan, generation: g) }
        #expect(r.presenter.applied.count - before == 10)
    }

    /// Urgent updates (a display change, the notice, a fault) are always drawn.
    @Test func urgentUpdatesAreAlwaysDrawn() {
        let (r, _) = judged()
        let before = r.presenter.applied.count
        r.coordinator.present(urgent: true)
        r.coordinator.present(urgent: true)
        #expect(r.presenter.applied.count - before == 2)
    }

    /// After the canvases were taken off some other way (the emergency quit), the next update is drawn even if it is the same.
    @Test func afterTheCanvasesWereClearedTheNextUpdateIsDrawn() {
        let (r, g) = judged()
        let plan = with([CGRect(x: 10, y: 10, width: 40, height: 40)])
        r.coordinator.deliver(plan, generation: g)
        r.coordinator.presenterCleared()
        let before = r.presenter.applied.count
        r.coordinator.deliver(plan, generation: g)
        #expect(r.presenter.applied.count - before == 1)
    }

    /// The same, after the lock screen took the canvases off.
    @Test func afterTheLockScreenTheNextUpdateIsDrawn() {
        let (r, g) = judged()
        let plan = with([CGRect(x: 10, y: 10, width: 40, height: 40)])
        r.coordinator.deliver(plan, generation: g)
        r.os.state = SystemState(displaysAsleep: false, sessionOnConsole: true, screenLocked: true, lockScreenUp: true)
        r.coordinator.tick()
        #expect(r.presenter.removed >= 1)
        r.os.state = SystemState(displaysAsleep: false, sessionOnConsole: true)
        r.coordinator.tick()
        let before = r.presenter.applied.count
        r.coordinator.deliver(.clear(a), generation: g)
        #expect(r.presenter.applied.count - before == 1 || r.presenter.last.allSatisfy { $0.wholeDisplay != nil }, "drawn (or still covered whole after the lock)")
    }

    /// An update left out is still checked against the screen at once, every time: a canvas the system hid (a switch of
    /// Spaces, say) is shown again at the next update, as before, not only at the next one drawn.
    @Test func everyUpdateLeftOutIsCheckedAgainstTheScreen() {
        let (r, g) = judged()
        let plan = with([CGRect(x: 10, y: 10, width: 40, height: 40)])
        r.coordinator.deliver(plan, generation: g)
        let drawn = r.presenter.applied.count, kept = r.presenter.keptUp
        for _ in 0..<5 { r.os.now += 0.01; r.coordinator.deliver(plan, generation: g) }
        #expect(r.presenter.applied.count == drawn, "nothing new drawn")
        #expect(r.presenter.keptUp - kept == 5, "but every one checked against the screen: \(r.presenter.keptUp - kept)")
    }

    /// The watched presenter passes the check on to the canvases and tells the watchdog a cover may be up while it runs,
    /// but does not count it as an update drawn.
    @Test func theWatchedPresenterPassesTheCheckOn() {
        let inner = RecordingPresenter()
        let watched = WatchedPresenter(inner)
        var drawnHeard = 0, shown: [Bool] = []
        watched.onDrawn = { _ in drawnHeard += 1 }
        watched.onCoversShown = { shown.append($0) }
        watched.apply([with([CGRect(x: 10, y: 10, width: 40, height: 40)])])
        drawnHeard = 0; shown = []
        watched.keepUp()
        #expect(inner.keptUp == 1 && drawnHeard == 0 && shown == [true, true], "\(shown)")
    }
}
