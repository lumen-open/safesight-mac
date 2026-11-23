// SPDX-License-Identifier: Apache-2.0
// A stuck main thread under a cover ends the Testing edition; a main thread that answers, one with no cover up, or one
// held up with the whole process (a sleep, a paused virtual Mac, a debugger, a clock jump), never does.
import Foundation
import Testing
import SafeSightMacCore
@testable import SafeSightMacTestingEdition

@Suite struct StallWatchdogTests {
    let limit = StallWatchdog.limit

    @Test func itQuitsOnlyWhenACoverIsUpAndTheMainThreadIsSilent() {
        // Main thread silent for longer than the limit, a cover up: quit.
        #expect(StallWatchdog.shouldQuit(silence: limit + 0.1, coverShown: true))
        // No cover: nobody is stuck behind anything.
        #expect(!StallWatchdog.shouldQuit(silence: 100, coverShown: false))
        // Silent, but not yet for the limit.
        #expect(!StallWatchdog.shouldQuit(silence: limit - 0.5, coverShown: true))
    }

    @Test func silenceCountsOnlyTheWatchersOwnRunningTime() {
        var s = StallWatchdog.Silence(now: 0)
        // The first check has nothing to compare with.
        #expect(s.check(at: 0.5) == 0)
        // On time, no beat: the time since the last check counts in full.
        #expect(s.check(at: 1.5) == 1)
        #expect(s.check(at: 3.5) == 3)
        // Late (the Mac slept, App Nap, a debugger): one interval, not the gap.
        #expect(s.check(at: 90) == 4)
        // A beat since the last check starts again from it.
        s.beat(at: 90.4)
        #expect(abs(s.check(at: 91) - 0.6) < 1e-9)
        // A beat, then a late check: from the beat, but never more than one interval.
        s.beat(at: 92)
        #expect(s.check(at: 200) == 1)
        // A clock that went back counts nothing.
        #expect(s.check(at: 100) == 1)
        #expect(s.check(at: 101) == 2)
    }

    final class Clock: @unchecked Sendable {
        var now: TimeInterval = 1000
        let lock = NSLock()
        func read() -> TimeInterval { lock.withLock { now } }
        func advance(_ s: TimeInterval) { lock.withLock { now += s } }
    }

    /// The main queue, in the test's hands: questions wait until the test lets the main thread answer them.
    final class MainQueue: @unchecked Sendable {
        let lock = NSLock()
        var waiting: [@Sendable () -> Void] = []
        var asked = 0
        func ask(_ f: @escaping @Sendable () -> Void) { lock.withLock { waiting.append(f); asked += 1 } }
        /// The main thread is free: every waiting question is answered now.
        func answer() {
            let w = lock.withLock { () -> [@Sendable () -> Void] in defer { waiting = [] }; return waiting }
            w.forEach { $0() }
        }
        var pending: Int { lock.withLock { waiting.count } }
    }

    final class Activity: CoverActivity, @unchecked Sendable {
        let lock = NSLock()
        var held = false, begun = 0
        func begin() { lock.withLock { held = true; begun += 1 } }
        func end() { lock.withLock { held = false } }
    }

    final class Count: @unchecked Sendable {
        var n = 0
        let lock = NSLock()
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    struct Rig {
        let clock = Clock(), main = MainQueue(), quits = Count(), activity = Activity()
        let dog: StallWatchdog
        init(cover: Bool = true) {
            let clock = clock, main = main, quits = quits
            dog = StallWatchdog(clock: { clock.read() }, ask: { main.ask($0) }, activity: activity) { quits.add() }
            dog.setCoverShown(cover)
        }
        /// A healthy stretch: every second, a check; the main thread answers half a second after it, so the last beat
        /// is always half a second old when the next check comes.
        func healthy(seconds: Int) {
            for _ in 0..<seconds {
                clock.advance(0.5); main.answer()
                clock.advance(0.5); dog.check()
            }
        }
        /// The main thread blocked: checks go on every `every` seconds and nothing is answered. Returns the checks it
        /// took to end the app, or nil.
        func blocked(checks: Int, every: TimeInterval = 1) -> Int? {
            for i in 1...checks {
                clock.advance(every)
                if dog.check() { return i }
            }
            return nil
        }
    }

