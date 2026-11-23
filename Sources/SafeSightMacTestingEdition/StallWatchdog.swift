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
// The heartbeat proves the main thread ran: each check asks the main queue to answer (one question at a time), and
// the answer is the beat. A timer on the main run loop could be held back by macOS to save energy (App Nap, timer
// coalescing) while the main thread was fine; a main-queue answer is not a timer, and comes as soon as the main thread
// is free. While a cover is up the app also holds a user-initiated activity, which keeps App Nap off without
// keeping the Mac or its displays awake.
//
// Silence is counted only while the watcher itself was running. A check that ran late means the whole process was
// held up (the Mac or the virtual Mac slept, App Nap, a debugger, a long pause), not just the main thread: that gap
// counts as one check interval at most, never as its length. So a sleep, a pause of any length or a clock that
// jumps never ends the app, and a main thread that stays silent for `limit` seconds of the watcher's own running
// time, before or after one, still does. When every check runs late, a real stall is found after about nine of them.
import Foundation
import SafeSightMacCore

public final class StallWatchdog: @unchecked Sendable {
    /// Seconds of main-thread silence, with a cover up, before the app quits.
    public static let limit: TimeInterval = 8
    /// How often the watcher looks (and asks the main thread to answer), in seconds.
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
    /// A question to the main thread is waiting for its answer.
    private var asking = false
    private let clock: @Sendable () -> TimeInterval
    private let ask: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let activity: CoverActivity
    private let action: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "safesightmac.testing.watchdog", qos: .userInteractive)

    /// `ask` runs a block on the main thread (the main queue; a stand-in in tests). `activity` is held while a cover is
    /// up. `action` runs on the watchdog's own queue, never the main thread.
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                ask: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                activity: CoverActivity = NoNapWhileCovered(),
                action: @escaping @Sendable () -> Void) {
        self.clock = clock
        self.ask = ask
        self.activity = activity
        self.action = action
        self.silence = Silence(now: clock())
    }

    /// Starts the watching timer. Main thread.
    public func start() {
        beat()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.check() }
        source.resume()
        timer = source
    }

    public func stop() {
        timer?.cancel(); timer = nil
        setCoverShown(false)
    }

    /// The main thread is alive.
    public func beat() {
        let now = clock()
        lock.withLock { silence.beat(at: now) }
    }

    /// Whether any cover is on screen now. Main thread, whenever covers change. The activity is held from the first
    /// cover until none is left.
    public func setCoverShown(_ shown: Bool) {
        let changed: Bool = lock.withLock {
            defer { coverShown = shown }
            return coverShown != shown
        }
        guard changed else { return }
        if shown { activity.begin() } else { activity.end() }
    }

    /// One look. Returns true when it ended the app (in tests, when `action` ran). Otherwise it asks the main thread
    /// to answer, unless an earlier question is still waiting.
    @discardableResult
    func check() -> Bool {
        let now = clock()
        let (quit, askNow): (Bool, Bool) = lock.withLock {
            let quit = Self.shouldQuit(silence: silence.check(at: now), coverShown: coverShown)
            let askNow = !quit && !asking
            if askNow { asking = true }
            return (quit, askNow)
        }
        if quit { action(); return true }
        if askNow {
            ask { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.asking = false }
                self.beat()
            }
        }
        return false
    }
}

/// What the watchdog holds while a cover is up.
public protocol CoverActivity: AnyObject, Sendable {
    func begin()
    func end()
}

/// A user-initiated activity that still lets the Mac sleep when idle: it keeps App Nap and timer throttling off, so
/// the app's checks run on time, and does not keep the Mac or its displays awake.
public final class NoNapWhileCovered: CoverActivity, @unchecked Sendable {
    public static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    public init() {}
    public func begin() {
        lock.withLock {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(options: Self.options, reason: "A cover is on screen")
        }
    }
    public func end() {
        lock.withLock {
            if let t = token { ProcessInfo.processInfo.endActivity(t) }
            token = nil
        }
    }
}

/// The one line the Testing edition leaves when its watchdog ended it, so the next launch can say its covers came down:
/// the time only, in a small file inside its own folder (the sandbox container). Nothing from the screen.
public enum StallNote {
    public static let fileName = "ended-itself.txt"

    /// The app's own folder: Application Support/<product name> (inside the container when sandboxed).
    public static func folder() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent(AppText.productName, isDirectory: true)
    }

    /// Leaves the note. Called just before the app ends, off the main thread.
    public static func write(_ date: Date, in folder: URL = folder()) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = ISO8601DateFormatter().string(from: date) + "\n"
        try? Data(line.utf8).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    /// The time in the note, if one was left; the note is removed. At launch.
    public static func take(in folder: URL = folder()) -> Date? {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let text = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ISO8601DateFormatter().date(from: text)
    }
}
