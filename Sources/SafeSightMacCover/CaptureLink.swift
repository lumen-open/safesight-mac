// SPDX-License-Identifier: Apache-2.0
// The link between the cover coordinator (main thread) and the capture streams (StreamScheduler). The app's watcher
// uses it, and so do the tests that drive a display change through a capture restart, with a fake capture backend.
//
// - A capture request carries the generation the coordinator took when it asked, on the main thread. A display change
//   after the request outranks it, however late its streams start.
// - Every report from the scheduler reaches the coordinator on the main thread before the scheduler goes on: a display
//   with no stream is covered; a stream that stopped by itself is a fault; one stopped on purpose is retired.
// - Pausing stops the scheduler without waiting. A request still running in it, or a frame on its way, carries a
//   generation the coordinator outranks when covering starts again.
import Foundation
import SafeSightMacWatcher

@MainActor
public final class CaptureLink {
    public let coordinator: CoverCoordinator
    /// False while capture may not start: the detector is loading, or it failed.
    public var ready = false
    public private(set) var scheduler: StreamScheduler?
    /// Tests: keep every request sent, so `settled()` can wait for them.
    public var keepsRequests = false
    private var requests: [Task<Void, Never>] = []

    public init(coordinator: CoverCoordinator) {
        self.coordinator = coordinator
        coordinator.restartCapture = { [weak self] g in self?.send { s, only in await s.start(only: only, generation: g) } }
        coordinator.topUpCapture = { [weak self] g in self?.send { s, only in await s.topUp(only: only, generation: g) } }
    }

    /// What a scheduler tells this link's coordinator.
    public var reports: CaptureReports {
        let c = coordinator
        return CaptureReports(
            listed: { ids in c.captureSaw(ids) },
            failed: { id, cause, g in c.fault(id, cause, generation: g) },
            stopped: { id, g, byItself in
                if byItself { c.fault(id, .streamStopped, generation: g) } else { c.retire(id, generation: g) }
            })
    }

    /// Starts using a new scheduler over `backend` (at start, and when covering starts again after a pause).
    public func attach(_ backend: any CaptureBackend) {
        detach()
        scheduler = StreamScheduler(backend: backend, reports: reports)
    }

    /// Stops the scheduler's streams, without waiting.
    public func detach() {
        ready = false
        guard let s = scheduler else { return }
        scheduler = nil
        keep(Task { await s.stop() })
    }

    /// Waits for every request kept so far (tests).
    public func settled() async {
        while !requests.isEmpty {
            let r = requests
            requests = []
            for t in r { await t.value }
        }
    }

    /// Sends a request for the judged displays, counted from the OS's lists, to the scheduler.
    private func send(_ body: @escaping @Sendable (StreamScheduler, Set<UInt32>) async -> Void) {
        guard ready, let s = scheduler else { return }
        let only = Set(coordinator.coverage.list.judged)
        keep(Task { await body(s, only) })
    }

    private func keep(_ t: Task<Void, Never>) { if keepsRequests { requests.append(t) } }
}