    @Test func aStuckMainThreadUnderACoverEndsTheAppAndAnAnsweringOneNever() {
        let r = Rig()
        r.healthy(seconds: 60)
        #expect(r.quits.value == 0)
        let took = r.blocked(checks: 12)
        #expect(took != nil && r.quits.value == 1, "ended within about \(Int(limit) + 1) seconds")
        #expect((took ?? 0) >= Int(limit), "not before the limit")
    }

    @Test func coversGoneMeansNoQuitEvenWhenStuck() {
        let r = Rig(cover: false)
        _ = r.blocked(checks: 30)
        #expect(r.quits.value == 0)
    }

    // A main-run-loop timer can be held back by macOS (App Nap, timer coalescing) while the main thread is fine. The
    // beat is the main queue's answer to each check, not a timer: no beat from anything else for a minute, every
    // question answered, and nothing ends.
    @Test func aHeldBackTimerIsNotAStall() {
        let r = Rig()
        r.healthy(seconds: 5)
        for _ in 0..<60 {
            r.clock.advance(0.01); r.main.answer()
            r.clock.advance(0.99); r.dog.check()
        }
        #expect(r.quits.value == 0)
    }

    // A main thread that is really blocked does not answer: it still ends, and only one question waits at a time.
    @Test func aBlockedMainThreadStillEndsAndQuestionsDoNotPileUp() {
        let r = Rig()
        r.healthy(seconds: 5)
        let asked = r.main.asked
        let took = r.blocked(checks: 20)
        #expect(took != nil)
        #expect(r.main.pending == 1)
        #expect(r.main.asked - asked <= 1)
    }

    // While a cover is up the activity that keeps App Nap off is held, once; it goes with the last cover and on stop.
    @Test func theActivityIsHeldOnlyWhileACoverIsUp() {
        let r = Rig(cover: false)
        #expect(!r.activity.held)
        r.dog.setCoverShown(true); r.dog.setCoverShown(true)
        #expect(r.activity.held && r.activity.begun == 1)
        r.dog.setCoverShown(false)
        #expect(!r.activity.held)
        r.dog.setCoverShown(true)
        r.dog.stop()
        #expect(!r.activity.held && r.activity.begun == 2)
        #expect(NoNapWhileCovered.options == .userInitiatedAllowingIdleSystemSleep)
        #expect(!NoNapWhileCovered.options.contains(.idleSystemSleepDisabled))
        #expect(!NoNapWhileCovered.options.contains(.idleDisplaySleepDisabled))
    }

    // The live run's exit: the virtual Mac was paused 81 s under a cover; at wake the watchdog's check ran first and
    // late, and the main thread was busy for a moment (displays, capture restarting) before it answered. The late
    // check was forgiven but the beat from before the gap stayed the last one, so the next check, on time, counted the
    // whole gap as silence and ended the app.
    @Test func aSleepThenABusyMainThreadAtWakeNeverEndsTheApp() {
        let r = Rig()
        r.healthy(seconds: 60)
        r.clock.advance(81)
        #expect(!r.dog.check())
        // The main thread is busy for 1.5 s, with one check on time.
        r.clock.advance(1); #expect(!r.dog.check(), "the sleep counted as main-thread silence")
        r.clock.advance(0.5); r.main.answer()
        r.clock.advance(0.5); #expect(!r.dog.check())
        r.healthy(seconds: 60)
        #expect(r.quits.value == 0)
    }

    // Every kind of hold-up the process can have: a short sleep, a long one, a paused virtual Mac (minutes), a debugger
    // (an hour). Going in, the last beat is half a second old; the late check adds one second; so a main thread busy
    // for up to 6.5 s after wake keeps the app running, and one blocked for 7 s ends it.
    @Test func noPauseOfAnyLengthEndsTheAppWhileTheMainThreadComesBackInTime() {
        for pause in [3.0, 9, 81, 600, 3600] {
            for busy in [0, 1, 3, 6, 7] {
                let r = Rig()
                r.healthy(seconds: 10)
                r.clock.advance(pause)
                r.dog.check()
                for _ in 0..<busy { r.clock.advance(1); r.dog.check() }
                r.main.answer()
                r.healthy(seconds: 20)
                #expect(r.quits.value == (busy >= 7 ? 1 : 0), "pause \(pause) s, busy \(busy) s")
            }
        }
    }

