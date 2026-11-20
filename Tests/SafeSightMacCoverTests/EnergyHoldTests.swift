// SPDX-License-Identifier: Apache-2.0
// Capture stops while nothing on screen is this session's to judge (the displays asleep, the Mac asleep, the screen
// locked, another session on the console), and starts again when that ends: every display covered whole meanwhile, and
// after, until a judged frame of a stream started after it. No screen is captured: the capture framework is a fake.
import CoreGraphics
import Foundation
import Testing
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@MainActor @Suite struct EnergyHoldTests {
    let a = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
    let x = DisplayDescriptor(id: 2, bounds: CGRect(x: 300, y: 0, width: 300, height: 200))

    func rig() async throws -> (LinkRig, FakeCapture, Int) {
        let capture = FakeCapture([1, 2])
        let r = LinkRig(DisplayList(displays: [a, x], main: 1), capture: capture)
        await r.begin()
        let g = try #require(capture.generation(of: 1))
        r.coordinator.deliver(.clear(a), generation: g)
        r.coordinator.deliver(.clear(x), generation: g)
        #expect(r.presenter.whole(1) == nil && r.presenter.whole(2) == nil)
        return (r, capture, g)
    }

    @Test(arguments: [HoldReason.displaysAsleep, .sleep, .session])
    func captureStopsWhileHeldAndStartsAgainCoveredUntilJudged(_ reason: HoldReason) async throws {
        let (r, capture, g1) = try await rig()
        if reason == .session { r.os.state.sessionOnConsole = false } else { r.os.state.displaysAsleep = true }
        r.coordinator.willChange(reason)
        let since = r.presenter.applied.count - 1
        await r.link.settled()
        #expect(capture.streams.allSatisfy { $0.closed }, "every stream stopped while held")
        let running = await r.link.scheduler!.running
        #expect(running.isEmpty)
        // Time passes while held: nothing starts a stream again.
        for _ in 0..<20 { r.os.now += 0.25; r.coordinator.tick() }
        await r.link.settled()
        #expect(capture.streams.count == 2, "no stream started while held")
        #expect(r.coveredSince(since, 1) && r.coveredSince(since, 2))
        // A frame of the old streams, late, lowers nothing.
        r.coordinator.deliver(.clear(a), generation: g1)
        #expect(r.presenter.whole(1) != nil)

        // Awake again: capture restarts once the change has settled; covered until a frame of the new streams is judged.
        r.os.state = SystemState(displaysAsleep: false, sessionOnConsole: true)
        r.coordinator.didChange(reason)
        // (A session switch also held for the lock screen: that hold ends on the next tick, as a wake of its own.)
        for _ in 0..<2 { r.os.now += CoverCoordinator.settle; r.coordinator.tick() }
        await r.link.settled()
        let g2 = try #require(capture.generation(of: 1))
        #expect(g2 > g1)
        let again = await r.link.scheduler!.running
        #expect(again.count == 2)
        r.coordinator.deliver(.clear(a), generation: g1)
        #expect(r.presenter.whole(1) != nil, "the old stream's frames never count after the wake")
        #expect(r.coveredSince(since, 1) && r.coveredSince(since, 2), "covered whole from the hold to the first judged frame")
        r.coordinator.deliver(.clear(a), generation: g2)
        #expect(r.presenter.whole(1) == nil)
        #expect(r.presenter.whole(2) != nil, "display 2 waits for its own judged frame")
    }

    @Test func theLockScreenSeenOnATickStopsCaptureToo() async throws {
        let (r, capture, _) = try await rig()
        r.os.state.screenLocked = true
        r.os.now += 0.25
        r.coordinator.tick()
        await r.link.settled()
        #expect(capture.streams.allSatisfy { $0.closed })
        r.os.state.screenLocked = false
        r.os.now += 1
        r.coordinator.tick()        // the lock is over: as a wake
        r.os.now += CoverCoordinator.settle
        r.coordinator.tick()
        await r.link.settled()
        let again = await r.link.scheduler!.running
        #expect(again.count == 2, "capture starts again after the lock")
        #expect(r.presenter.whole(1) != nil, "covered until judged")
    }

    @Test func anAnnouncedDisplayChangeDoesNotPauseCapture() async throws {
        let (r, capture, _) = try await rig()
        r.coordinator.willChange(.change)
        await r.link.settled()
        #expect(!capture.streams.contains { $0.closed }, "a display change restarts capture itself once settled")
    }

    @Test func aPauseOlderThanTheNewestStartIsIgnoredAndANewerStartUndoesIt() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        await s.start(only: [1, 2], generation: 5)
        await s.pause(generation: 4)
        #expect(await s.running.count == 2)
        await s.pause(generation: 6)
        #expect(await s.running.isEmpty)
        #expect(log.stopped == [Stop(display: 1, generation: 5, byItself: false), Stop(display: 2, generation: 5, byItself: false)])
        await s.topUp(only: [1, 2], generation: 6)
        #expect(await s.running.isEmpty, "a top-up no newer than the pause starts nothing")
        await s.start(only: [1, 2], generation: 7)
        #expect(await s.running == [1: 7, 2: 7])
    }
}
