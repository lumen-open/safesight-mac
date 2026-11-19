// SPDX-License-Identifier: Apache-2.0
// The cover coordinator on the main thread: a canvas for every display the OS lists, every display covered the moment
// macOS announces a change, a new display covered before any stream starts, and no plan from before a change shown
// after it. The presenter is a fake that records what it is asked to draw and the OS's lists are faked: no window is
// shown, no display is touched and nothing is captured.
import AppKit
import CoreGraphics
import Testing
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@MainActor final class RecordingPresenter: CoverPresenter {
    var applied: [[CoverPlan]] = []
    var removed = 0
    func apply(_ plans: [CoverPlan]) { applied.append(plans) }
    func removeAll() { removed += 1 }
    var last: [CoverPlan] { applied.last ?? [] }
    /// Why display `id` is covered whole in the last drawing (nil: it shows its judged plan).
    func whole(_ id: UInt32) -> FaultCause? { last.first { $0.display.id == id }?.wholeDisplay }
    func drawn(_ id: UInt32) -> Bool { last.contains { $0.display.id == id } }
}

/// The OS as the coordinator sees it: its display lists, a clock, and what the coordinator asked of the app.
@MainActor final class FakeOS {
    var list: DisplayList?
    var now: TimeInterval = 100
    var flushes = 0, restarts = 0, topUps = 0
    var judged: [UInt32] = []
    var required: [UInt32: Int] = [:]
}

@MainActor struct Rig {
    let presenter: RecordingPresenter
    let os: FakeOS
    let generations: GenerationCounter
    let coordinator: CoverCoordinator

    init(_ l: DisplayList) {
        let presenter = RecordingPresenter(), os = FakeOS(), generations = GenerationCounter()
        os.list = l
        let c = CoverCoordinator(presenter: presenter, generations: generations, read: { _ in os.list },
                                 flush: { os.flushes += 1 }, clock: { os.now })
        c.restartCapture = { os.restarts += 1 }
        c.topUpCapture = { os.topUps += 1 }
        c.judging = { j, r in os.judged = j; os.required = r }
        self.presenter = presenter; self.os = os; self.generations = generations; self.coordinator = c
    }

    func settle() { os.now += CoverCoordinator.settle; coordinator.tick() }
}

@MainActor @Suite struct CoverCoordinatorTests {
    let a = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
    let b = DisplayDescriptor(id: 2, bounds: CGRect(x: 300, y: 0, width: 300, height: 200))
    let c3 = DisplayDescriptor(id: 3, bounds: CGRect(x: 600, y: 0, width: 300, height: 200))

    func list(_ ds: [DisplayDescriptor]) -> DisplayList { DisplayList(displays: ds, main: 1) }

    /// Started, capture started once, and every display judged clean by its first stream.
    func judgedRig(_ ds: [DisplayDescriptor]) -> (Rig, Int) {
        let r = Rig(list(ds))
        r.coordinator.start()
        r.coordinator.restartNow()
        let g = r.generations.next()
        for d in ds { r.coordinator.deliver(.clear(d), generation: g) }
        return (r, g)
    }

    @Test func atStartEveryDisplayIsCoveredWholeBeforeAnyStreamStarts() {
        let r = Rig(list([a, b]))
        r.coordinator.start()
        #expect(r.os.restarts == 0, "capture starts later, when the detector is ready")
        #expect(r.presenter.last.map(\.display.id) == [1, 2], "a canvas for every display")
        #expect(r.presenter.last.allSatisfy { $0.wholeDisplay == .notYetJudged })
        #expect(r.os.flushes >= 1, "pushed to the screen at once")
        #expect(r.os.judged == [1, 2] && r.os.required == [1: 1, 2: 1])
    }

