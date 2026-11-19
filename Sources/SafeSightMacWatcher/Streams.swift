// SPDX-License-Identifier: Apache-2.0
// Capture streams on request: at most one stream per display, every stream accounted for, and no report or frame
// from an old request able to pass for a new one.
//
// Every request (a full start or a top-up) carries the generation the cover coordinator took on the main thread when
// it asked. A display change raises the generation a display's frames need above every request made before it, so a
// stream started for an old request can never lower a cover, however late it starts. Every stream that ends is
// reported with its generation: one stopped on purpose (by a newer start, or because a newer request got its display)
// and one that stopped by itself alike, so the coordinator never shows a plan whose stream is gone.
//
// Pure: no ScreenCaptureKit. The app's backend is ScreenCaptureKit (SafeSightMacCapture); tests use a fake.
import Foundation

/// What a display stream leaves out of capture: the app's own windows (its covers). With none listed, a stream would
/// capture the covers themselves, and a cover would look like a clean picture of what it hides: no stream is started,
/// and the display stays covered whole.
public enum CaptureExclusion {
    /// The apps to leave out (those of `ownPID`), or nil when there are none and no stream may start.
    public static func own<App>(_ apps: [App], pid: (App) -> Int32, ownPID: Int32) -> [App]? {
        let own = apps.filter { pid($0) == ownPID }
        return own.isEmpty ? nil : own
    }
}

/// One running capture stream.
public protocol CaptureStream: AnyObject, Sendable {
    /// Stops the stream. Its frames stop coming, apart from any already on their way.
    func close() async
}

/// One look at what can be captured: the displays listed, and a way to start a stream on one of them.
public protocol CaptureListing: Sendable {
    var displays: [UInt32] { get }
    /// Starts a stream for a listed display; every frame of it carries `generation`. `stoppedByItself` runs at most
    /// once, if the stream stops on its own (an error), never after `close`.
    func open(_ display: UInt32, generation: Int, stoppedByItself: @escaping @Sendable () -> Void) async throws -> any CaptureStream
}

/// The capture framework as the scheduler sees it.
public protocol CaptureBackend: Sendable {
    /// Lists the displays that can be captured now. Throws when none can be listed (Screen Recording is off).
    func list() async throws -> any CaptureListing
}

/// What the scheduler tells the cover coordinator, on the main thread, before it goes on.
public struct CaptureReports: Sendable {
    /// The displays the capture framework listed (a cross-check: it can add a display, never remove one).
    public var listed: @MainActor @Sendable ([UInt32]) -> Void
    /// Request `generation` could not give this display a stream (`noStream`, or `noPermissionOrNoContent`).
    public var failed: @MainActor @Sendable (_ display: UInt32, _ cause: FaultCause, _ generation: Int) -> Void
    /// A stream of this generation ended: stopped on purpose, or by itself. Its frames never count again.
    public var stopped: @MainActor @Sendable (_ display: UInt32, _ generation: Int, _ byItself: Bool) -> Void

    public init(listed: @escaping @MainActor @Sendable ([UInt32]) -> Void,
                failed: @escaping @MainActor @Sendable (UInt32, FaultCause, Int) -> Void,
                stopped: @escaping @MainActor @Sendable (UInt32, Int, Bool) -> Void) {
        self.listed = listed; self.failed = failed; self.stopped = stopped
    }
}

/// Starts and stops one capture stream per display, on request.
///
/// - `start(only:generation:)` stops every stream older than the request, then starts one for each display in `only`
///   that has none. A start older than the newest start already run is ignored.
/// - `topUp(only:generation:)` only starts streams for displays in `only` that have none. A top-up older than the
///   newest start is ignored.
/// - A request stops early, stopping what it had just started, as soon as a newer start (or `stop`) has begun.
/// - Two streams never run for one display: the newer is kept and the older stopped.
/// - `stop()` stops every stream; nothing after it starts another.
public actor StreamScheduler {
    private struct Running { let stream: any CaptureStream; let generation: Int; let serial: Int }

    private let backend: any CaptureBackend
    private let reports: CaptureReports
    private var streams: [UInt32: Running] = [:]
    /// The generation of the newest start run.
    private var newestStart = Int.min
    private var stopped = false
    private var serial = 0
    /// Streams (by serial) that stopped by themselves before they were kept: never kept.
    private var stoppedEarly: Set<Int> = []

    public init(backend: any CaptureBackend, reports: CaptureReports) {
        self.backend = backend; self.reports = reports
    }

    /// The running streams' generations, by display.
    public var running: [UInt32: Int] { streams.mapValues(\.generation) }

    public func start(only: Set<UInt32>, generation g: Int) async {
        guard !stopped, g > newestStart else { return }
        newestStart = g
        let old = streams.filter { $0.value.generation < g }
        for id in old.keys { streams[id] = nil }
        for (id, r) in old.sorted(by: { $0.key < $1.key }) {
            await reports.stopped(id, r.generation, false)
            await r.stream.close()
        }
        await addMissing(only, g)
    }

    public func topUp(only: Set<UInt32>, generation g: Int) async {
        guard !stopped, g > newestStart else { return }
        await addMissing(only, g)
    }

    public func stop() async {
        stopped = true
        let old = streams
        streams = [:]
        for (id, r) in old.sorted(by: { $0.key < $1.key }) {
            await reports.stopped(id, r.generation, false)
            await r.stream.close()
        }
    }

    /// Request `g` is still current: nothing newer has started, and the scheduler is not stopped.
    private func current(_ g: Int) -> Bool { !stopped && g >= newestStart }

    private func addMissing(_ only: Set<UInt32>, _ g: Int) async {
        let listing: any CaptureListing
        do {
            listing = try await backend.list()
        } catch {
            guard current(g) else { return }
            for id in only.sorted() where streams[id] == nil { await reports.failed(id, .noPermissionOrNoContent, g) }
            return
        }
        guard current(g) else { return }
        await reports.listed(listing.displays)
        for id in only.sorted() where streams[id] == nil {
            guard current(g) else { return }
            guard listing.displays.contains(id) else {
                // A display the capture framework cannot see: covered whole for as long as that lasts.
                await reports.failed(id, .noStream, g); continue
            }
            serial += 1
            let mine = serial
            let stream: any CaptureStream
            do {
                stream = try await listing.open(id, generation: g) { [weak self] in
                    Task { await self?.stoppedByItself(id, serial: mine, generation: g) }
                }
            } catch {
                guard current(g) else { return }
                await reports.failed(id, .noStream, g); continue
            }
            if stoppedEarly.contains(mine) {
                // It stopped by itself before it was kept, and that was reported; a top-up starts another.
                await stream.close(); continue
            }
            guard current(g) else {
                // Overtaken while it started: a newer start or `stop` covers this display now.
                await reports.stopped(id, g, false)
                await stream.close()
                return
            }
            let displaced = streams[id]
            if let d = displaced, d.generation >= g {
                // A request at least as new got this display first.
                await reports.stopped(id, g, false)
                await stream.close()
                continue
            }
            streams[id] = Running(stream: stream, generation: g, serial: mine)
            if let d = displaced {
                await reports.stopped(id, d.generation, false)
                await d.stream.close()
            }
        }
    }

    /// A stream stopped on its own: forgotten (so a top-up can start another) and reported.
    private func stoppedByItself(_ id: UInt32, serial: Int, generation g: Int) async {
        if let r = streams[id], r.serial == serial { streams[id] = nil } else { stoppedEarly.insert(serial) }
        await reports.stopped(id, g, true)
    }
}
