// SPDX-License-Identifier: Apache-2.0
// Capture streams on request, and their link to the cover coordinator, with a capture framework the test controls:
// which displays it lists, which streams fail, and gates that hold a request part-way so a display change or a pause
// can come in between. No screen is captured: the fake streams carry no frames, and the test hands the coordinator the
// plan a judged frame of a given stream generation would give.
import CoreGraphics
import Foundation
import Testing
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

/// Holds whoever passes until opened.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func pass() async {
        arrivals += 1
        let due = watchers.filter { $0.count <= arrivals }
        watchers.removeAll { $0.count <= arrivals }
        due.forEach { $0.continuation.resume() }
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let w = waiting
        waiting = []
        w.forEach { $0.resume() }
    }

    /// Returns once `n` callers have reached the gate.
    func reached(_ n: Int) async {
        if arrivals >= n { return }
        await withCheckedContinuation { watchers.append((n, $0)) }
    }
}

enum FakeCaptureError: Error { case cannotList, cannotOpen }

/// A capture framework the test controls.
final class FakeCapture: CaptureBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var state: (displays: [UInt32], failing: Set<UInt32>, stopAtOnce: Set<UInt32>, listingFails: Bool, listGate: Gate?, openGate: Gate?)
    private var made: [FakeStream] = []

    init(_ displays: [UInt32]) { state = (displays, [], [], false, nil, nil) }

    var displays: [UInt32] { get { lock.withLock { state.displays } } set { lock.withLock { state.displays = newValue } } }
    /// Displays whose stream fails to start.
    var failing: Set<UInt32> { get { lock.withLock { state.failing } } set { lock.withLock { state.failing = newValue } } }
    /// Displays whose stream stops by itself while it is starting.
    var stopAtOnce: Set<UInt32> { get { lock.withLock { state.stopAtOnce } } set { lock.withLock { state.stopAtOnce = newValue } } }
    var listingFails: Bool { get { lock.withLock { state.listingFails } } set { lock.withLock { state.listingFails = newValue } } }
    var listGate: Gate? { get { lock.withLock { state.listGate } } set { lock.withLock { state.listGate = newValue } } }
    var openGate: Gate? { get { lock.withLock { state.openGate } } set { lock.withLock { state.openGate = newValue } } }
    var streams: [FakeStream] { lock.withLock { made } }
    var opened: [(display: UInt32, generation: Int)] { streams.map { ($0.display, $0.generation) } }
    /// The generation of the newest stream opened for a display.
    func generation(of id: UInt32) -> Int? { opened.last { $0.display == id }?.generation }

    func list() async throws -> any CaptureListing {
        if let g = listGate { await g.pass() }
        if listingFails { throw FakeCaptureError.cannotList }
        return FakeListing(backend: self, displays: displays)
    }

    func makeStream(_ id: UInt32, _ g: Int, _ stoppedByItself: @escaping @Sendable () -> Void) async throws -> FakeStream {
        if let gate = openGate { await gate.pass() }
        if failing.contains(id) { throw FakeCaptureError.cannotOpen }
        let s = FakeStream(display: id, generation: g, stoppedByItself: stoppedByItself)
        lock.withLock { made.append(s) }
        if stopAtOnce.contains(id) {
            s.fail()
            try? await Task.sleep(nanoseconds: 20_000_000)   // the scheduler hears of it before the start returns
        }
        return s
    }
}

struct FakeListing: CaptureListing {
    let backend: FakeCapture
    let displays: [UInt32]
    func open(_ display: UInt32, generation: Int, stoppedByItself: @escaping @Sendable () -> Void) async throws -> any CaptureStream {
        try await backend.makeStream(display, generation, stoppedByItself)
    }
}

final class FakeStream: CaptureStream, @unchecked Sendable {
    let display: UInt32
    let generation: Int
    private let stoppedByItself: @Sendable () -> Void
    private let lock = NSLock()
    private var isClosed = false
    init(display: UInt32, generation: Int, stoppedByItself: @escaping @Sendable () -> Void) {
        self.display = display; self.generation = generation; self.stoppedByItself = stoppedByItself
    }
    var closed: Bool { lock.withLock { isClosed } }
    func close() async { lock.withLock { isClosed = true } }
    /// The stream stops on its own (an error).
    func fail() { stoppedByItself() }
}