    // Several late checks in a row (the Mac dozing in and out, App Nap), the main thread answering in between: each
    // late check counts as one interval, never as the whole gap.
    @Test func repeatedLateChecksNeverAddUpToAStall() {
        let r = Rig()
        r.healthy(seconds: 10)
        for _ in 0..<5 {
            r.clock.advance(30); r.dog.check()
            r.clock.advance(0.4); r.main.answer()
        }
        r.healthy(seconds: 10)
        #expect(r.quits.value == 0)
    }

    // A monotonic clock never runs backwards, but if one ever did (or a wall clock were wired in by mistake and set
    // back), nothing is counted as silence and nothing ends.
    @Test func aClockThatJumpsBackwardsEndsNothing() {
        let r = Rig()
        r.healthy(seconds: 10)
        r.clock.advance(-3600)
        r.dog.check()
        r.clock.advance(1); r.dog.check()
        r.clock.advance(0.5); r.main.answer()
        r.healthy(seconds: 20)
        #expect(r.quits.value == 0)
    }

    // A real stall is still found after a sleep: the main thread never comes back after wake, and the app ends once
    // the main thread has been silent for the limit while the watchdog itself ran on time.
    @Test func aRealStallAfterWakeStillEndsTheApp() {
        let r = Rig()
        r.healthy(seconds: 10)
        r.clock.advance(81)
        r.dog.check()
        let took = r.blocked(checks: 30)
        #expect(r.quits.value == 1)
        #expect(took.map { $0 >= Int(limit) - 2 && $0 <= Int(limit) } == true, "ended \(took ?? -1) s after wake")
    }

    // A main thread that is stuck before the sleep and stays stuck after it: still ended, at most one interval of the
    // sleep counted.
    @Test func aStallThatSpansASleepStillEndsTheApp() {
        let r = Rig()
        r.healthy(seconds: 10)
        #expect(r.blocked(checks: 4) == nil)
        r.clock.advance(81); r.dog.check()
        let took = r.blocked(checks: 30)
        #expect(r.quits.value == 1)
        #expect((took ?? 99) <= Int(limit) - 4, "ended \(took ?? -1) s after wake")
    }

    // Every check late, and no answer at all: still ended, each late check counting one interval, so after about nine
    // of them (9 x the gap).
    @Test func aStallWhenEveryCheckRunsLateStillEnds() {
        for gap in [3.0, 10, 60] {
            let r = Rig()
            r.healthy(seconds: 10)
            let took = r.blocked(checks: 20, every: gap)
            #expect(took != nil && took! <= Int(limit) + 1, "gap \(gap) s: ended after \(took ?? -1) checks")
        }
    }

    // A stall on a Mac so loaded that every other check runs late: it still ends.
    @Test func aStallOnAMacWhereChecksRunLateStillEnds() {
        let r = Rig()
        r.healthy(seconds: 10)
        var checks = 0
        while r.quits.value == 0, checks < 40 {
            r.clock.advance(checks % 2 == 0 ? 1 : 4); r.dog.check(); checks += 1
        }
        #expect(r.quits.value == 1, "ended after \(checks) checks")
    }

    // The note the watchdog leaves: the time only, read once at the next launch, then gone.
    @Test func theNoteSaysWhenItEndedItselfOnceAndHoldsNothingElse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stallnote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(StallNote.take(in: folder) == nil)
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        StallNote.write(when, in: folder)
        let text = try String(contentsOf: folder.appendingPathComponent(StallNote.fileName), encoding: .utf8)
        #expect(text == ISO8601DateFormatter().string(from: when) + "\n")
        #expect(StallNote.take(in: folder) == when)
        #expect(StallNote.take(in: folder) == nil)
        #expect(StallNote.folder().lastPathComponent == AppText.productName)
    }
}