    @Test func theBeginCallbackCoversEveryDisplayBeforeItReturns() {
        let (r, g) = judgedRig([a, b])
        #expect(r.presenter.last.allSatisfy { $0.wholeDisplay == nil })
        let reconfiguration = DisplayReconfiguration { change, _ in
            switch change {
            case .willChange: r.coordinator.willChange()
            case .didChange: r.coordinator.didChange()
            }
        }
        let info = Unmanaged.passUnretained(reconfiguration).toOpaque()
        let drawnBefore = r.presenter.applied.count, flushesBefore = r.os.flushes
        // macOS calls the registered C callback with the begin flag, on the main thread, before applying the change.
        DisplayReconfiguration.callback(2, [.beginConfigurationFlag], info)
        #expect(r.presenter.applied.count > drawnBefore, "drawn inside the callback, before it returned")
        #expect(r.presenter.last.allSatisfy { $0.wholeDisplay == .displayChanging }, "every display")
        #expect(r.os.flushes > flushesBefore, "and pushed to the screen at once")
        // A plan judged before the change and arriving now lowers nothing.
        r.coordinator.deliver(.clear(a), generation: g)
        #expect(r.presenter.whole(1) == .displayChanging)
        // The change is applied: a third display. It gets its canvas, covered whole, before any stream starts.
        r.os.list = list([a, b, c3])
        DisplayReconfiguration.callback(3, [.addFlag], info)
        #expect(r.presenter.last.map(\.display.id) == [1, 2, 3])
        #expect(r.presenter.last.allSatisfy { $0.wholeDisplay != nil })
        #expect(r.os.restarts == 1, "capture restarts only once the change has settled")
        r.settle()
        #expect(r.os.restarts == 2)
        // The new streams' first judged frames lower displays 1 and 2; display 3 is past the limit.
        let g2 = r.generations.next()
        for d in [a, b, c3] { r.coordinator.deliver(.clear(d), generation: g2) }
        #expect(r.presenter.whole(1) == nil && r.presenter.whole(2) == nil)
        #expect(r.presenter.whole(3) == .tooManyDisplays)
        withExtendedLifetime(reconfiguration) {}
    }

    @Test func aNewDisplayStaysCoveredUntilItsOwnFirstJudgedFrame() {
        let (r, g) = judgedRig([a])
        r.os.list = list([a, b])
        r.coordinator.didChange()
        #expect(r.presenter.whole(1) == .displayChanging && r.presenter.whole(2) == .displayChanging)
        r.coordinator.deliver(.clear(b), generation: g)
        #expect(r.presenter.whole(2) != nil, "a plan from a stream started before it was attached")
        r.settle()
        let g2 = r.generations.next()
        r.coordinator.deliver(.clear(a), generation: g2)
        #expect(r.presenter.whole(1) == nil)
        #expect(r.presenter.whole(2) == .displayChanging, "the new display waits for its own first judged frame")
        r.coordinator.deliver(.clear(b), generation: g2)
        #expect(r.presenter.whole(2) == nil)
    }

    @Test func aDisplayNobodyAnnouncedIsCoveredAtTheNextDrawing() {
        let (r, g) = judgedRig([a])
        r.os.list = list([a, b])                           // no callback, no notification
        r.coordinator.deliver(.clear(a), generation: g)    // every drawing reads the lists first
        #expect(r.presenter.whole(2) == .displayChanging)
        #expect(r.presenter.whole(1) == .displayChanging, "handled like an announced change")
        #expect(r.coordinator.restartDue != nil)
    }

    @Test func theListsAreReadAgainOnEveryTick() {
        let (r, _) = judgedRig([a])
        r.os.list = list([a, b])
        r.coordinator.tick()
        #expect(r.presenter.drawn(2) && r.presenter.whole(2) != nil)
    }

    @Test func anAnnouncedChangeThatNeverFinishesIsTreatedAsFinished() {
        let (r, _) = judgedRig([a, b])
        r.coordinator.willChange()
        r.os.now += CoverCoordinator.unfinishedChange - 0.5
        r.coordinator.tick()
        #expect(r.coordinator.coverage.hold != nil)
        r.os.now += 1
        r.coordinator.tick()
        #expect(r.coordinator.coverage.hold == nil)
        #expect(r.presenter.last.allSatisfy { $0.wholeDisplay != nil }, "still covered until judged")
        r.settle()
        #expect(r.os.restarts == 2)
    }