struct Stop: Equatable { let display: UInt32; let generation: Int; let byItself: Bool }
struct Fail: Equatable { let display: UInt32; let cause: FaultCause; let generation: Int }

@MainActor final class ReportLog {
    var listed: [[UInt32]] = []
    var failed: [Fail] = []
    var stopped: [Stop] = []
    var reports: CaptureReports {
        CaptureReports(listed: { [unowned self] in self.listed.append($0) },
                       failed: { [unowned self] in self.failed.append(Fail(display: $0, cause: $1, generation: $2)) },
                       stopped: { [unowned self] in self.stopped.append(Stop(display: $0, generation: $1, byItself: $2)) })
    }
}

/// Waits (briefly) until a condition holds on the main thread.
@MainActor func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 2_000_000) }
}

@MainActor @Suite struct StreamSchedulerTests {
    @Test func aStartStreamsEachDisplayAskedForWithTheRequestsGeneration() async {
        let log = ReportLog(), capture = FakeCapture([1, 2, 3])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        await s.start(only: [1, 2], generation: 5)
        #expect(await s.running == [1: 5, 2: 5])
        #expect(capture.opened.map(\.display).sorted() == [1, 2], "a display not asked for (past the limit) gets no stream")
        #expect(log.listed == [[1, 2, 3]])
        #expect(log.failed.isEmpty && log.stopped.isEmpty)
    }

