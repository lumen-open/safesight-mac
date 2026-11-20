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

    // MARK: A slow first warm-up

    /// The models' warm-up ran past its limit (a detector failure) and ends well while the displays sleep, or at the lock
    /// screen: the failure is over, but the hold stays. Capture does not start until the hold ends, and every display stays
    /// covered whole until a frame of the new streams is judged.
    @Test(arguments: [HoldReason.displaysAsleep, .sleep, .locked])
    func aSlowWarmUpEndingDuringAHoldNeverStartsCapture(_ reason: HoldReason) async throws {
        let capture = FakeCapture([1, 2])
        let r = LinkRig(DisplayList(displays: [a, x], main: 1), capture: capture)
        r.coordinator.start()
        r.coordinator.detectorFailed()            // the warm-up deadline passed
        if reason == .locked {
            r.os.state.screenLocked = true
            r.os.now += 0.25
            r.coordinator.tick()
        } else {
            r.os.state.displaysAsleep = true
            r.coordinator.willChange(reason)
        }
        // The warm-up ends well: as the watcher does it.
        let watch = WarmUpWatch()
        watch.deadlinePassed(7)
        #expect(watch.ready(7, detectorFailed: true))
        r.coordinator.detectorRecovered()
        r.link.ready = true
        r.coordinator.restartNow()
        for _ in 0..<20 { r.os.now += 0.25; r.coordinator.tick() }
        await r.link.settled()
        #expect(capture.streams.isEmpty, "no capture during the hold")
        #expect(r.coordinator.coverage.hold != nil, "the hold is kept")
        #expect(r.presenter.applied.last?.allSatisfy { $0.wholeDisplay != nil } ?? true, "covered whole (or, at the lock screen, nothing drawn)")
        // The hold ends: capture starts, and the displays stay covered until judged.
        r.os.state = SystemState(displaysAsleep: false, sessionOnConsole: true)
        if reason != .locked { r.coordinator.didChange(reason) }
        for _ in 0..<3 { r.os.now += CoverCoordinator.settle; r.coordinator.tick() }
        await r.link.settled()
        let g = try #require(capture.generation(of: 1))
        #expect(r.presenter.whole(1) != nil && r.presenter.whole(2) != nil)
        r.coordinator.deliver(.clear(a), generation: g)
        #expect(r.presenter.whole(1) == nil)
    }

    @Test func aRealFailureAfterTheDeadlineStaysFailed() {
        let w = WarmUpWatch()
        #expect(w.ready(1, detectorFailed: false), "a warm-up within the limit")
        w.deadlinePassed(2)
        #expect(w.ready(2, detectorFailed: true), "past the limit, then ended well")
        w.deadlinePassed(3)
        w.failed(3)
        #expect(!w.ready(3, detectorFailed: true), "past the limit, then failed: stays failed")
        #expect(!w.ready(4, detectorFailed: true), "a failure with no deadline (the load itself failed) stays failed")
        w.deadlinePassed(5)
        #expect(!w.ready(6, detectorFailed: true), "only the load whose deadline passed may recover")
    }

    // MARK: Holds and capture, in awkward orders

    @Test func aPauseArrivingWhileAStartIsPartWayStopsWhatItStarts() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let gate = Gate()
        capture.openGate = gate
        let s = StreamScheduler(backend: capture, reports: log.reports)
        let start = Task { await s.start(only: [1, 2], generation: 5) }
        await gate.reached(1)
        await s.pause(generation: 6)
        await gate.open()
        await start.value
        #expect(await s.running.isEmpty, "nothing kept running after the pause")
        #expect(capture.streams.allSatisfy { $0.closed }, "the stream opened part-way was closed")
    }

    @Test func aDisplayChangeDuringSleepDoesNotStartCapture() async throws {
        let (r, capture, _) = try await rig()
        r.os.state.displaysAsleep = true
        r.coordinator.willChange(.displaysAsleep)
        await r.link.settled()
        let opened = capture.streams.count
        r.coordinator.willChange(.change)
        r.coordinator.didChange(.change)
        for _ in 0..<12 { r.os.now += CoverCoordinator.settle; r.coordinator.tick() }
        await r.link.settled()
        #expect(capture.streams.count == opened, "no stream while the displays sleep, display change or not")
        #expect(r.presenter.whole(1) != nil && r.presenter.whole(2) != nil)
    }

    /// The displays wake while the screen is still locked (the wake notice comes before the lock screen is seen gone):
    /// capture waits for the unlock.
    @Test func aWakeNoticeAtTheLockScreenWaitsForTheUnlock() async throws {
        let (r, capture, _) = try await rig()
        r.os.state = SystemState(displaysAsleep: true, sessionOnConsole: true, screenLocked: true)
        r.coordinator.willChange(.displaysAsleep)
        await r.link.settled()
        let opened = capture.streams.count
        r.os.state.displaysAsleep = false
        r.coordinator.didChange(.displaysAsleep)
        for _ in 0..<8 { r.os.now += CoverCoordinator.settle; r.coordinator.tick() }
        await r.link.settled()
        #expect(capture.streams.count == opened, "still locked: no capture")
        r.os.state.screenLocked = false
        for _ in 0..<3 { r.os.now += CoverCoordinator.settle; r.coordinator.tick() }
        await r.link.settled()
        #expect(capture.streams.count > opened, "unlocked: capture starts")
        #expect(r.presenter.whole(1) != nil, "covered until judged")
    }
}

