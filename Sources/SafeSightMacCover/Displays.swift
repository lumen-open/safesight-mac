// SPDX-License-Identifier: Apache-2.0
// Every display, one rule, on the main thread (register SD-111, SD-112; chapter 05, sections 5.13 and 5.14).
//
// - Every display the OS lists gets a canvas, covered whole from the moment it is listed, before any capture stream
//   exists for it, until a judged frame from a current stream lowers it (DisplayCoverage).
// - When macOS announces a display change (CoreGraphics' reconfiguration callback, begin flag), every display is
//   covered whole at once, on this thread, before the callback returns. Nothing waits for the judging queue.
// - After the change the displays are read again, a canvas is made for each new display at once, and capture
//   restarts once the change has been quiet for `settle`.
// - The OS's lists are read again at every drawing and on a short timer, so a change nobody announced is covered too.
import AppKit
import QuartzCore
import SafeSightMacWatcher

/// Reads the OS's display lists: AppKit's screens, CoreGraphics' active and online lists, each display's bounds and
/// the display it repeats in a mirror set.
@MainActor
public enum SystemDisplays {
    /// `capture`: ScreenCaptureKit's list, when known (it can only add a display). Nil when CoreGraphics' active list
    /// cannot be read: the caller then keeps every display covered and reads again shortly.
    public static func read(capture: [UInt32] = []) -> DisplayList? {
        guard let active = list(CGGetActiveDisplayList) else { return nil }
        let screens: [DisplayList.Screen] = NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayList.Screen(id: n.uint32Value, frame: s.frame)
        }
        let main = CGMainDisplayID()
        return DisplayList.make(screens: screens, active: active, online: list(CGGetOnlineDisplayList) ?? [], capture: capture,
                                main: main, primaryHeight: CGDisplayBounds(main).height,
                                bounds: { CGDisplayBounds($0) },
                                mirrorOf: { let m = CGDisplayMirrorsDisplay($0); return m == kCGNullDirectDisplay ? nil : m })
    }

    static func list(_ get: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [UInt32]? {
        var count: UInt32 = 0
        guard get(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard get(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }
}

/// What the coordinator reads to end a hold whose counterpart notification never came.
public struct SystemState: Equatable, Sendable {
    /// Some listed display is asleep.
    public var displaysAsleep: Bool
    /// This login session is the one on the console (not switched away).
    public var sessionOnConsole: Bool
    /// The screen is locked (the session dictionary's `CGSSessionScreenIsLocked`).
    public var screenLocked: Bool
    /// The lock screen (or login window) is drawn over every listed display: a window at or above the level the lock
    /// screen was seen at (`CoverLevel.lockScreenSeen`) covering each display whole. Read only while `away`.
    public var lockScreenUp: Bool
    public init(displaysAsleep: Bool, sessionOnConsole: Bool, screenLocked: Bool = false, lockScreenUp: Bool = false) {
        self.displaysAsleep = displaysAsleep; self.sessionOnConsole = sessionOnConsole; self.screenLocked = screenLocked
        self.lockScreenUp = lockScreenUp
    }

    /// The owner is at the lock screen or the login window, or another session has the console: covers must not be drawn.
    public var away: Bool { screenLocked || !sessionOnConsole }

    /// Reads CoreGraphics: `CGDisplayIsAsleep` for the listed displays, and the session's on-console flag.
    public static func read(displays: [UInt32]) -> SystemState {
        let asleep = displays.contains { CGDisplayIsAsleep($0) != 0 }
        let d = CGSessionCopyCurrentDictionary() as? [String: Any]
        let session = d?[kCGSessionOnConsoleKey as String] as? Bool
        let locked = d?["CGSSessionScreenIsLocked"] as? Bool
        var s = SystemState(displaysAsleep: asleep, sessionOnConsole: session ?? false, screenLocked: locked ?? false)
        if s.away { s.lockScreenUp = lockScreenCovers(displays.map { CGDisplayBounds($0) }) }
        return s
    }

    /// Whether every display is covered whole by a window at or above the lock screen's level (the window list gives levels
    /// and frames only; no name is read). False with no display, or when the list cannot be read.
    public static func lockScreenCovers(_ displays: [CGRect]) -> Bool {
        guard !displays.isEmpty, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let shields: [CGRect] = list.compactMap { d in
            guard let layer = d[kCGWindowLayer as String] as? Int, layer >= CoverLevel.lockScreenSeen,
                  (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.001,
                  let b = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return r
        }
        return lockScreenCovers(displays, shields: shields)
    }

    /// The pure rule: every display lies inside one of `shields` (to within a point).
    public static func lockScreenCovers(_ displays: [CGRect], shields: [CGRect]) -> Bool {
        !displays.isEmpty && displays.allSatisfy { d in shields.contains { $0.insetBy(dx: -1, dy: -1).contains(d) } }
    }
}

/// CoreGraphics' display reconfiguration callback (CGDisplayRegisterReconfigurationCallback): called before a change
/// is applied (`willChange`, the begin flag) and once for each display after it (`didChange`).
public final class DisplayReconfiguration {
    public let handler: (DisplayChange, UInt32) -> Void
    public private(set) var registered = false

    public init(_ handler: @escaping (DisplayChange, UInt32) -> Void) { self.handler = handler }

    /// Registers the callback. Register it on the main thread: macOS calls it back on the thread that registered it,
    /// through that thread's run loop.
    public func start() {
        guard !registered else { return }
        registered = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque()) == .success
    }

    public func stop() {
        guard registered else { return }
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        registered = false
    }

    /// The C callback. On the main thread the handler runs at once, so the covers are drawn before the callback
    /// returns; from any other thread it is sent to the main thread.
    public static let callback: CGDisplayReconfigurationCallBack = { id, flags, info in
        guard let info else { return }
        let me = Unmanaged<DisplayReconfiguration>.fromOpaque(info).takeUnretainedValue()
        let change = DisplayChange(flags: flags)
        if Thread.isMainThread { me.handler(change, id) } else { DispatchQueue.main.async { me.handler(change, id) } }
    }
}

/// Decides, on the main thread, what every display shows, and draws it. It owns the display rule (DisplayCoverage),
/// the presenter and the timing of capture restarts. The app wires it to the capture layer and the judging queue.
@MainActor
public final class CoverCoordinator {
    public let coverage: DisplayCoverage
    public private(set) var running = false
    /// What was drawn last: one plan per display the OS lists.
    public private(set) var shown: [CoverPlan] = []
    /// Restarts every capture stream (after a change has settled, or when the detector is ready). The generation is
    /// taken here, on the main thread, when the restart is asked for: a display change after this outranks it, however
    /// late the streams start.
    public var restartCapture: (@MainActor (_ generation: Int) -> Void)?
    /// Starts streams only for displays without one: a display ScreenCaptureKit did not list yet, a stream that stopped.
    public var topUpCapture: (@MainActor (_ generation: Int) -> Void)?
    /// Stops every capture stream and starts none (asleep, locked, or another session on the console). Capture starts
    /// again with the restart that follows the end of the hold; every display stays covered whole until a judged frame
    /// of a stream started after that.
    public var pauseCapture: (@MainActor (_ generation: Int) -> Void)?
    /// Hands the judging queue the judged displays (counted here from the OS's lists) and each display's required
    /// stream generation. Called whenever either changes.
    public var judging: (@MainActor (_ judged: [UInt32], _ required: [UInt32: Int]) -> Void)?
    /// After every drawing.
    public var onShown: (@MainActor ([CoverPlan]) -> Void)?
    /// Asks the app to call `tick` after this many seconds: a restart or a retry is due.
    public var wake: (@MainActor (TimeInterval) -> Void)?

    /// How long a change must be quiet before capture restarts.
    public nonisolated static let settle: TimeInterval = 0.2
    /// An announced change with no call after it is treated as finished after this long.
    public nonisolated static let unfinishedChange: TimeInterval = 3
    /// Retries for a display with no stream (ScreenCaptureKit's list can lag a new display): after 1, 2 and 4 s, then
    /// not until the next change. The display stays covered whole meanwhile.
    public nonisolated static let topUpDelays: [TimeInterval] = [1, 2, 4]
    /// A sleep, display-sleep or session hold whose wake or return notification never came ends once the OS says it
    /// is over and the hold has lasted this long (awake time): displays awake, the session on the console.
    public nonisolated static let holdCheckAfter: [HoldReason: TimeInterval] = [.displaysAsleep: 2, .session: 2, .sleep: 10, .locked: 0]
    /// While the screen locks, every display stays covered whole (below the lock screen's level) until the lock screen is
    /// seen drawn over it; then the canvases are taken off. If it is not seen within this long, they are taken off anyway:
    /// a cover must never be what stands in front of the password field.
    public nonisolated static let lockScreenWait: TimeInterval = 10

    private let presenter: CoverPresenter
    private let read: @MainActor ([UInt32]) -> DisplayList?
    private let flush: @MainActor () -> Void
    private let clock: @MainActor () -> TimeInterval
    private let state: @MainActor ([UInt32]) -> SystemState
    private var holdSince: [HoldReason: TimeInterval] = [:]
    private var seenByCapture: [UInt32] = []
    public private(set) var restartDue: TimeInterval?
    public private(set) var topUpDue: TimeInterval?
    private var topUps = 0
    private var stalled: Set<UInt32> = []
    private var unjudged: [UInt32: [CGRect]] = [:]
    private var handedToJudging: (judged: [UInt32], required: [UInt32: Int])?

    public init(presenter: CoverPresenter, generations: GenerationCounter,
                read: @escaping @MainActor ([UInt32]) -> DisplayList? = { SystemDisplays.read(capture: $0) },
                flush: @escaping @MainActor () -> Void = { CATransaction.flush() },
                clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                state: @escaping @MainActor ([UInt32]) -> SystemState = { SystemState.read(displays: $0) }) {
        self.coverage = DisplayCoverage(generations: generations)
        self.presenter = presenter; self.read = read; self.flush = flush; self.clock = clock; self.state = state
    }

    // MARK: Life

    /// Every display the OS lists gets a canvas, covered whole, before any stream exists. Capture starts when the app
    /// calls `restartNow` (once the detector is ready).
    public func start() {
        running = true
        coverage.detectorFailed = false
        coverage.reset(read(seenByCapture) ?? coverage.list)
        holdSince = [:]
        resetRetries(); restartDue = nil
        handedToJudging = nil
        present(urgent: true)
    }

    /// Removes every cover (Pause in the practice state, Quit).
    public func stop() {
        running = false
        restartDue = nil; topUpDue = nil
        presenter.removeAll()
        gate.reset()
        shown = []
        onShown?(shown)
    }

    /// Try again: every display is covered whole again until judged. Capture restarts when the app calls `restartNow`.
    public func restart() {
        guard running else { start(); return }
        coverage.detectorFailed = false
        coverage.reset(read(seenByCapture) ?? coverage.list)
        holdSince = [:]
        resetRetries(); restartDue = nil
        present(urgent: true)
    }

    /// Restarts capture now (the detector has just become ready), or as soon as a change in progress is done.
    public func restartNow() {
        guard running else { return }
        guard coverage.hold == nil else { restartDue = clock(); return }
        restartDue = nil
        restartCapture?(coverage.newRequest())
    }

    /// The detector could not load: every display is covered whole, including any display attached later.
    public func detectorFailed() {
        guard running else { return }
        coverage.detectorFailed = true
        present(urgent: true)
    }

    /// A warm-up that ran past `WARM_UP_LIMIT` has ended well: the detector failure it caused is over. Unlike `restart`,
    /// every hold (asleep, locked, another session, a display change) stays: the displays stay covered whole, and capture
    /// restarts only through `restartNow`, which waits for the holds to end.
    public func detectorRecovered() {
        guard running else { return }
        coverage.detectorFailed = false
        present(urgent: true)
    }

    // MARK: Display changes

    /// macOS announced a change (`.change`), or the Mac or its displays are going to sleep, or the session is going
    /// away: every display is covered whole now, and stays covered until `didChange` with the same reason. An
    /// announced change that never finishes is treated as finished after `unfinishedChange`.
    public func willChange(_ reason: HoldReason = .change) {
        guard running else { return }
        let ends = reason == .change ? clock() + Self.unfinishedChange : nil
        if holdSince[reason] == nil { holdSince[reason] = clock() }
        coverage.hold(reason, until: ends)
        if ends != nil { wake?(Self.unfinishedChange) }
        if reason != .change, !coverage.holds.contains(.locked), state(coverage.list.ids).away {
            holdSince[.locked] = clock()
            coverage.hold(.locked)
        }
        present(urgent: true)
        if reason != .change { pauseForHold() }
    }

    /// A change has been applied (`.change`), or the Mac or its displays woke, or the session came back. The displays
    /// are read again and every display, a new one included, is covered whole until a judged frame from a stream
    /// started after the change has settled.
    public func didChange(_ reason: HoldReason = .change) {
        guard running else { return }
        holdSince[reason] = nil
        if let new = read(seenByCapture) {
            coverage.release(reason, new)
        } else {
            coverage.release(reason, coverage.list)
            coverage.hold(.change, until: clock() + 1)
        }
        resetRetries()
        draw(urgent: true)
        requestRestart(after: Self.settle)
    }

    // MARK: From the judging queue and the capture layer

    /// A plan made from a frame of stream `generation`. Drawn only if the display rule accepts it.
    public func deliver(_ plan: CoverPlan, generation: Int) {
        guard running, coverage.accept(plan, generation: generation) else { return }
        present()
    }

    /// A display has no stream for request or stream `generation` (none could start, or it stopped by itself). It is
    /// covered whole, and retried a few times.
    public func fault(_ id: UInt32, _ cause: FaultCause, generation: Int) {
        guard running else { return }
        coverage.fault(id, cause, generation: generation)
        if [.noStream, .streamStopped, .noPermissionOrNoContent].contains(cause), coverage.list.descriptor(id) != nil {
            scheduleTopUp()
        }
        present()
    }

    /// A stream of this generation was stopped on purpose: its frames never count again, and a plan from it no longer
    /// shows.
    public func retire(_ id: UInt32, generation: Int) {
        guard running else { return }
        coverage.retire(id, generation: generation)
        present()
    }

    /// The displays ScreenCaptureKit listed. It can add a display; it never takes one away.
    public func captureSaw(_ ids: [UInt32]) {
        guard running else { return }
        seenByCapture = ids
        if let new = read(ids), coverage.add(new) {
            resetRetries()
            requestRestart(after: Self.settle)
        }
        draw(urgent: false)
    }

    // MARK: Time

    /// Runs what is due (a restart after a change has settled, a retry, the end of an announced change that never
    /// finished) and reads the OS's lists again. `stalled`: displays whose judging has fallen too far behind.
    /// `unjudged`: changed areas left waiting too long to be judged, covered until they are.
    public func tick(stalled: Set<UInt32> = [], unjudged: [UInt32: [CGRect]] = [:]) {
        guard running else { return }
        let now = clock()
        // Read from the OS itself (never from a notification any app could post): at the lock screen, or with another
        // session on the console, no cover is drawn (`.locked`); it ends below once the OS says the owner is back.
        if !coverage.holds.contains(.locked), state(coverage.list.ids).away {
            holdSince[.locked] = now
            coverage.hold(.locked)
            draw(urgent: true)
            pauseForHold()
        }
        var redraw = stalled != self.stalled || unjudged != self.unjudged
        self.stalled = stalled
        self.unjudged = unjudged
        if let e = coverage.holdEnds, now >= e { didChange(); redraw = false }
        endHoldsThatAreOver(now)
        if coverage.hold == nil, let r = restartDue, now >= r {
            restartDue = nil; topUpDue = nil
            restartCapture?(coverage.newRequest())
        }
        if coverage.hold == nil, let t = topUpDue, now >= t {
            topUpDue = nil
            topUpCapture?(coverage.newRequest())
        }
        if refresh() { redraw = true }
        if waitingForLockScreen { redraw = true }
        if redraw { draw(urgent: true) }
    }

    // MARK: Drawing

    /// Reads the OS's lists, then draws one plan per listed display. A display that appeared since is covered whole at
    /// once; a change nobody announced also restarts capture.
    public func present(urgent: Bool = false) {
        guard running else { return }
        refresh()
        draw(urgent: urgent)
    }

    /// Returns true when the OS's lists changed (or could not be read).
    @discardableResult
    private func refresh() -> Bool {
        guard let new = read(seenByCapture) else {
            // The lists could not be read: everything stays covered, and they are read again shortly.
            if coverage.hold == nil { coverage.hold(.change, until: clock() + 1); wake?(1) }
            return true
        }
        guard coverage.update(new) else { return false }
        resetRetries()
        requestRestart(after: Self.settle)
        return true
    }

    /// The last update handed to the presenter, so one exactly like it is not handed over again.
    private var gate = DrawGate()
    /// The presenter was cleared by someone else (the emergency quit): the next update is drawn whatever it holds.
    public func presenterCleared() { gate.reset() }

    /// True while the canvases are drawn covered whole during a lock, waiting for the lock screen to be drawn.
    public private(set) var waitingForLockScreen = false

    private func draw(urgent: Bool) {
        guard running else { return }
        shown = coverage.shown(stalled: stalled, unjudged: unjudged)
        // At the lock screen nothing is drawn: every canvas is taken off the screen, so none can stand in front of the
        // password field. But the lock screen takes a moment (seconds, on a slow Mac) to be drawn after the session says
        // it is locked, and taking the canvases off at once showed the desktop meanwhile. So until the lock screen is
        // seen over every display, the canvases stay, covered whole, below its level (`CoverLevel.canvas` is under
        // `CoverLevel.lockScreenSeen`), and they go once it is, or after `lockScreenWait` in any case. Everything counts as
        // covered whole meanwhile, and is drawn covered whole on the way back.
        if coverage.holds.contains(.locked) {
            let since = holdSince[.locked] ?? clock()
            // Drawn here some other way: the next update after the lock is drawn whatever it holds.
            gate.reset()
            if state(coverage.list.ids).lockScreenUp || clock() - since >= Self.lockScreenWait {
                waitingForLockScreen = false
                presenter.removeAll()
            } else {
                waitingForLockScreen = true
                presenter.apply(shown)
                wake?(0.1)
            }
        } else {
            waitingForLockScreen = false
            // An update exactly like the last one drawn is not drawn again (`DrawGate`): the judging hands one over for
            // every frame the capture sends, most of them the same.
            if gate.shouldDraw(shown, now: clock(), urgent: urgent) { presenter.apply(shown) }
        }
        if urgent { flush() }
        let judged = coverage.list.judged, required = coverage.required
        if handedToJudging.map({ $0.judged != judged || $0.required != required }) ?? true {
            handedToJudging = (judged, required)
            judging?(judged, required)
        }
        onShown?(shown)
    }

    /// Sleep, display sleep, the lock screen or another session: nothing on screen is this session's to judge, so capture
    /// stops (it costs energy and judges nothing that could be shown). It never lowers a cover: every display is covered
    /// whole by the hold already, and the streams' stops retire their generations. Any restart already due waits for the
    /// end of the hold, which restarts capture; the coming restart outranks this pause.
    private func pauseForHold() {
        guard coverage.holds.contains(where: { $0 != .change }) else { return }
        topUpDue = nil
        pauseCapture?(coverage.newRequest())
    }

    private func requestRestart(after delay: TimeInterval) {
        restartDue = clock() + delay
        wake?(delay)
    }

    private func scheduleTopUp() {
        guard topUpDue == nil, restartDue == nil, topUps < Self.topUpDelays.count else { return }
        let d = Self.topUpDelays[topUps]
        topUps += 1
        topUpDue = clock() + d
        wake?(d)
    }

    private func resetRetries() { topUps = 0; topUpDue = nil }

    /// A sleep, display-sleep or session hold ends without its notification once the OS says it is over: the listed
    /// displays are awake (and, for sleep, the session is on the console), or the session is back on the console. It
    /// is ended as its notification would end it: every display stays covered until judged by restarted streams.
    private func endHoldsThatAreOver(_ now: TimeInterval) {
        let waiting = coverage.holds.filter { $0 != .change }
        guard !waiting.isEmpty else { return }
        let s = state(coverage.list.ids)
        for reason in waiting.sorted(by: { "\($0)" < "\($1)" }) {
            guard let since = holdSince[reason], let after = Self.holdCheckAfter[reason], now - since >= after else { continue }
            let over: Bool
            switch reason {
            case .displaysAsleep: over = !s.displaysAsleep
            case .session: over = s.sessionOnConsole
            case .sleep: over = !s.displaysAsleep && s.sessionOnConsole
            case .locked: over = !s.away
            case .change: over = false
            }
            if over { didChange(reason) }
        }
    }
}