    @Test func aStartStopsEveryOlderStreamAndReportsIt() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        await s.start(only: [1, 2], generation: 5)
        await s.start(only: [1, 2], generation: 7)
        #expect(await s.running == [1: 7, 2: 7])
        #expect(log.stopped == [Stop(display: 1, generation: 5, byItself: false), Stop(display: 2, generation: 5, byItself: false)])
        #expect(capture.streams.filter { $0.generation == 5 }.allSatisfy { $0.closed })
    }

    @Test func aRequestOlderThanTheNewestStartIsIgnored() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        await s.start(only: [1, 2], generation: 7)
        await s.start(only: [1, 2], generation: 5)
        await s.topUp(only: [1, 2], generation: 6)
        #expect(await s.running == [1: 7, 2: 7])
        #expect(capture.opened.count == 2)
    }

    @Test func aTopUpOnlyAddsMissingStreams() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        capture.failing = [2]
        await s.start(only: [1, 2], generation: 5)
        #expect(log.failed == [Fail(display: 2, cause: .noStream, generation: 5)], "reported with the request's generation")
        capture.failing = []
        await s.topUp(only: [1, 2], generation: 6)
        #expect(await s.running == [1: 5, 2: 6])
        #expect(log.stopped.isEmpty, "the running stream is left alone")
    }

    @Test func everyDisplayNotListedOrNotListableIsReportedWithTheRequestsGeneration() async {
        let log = ReportLog(), capture = FakeCapture([1])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        await s.start(only: [1, 2], generation: 5)
        #expect(log.failed == [Fail(display: 2, cause: .noStream, generation: 5)])
        capture.listingFails = true
        await s.start(only: [1, 2], generation: 6)
        #expect(log.failed.suffix(2) == [Fail(display: 1, cause: .noPermissionOrNoContent, generation: 6),
                                         Fail(display: 2, cause: .noPermissionOrNoContent, generation: 6)])
        #expect(await s.running.isEmpty, "the start stopped the old stream (reported) and could start none")
        #expect(log.stopped == [Stop(display: 1, generation: 5, byItself: false)])
    }

    @Test func aStartOvertakenWhileItOpensAStreamStopsItAndReportsIt() async {
        let log = ReportLog(), capture = FakeCapture([1])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        let gate = Gate()
        capture.openGate = gate
        async let first: Void = s.start(only: [1], generation: 5)
        await gate.reached(1)
        capture.openGate = nil
        await s.start(only: [1], generation: 7)
        await gate.open()
        await first
        #expect(await s.running == [1: 7])
        #expect(log.stopped == [Stop(display: 1, generation: 5, byItself: false)])
        #expect(capture.streams.first { $0.generation == 5 }?.closed == true)
    }

    @Test func twoRequestsForOneDisplayKeepTheNewerStream() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        capture.failing = [2]
        await s.start(only: [1, 2], generation: 5)
        capture.failing = []
        let gate = Gate()
        capture.openGate = gate
        async let six: Void = s.topUp(only: [1, 2], generation: 6)
        await gate.reached(1)
        async let seven: Void = s.topUp(only: [1, 2], generation: 7)
        await gate.reached(2)
        await gate.open()
        _ = await (six, seven)
        #expect(await s.running == [1: 5, 2: 7])
        #expect(log.stopped == [Stop(display: 2, generation: 6, byItself: false)])
    }

    @Test func aStreamThatStopsByItselfIsReportedOnceAndATopUpStartsAnother() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        await s.start(only: [1, 2], generation: 5)
        capture.streams.first { $0.display == 2 }?.fail()
        await waitUntil { log.stopped.contains(Stop(display: 2, generation: 5, byItself: true)) }
        #expect(await s.running == [1: 5])
        await s.topUp(only: [1, 2], generation: 6)
        #expect(await s.running == [1: 5, 2: 6])
        #expect(log.stopped == [Stop(display: 2, generation: 5, byItself: true)], "reported once")
    }

    @Test func aStreamThatStopsBeforeItIsKeptIsNeverKept() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        capture.stopAtOnce = [2]
        await s.start(only: [1, 2], generation: 5)
        await waitUntil { !log.stopped.isEmpty }
        #expect(await s.running == [1: 5])
        #expect(log.stopped == [Stop(display: 2, generation: 5, byItself: true)])
        #expect(capture.streams.first { $0.display == 2 }?.closed == true)
    }

    @Test func stopStopsEverythingAndNothingStartsAfterIt() async {
        let log = ReportLog(), capture = FakeCapture([1, 2])
        let s = StreamScheduler(backend: capture, reports: log.reports)
        await s.start(only: [1, 2], generation: 5)
        await s.stop()
        #expect(log.stopped == [Stop(display: 1, generation: 5, byItself: false), Stop(display: 2, generation: 5, byItself: false)])
        await s.start(only: [1, 2], generation: 9)
        await s.topUp(only: [1, 2], generation: 10)
        #expect(await s.running.isEmpty)
        #expect(capture.opened.count == 2)
    }
}

/// The coordinator, its capture link and a fake capture framework, wired as the app's watcher wires them.
@MainActor final class LinkRig {
    let presenter = RecordingPresenter()
    let os = FakeOS()
    let coordinator: CoverCoordinator
    let link: CaptureLink

    init(_ l: DisplayList, capture: FakeCapture) {
        let os = self.os
        os.list = l
        coordinator = CoverCoordinator(presenter: presenter, generations: GenerationCounter(), read: { _ in os.list },
                                       flush: {}, clock: { os.now }, state: { _ in os.state })
        link = CaptureLink(coordinator: coordinator)
        link.keepsRequests = true
        link.attach(capture)
    }

    /// Covering starts, the detector is ready, and capture starts.
    func begin() async {
        coordinator.start()
        link.ready = true
        coordinator.restartNow()
        await link.settled()
    }

    /// Display `id` is covered whole in every drawing from `index` on.
    func coveredSince(_ index: Int, _ id: UInt32) -> Bool {
        presenter.applied[index...].allSatisfy { plans in plans.first { $0.display.id == id }?.wholeDisplay != nil }
    }
}

@MainActor @Suite struct CaptureLinkTests {
    let a = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
    let x = DisplayDescriptor(id: 2, bounds: CGRect(x: 300, y: 0, width: 300, height: 200))

    func list(_ ds: [DisplayDescriptor]) -> DisplayList { DisplayList(displays: ds, main: 1) }