    @Test func sleepHoldsEveryCoverUntilWake() {
        let (r, _) = judgedRig([a, b])
        r.coordinator.willChange(.sleep)
        r.os.now += 3600
        r.coordinator.tick()
        #expect(r.coordinator.coverage.hold == .displayChanging)
        r.coordinator.deliver(.clear(a), generation: r.generations.next())
        #expect(r.presenter.whole(1) != nil)
        #expect(r.os.restarts == 1, "no restart while asleep")
        r.coordinator.didChange(.sleep)
        r.settle()
        #expect(r.os.restarts == 2)
    }

    @Test func aDisplayChangeWhileGoingToSleepDoesNotEndTheSleepHold() {
        let (r, _) = judgedRig([a, b])
        r.coordinator.willChange(.sleep)
        r.coordinator.willChange(.change)
        r.os.list = list([a])
        r.coordinator.didChange(.change)
        r.os.now += 60
        r.coordinator.tick()
        #expect(r.coordinator.coverage.hold != nil, "still held for sleep")
        r.coordinator.deliver(.clear(a), generation: r.generations.next())
        #expect(r.presenter.whole(1) != nil)
        r.coordinator.didChange(.sleep)
        #expect(r.coordinator.coverage.hold == nil)
        #expect(r.presenter.whole(1) == .displayChanging, "covered until judged after wake")
    }

    @Test func aDisplayWithNoStreamIsRetriedAFewTimesAndStaysCovered() {
        // Display 2 is listed, but no stream ever starts for it; display 1 is judged.
        let r = Rig(list([a, b]))
        r.coordinator.start()
        r.coordinator.restartNow()
        r.coordinator.deliver(.clear(a), generation: r.generations.next())
        for (i, delay) in CoverCoordinator.topUpDelays.enumerated() {
            r.coordinator.fault(2, .noStream, generation: nil)
            #expect(r.presenter.whole(2) == .noStream)
            r.os.now += delay
            r.coordinator.tick()
            #expect(r.os.topUps == i + 1)
        }
        r.coordinator.fault(2, .noStream, generation: nil)
        r.os.now += 60
        r.coordinator.tick()
        #expect(r.os.topUps == CoverCoordinator.topUpDelays.count, "then not again until the next change")
        #expect(r.presenter.whole(2) == .noStream && r.presenter.whole(1) == nil)
    }

    @Test func whenTheListsCannotBeReadEveryDisplayStaysCovered() {
        let (r, _) = judgedRig([a, b])
        r.os.list = nil
        r.coordinator.tick()
        #expect(r.presenter.last.map(\.display.id) == [1, 2], "the last known displays keep their canvases")
        #expect(r.presenter.last.allSatisfy { $0.wholeDisplay != nil })
    }

    @Test func theJudgingQueueIsToldWhatToJudgeCountedFromTheOSLists() {
        let (r, _) = judgedRig([a, b, c3])
        #expect(r.os.judged == [1, 2])
        let before = r.os.required
        r.coordinator.didChange()
        #expect(r.os.required.allSatisfy { $0.value > (before[$0.key] ?? .max) }, "every display's required generation was raised")
    }

    @Test func tryAgainKeepsEveryDisplayCoveredWhileItRestarts() {
        let (r, _) = judgedRig([a, b])
        r.coordinator.restart()
        #expect(r.presenter.removed == 0, "no cover comes down")
        #expect(r.presenter.last.allSatisfy { $0.wholeDisplay == .notYetJudged })
    }

    @Test func stopRemovesEveryCoverAndLatePlansDrawNothing() {
        let (r, g) = judgedRig([a, b])
        r.coordinator.stop()
        #expect(r.presenter.removed == 1)
        let drawn = r.presenter.applied.count
        r.coordinator.deliver(.clear(a), generation: g)
        r.coordinator.willChange()
        r.coordinator.didChange()
        r.coordinator.tick()
        #expect(r.presenter.applied.count == drawn)
    }

    @Test func aFailedDetectorCoversADisplayAttachedLater() {
        let (r, _) = judgedRig([a])
        r.coordinator.detectorFailed()
        r.os.list = list([a, b])
        r.coordinator.didChange()
        #expect(r.presenter.last.map(\.display.id) == [1, 2])
        #expect(r.presenter.last.allSatisfy { $0.wholeDisplay == .detectorUnavailable })
    }
}
