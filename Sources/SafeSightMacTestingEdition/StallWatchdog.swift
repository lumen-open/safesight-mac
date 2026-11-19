// SPDX-License-Identifier: Apache-2.0
// The last way out of the Testing edition: if its main thread stops answering while a cover is on screen, it
// quits, and its covers go with it.
//
// Every way to quit (the menu, the repair card, ⌃⌥⌘Q) is handled on the main thread. If that thread were ever stuck,
// a cover could stay up with nothing on the Mac able to lower it except Activity Monitor, and an app with no Dock
// icon is not listed in the Force Quit window. So a timer on another thread watches the main thread's heartbeat, and
// after `limit` seconds of silence with a cover up, it ends the app. If the watching timer itself ran late, the
// whole process was held up (the Mac slept, App Nap, a debugger), not just the main thread, and it waits instead.
import Foundation

public final class StallWatchdog: @unchecked Sendable {
    /// Seconds of main-thread silence, with a cover up, before the app quits.
    public static let limit: TimeInterval = 8
    /// How often the main thread beats and the watcher looks, in seconds.
    public static let beatInterval: TimeInterval = 0.5
    public static let checkInterval: TimeInterval = 1

    /// The rule, apart from the clocks: quit only when a cover is up, the main thread has been silent longer than
    /// `limit`, and this check itself ran on time.
    public static func shouldQuit(now: TimeInterval, lastBeat: TimeInterval, lastCheck: TimeInterval?, coverShown: Bool,
                                  limit: TimeInterval = limit, checkInterval: TimeInterval = checkInterval) -> Bool {
        guard coverShown, let lastCheck else { return false }
        let checkWasLate = now - lastCheck > checkInterval * 2.5
        return !checkWasLate && now - lastBeat > limit
    }

    private let lock = NSLock()
    private var lastBeat: TimeInterval
    private var lastCheck: TimeInterval?
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
        self.lastBeat = clock()
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
        lock.withLock { lastBeat = now }
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
            defer { lastCheck = now }
            return Self.shouldQuit(now: now, lastBeat: lastBeat, lastCheck: lastCheck, coverShown: coverShown)
        }
        if quit { action() }
        return quit
    }
}
