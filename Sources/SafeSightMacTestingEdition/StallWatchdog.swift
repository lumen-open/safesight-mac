// SPDX-License-Identifier: Apache-2.0
// The last way out of the Testing edition: if its main thread stops answering while a cover is on screen, it
// quits, and its covers go with it.
//
// Every way to quit (the menu, the repair card, ⌃⌥⌘Q) is handled on the main thread. If that thread were ever stuck,
// a cover could stay up with nothing on the Mac able to lower it except Activity Monitor, and an app with no Dock
// icon is not listed in the Force Quit window. So a timer on another thread watches the main thread's heartbeat, and
// after `limit` seconds of silence with a cover up, it ends the app. Nothing starts the Testing edition again: its
// owner opens it when they want it.
//
// Silence is counted only while the watcher itself was running. A check that ran late means the whole process was
// held up (the Mac or the virtual Mac slept, App Nap, a debugger, a long pause), not just the main thread: that gap
// counts as one check interval at most, never as its length. So a sleep, a pause of any length or a clock that
// jumps never ends the app, and a main thread that stays silent for `limit` seconds of the watcher's own running
// time, before or after one, still does.
import Foundation

public final class StallWatchdog: @unchecked Sendable {
    /// Seconds of main-thread silence, with a cover up, before the app quits.
    public static let limit: TimeInterval = 8
    /// How often the main thread beats and the watcher looks, in seconds.
    public static let beatInterval: TimeInterval = 0.5
    public static let checkInterval: TimeInterval = 1

    /// A check later than this after the one before (`checkInterval` x 2.5) means the process itself was held up.
    public static let lateAfter: TimeInterval = checkInterval * 2.5

    /// The rule, apart from the clocks: quit only when a cover is up and the main thread has been silent for longer
    /// than `limit` of the watcher's own running time (`Silence`).
    public static func shouldQuit(silence: TimeInterval, coverShown: Bool, limit: TimeInterval = limit) -> Bool {
        coverShown && silence > limit
    }

    /// How long the main thread has been silent, counted only while the watcher was running.
    public struct Silence: Sendable, Equatable {
        /// Seconds of silence counted so far.
        public private(set) var seconds: TimeInterval = 0
        private var lastCheck: TimeInterval?
        private var lastBeat: TimeInterval
        private var beats: UInt64 = 0
        private var beatsAtLastCheck: UInt64 = 0

        public init(now: TimeInterval) { lastBeat = now }

        /// The main thread beat at `now`.
        public mutating func beat(at now: TimeInterval) {
            lastBeat = now
            beats &+= 1
        }

        /// One check at `now`; returns the silence counted. The time since the last check counts in full when the
        /// check ran on time; a late one counts as one `checkInterval`, and a clock that went back counts nothing. A
        /// beat since the last check starts the count again from that beat, within the same bound. The first check
        /// only notes the time.
        @discardableResult
        public mutating func check(at now: TimeInterval, checkInterval: TimeInterval = StallWatchdog.checkInterval,
                                   lateAfter: TimeInterval = StallWatchdog.lateAfter) -> TimeInterval {
            defer { lastCheck = now; beatsAtLastCheck = beats }
            guard let last = lastCheck else { seconds = 0; return seconds }
            let elapsed = now - last
            let counted = elapsed < 0 ? 0 : (elapsed > lateAfter ? min(elapsed, checkInterval) : elapsed)
            if beats != beatsAtLastCheck {
                seconds = min(max(0, now - lastBeat), counted)
            } else {
                seconds += counted
            }
            return seconds
        }
    }

    private let lock = NSLock()
    private var silence: Silence
    private var coverShown = false
    private let clock: @Sendable () -> TimeInterval
    private let action: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var beatTimer: Timer?
    private let queue = DispatchQueue(label: "safesightmac.testing.watchdog", qos: .userInteractive)

    /// `action` runs on the watchdog's own queue, never the main thread.
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                action: @escaping @Sendable () -> Void) {
        self.clock = clock
        self.action = action
        self.silence = Silence(now: clock())
    }

    /// Starts the heartbeat (on the main run loop, in every mode, so menus and alerts do not stop it) and the
    /// watching timer. Main thread.
    public func start() {
        beat()
        let t = Timer(timeInterval: Self.beatInterval, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(t, forMode: .common)
        beatTimer = t
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.check() }
        source.resume()
        timer = source
    }

    public func stop() {
        beatTimer?.invalidate(); beatTimer = nil
        timer?.cancel(); timer = nil
    }

    /// The main thread is alive.
    public func beat() {
        let now = clock()
        lock.withLock { silence.beat(at: now) }
    }

    /// Whether any cover is on screen now. Main thread, whenever covers change.
    public func setCoverShown(_ shown: Bool) {
        lock.withLock { coverShown = shown }
    }

    /// One look. Returns true when it ended the app (in tests, when `action` ran).
    @discardableResult
    func check() -> Bool {
        let now = clock()
        let quit: Bool = lock.withLock {
            Self.shouldQuit(silence: silence.check(at: now), coverShown: coverShown)
        }
        if quit { action() }
        return quit
    }
}