    @Test func aRestartOvertakenByADisplayChangeNeverShowsItsFramesAndADisplayItCannotRestartIsCovered() async throws {
        let capture = FakeCapture([1, 2])
        let r = LinkRig(list([a, x]), capture: capture)
        await r.begin()
        let g1 = try #require(capture.generation(of: 2))
        r.coordinator.deliver(.clear(a), generation: g1)
        r.coordinator.deliver(.clear(x), generation: g1)
        #expect(r.presenter.whole(2) == nil)

        // Change 1. Its restart (A) is asked for once the change has settled, and waits on the content list.
        r.coordinator.willChange()
        r.coordinator.didChange()
        let gate = Gate()
        capture.listGate = gate
        r.os.now += CoverCoordinator.settle
        r.coordinator.tick()
        await gate.reached(1)

        // Change 2 comes while A waits; then A goes on and starts its streams.
        r.coordinator.willChange()
        r.coordinator.didChange()
        let sinceChange2 = r.presenter.applied.count - 1
        capture.listGate = nil
        await gate.open()
        await r.link.settled()
        let gA = try #require(capture.generation(of: 2))
        #expect(gA > g1, "A's streams started after change 2")
        r.coordinator.deliver(.clear(x), generation: gA)
        #expect(r.presenter.whole(2) != nil, "a frame of A's stream is refused: A was asked for before change 2")

        // Change 2's restart (B) stops A's streams and cannot start one for display 2, which is not listed yet.
        capture.displays = [1]
        r.os.now += CoverCoordinator.settle
        r.coordinator.tick()
        await r.link.settled()
        #expect(r.presenter.whole(2) == .noStream)
        r.coordinator.deliver(.clear(x), generation: gA)
        #expect(r.presenter.whole(2) == .noStream, "A's frames never count")
        #expect(r.coveredSince(sinceChange2, 2), "display 2 never came down after change 2")
        #expect(r.presenter.whole(1) != nil, "display 1 waits for a frame of B's stream")
        let gB = try #require(capture.generation(of: 1))
        r.coordinator.deliver(.clear(a), generation: gB)
        #expect(r.presenter.whole(1) == nil)
    }

    @Test func pausingAndCoveringAgainNeverShowsAPlanFromTheOldStreams() async throws {
        let old = FakeCapture([1, 2])
        let r = LinkRig(list([a, x]), capture: old)
        await r.begin()
        let g1 = try #require(old.generation(of: 2))
        r.coordinator.deliver(.clear(a), generation: g1)
        r.coordinator.deliver(.clear(x), generation: g1)

        // Display 2's stream stops by itself. Its top-up waits on the content list when the owner pauses.
        let gate = Gate()
        old.listGate = gate
        old.streams.first { $0.display == 2 }?.fail()
        await waitUntil { r.presenter.whole(2) == .streamStopped }
        #expect(r.presenter.whole(2) == .streamStopped)
        r.os.now += CoverCoordinator.topUpDelays[0]
        r.coordinator.tick()
        await gate.reached(1)

        // Pause as the watcher does (the old streams are stopped without waiting), then cover again with a new
        // capture backend that cannot see display 2.
        r.link.detach()
        r.coordinator.stop()
        let fresh = FakeCapture([1])
        r.coordinator.start()
        let sinceResume = r.presenter.applied.count - 1
        r.link.attach(fresh)
        r.link.ready = true
        r.coordinator.restartNow()
        old.listGate = nil
        await gate.open()
        await r.link.settled()
        #expect(r.presenter.whole(2) == .noStream)

        // Whatever the old streams or the old top-up still send carries a generation the new start outranks.
        for g in old.opened.map(\.generation) {
            r.coordinator.deliver(.clear(x), generation: g)
            r.coordinator.deliver(.clear(a), generation: g)
        }
        #expect(r.presenter.whole(2) == .noStream)
        #expect(r.coveredSince(sinceResume, 2), "display 2 never came down after covering started again")
        #expect(r.presenter.whole(1) != nil, "nor display 1, until a frame of the new stream")
        let fresh1 = try #require(fresh.generation(of: 1))
        r.coordinator.deliver(.clear(a), generation: fresh1)
        #expect(r.presenter.whole(1) == nil)
    }
}
