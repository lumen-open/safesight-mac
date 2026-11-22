// SPDX-License-Identifier: Apache-2.0
// A stuck main thread under a cover ends the Testing edition; a beating one, one with no cover up, or one held up
// with the whole process (a sleep, a paused virtual Mac, a debugger, a clock jump), never does.
import Foundation
import Testing
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

    final class Count: @unchecked Sendable {
        var n = 0
        let lock = NSLock()
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test func aStuckMainThreadUnderACoverEndsTheAppAndABeatingOneNever() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(true)
        // A healthy minute: the main thread beats every half second, the check runs every second.
        for _ in 0..<60 {
            clock.advance(0.5); dog.beat()
            clock.advance(0.5); dog.beat()
            dog.check()
        }
        #expect(quits.value == 0)
        // The main thread stops; checks go on every second.
        var fired = false
        for _ in 0..<12 where !fired {
            clock.advance(1)
            fired = dog.check()
        }
        #expect(fired && quits.value == 1, "ended within about \(Int(limit) + 1) seconds")
    }

    /// A healthy minute under a cover: the main thread beats every half second, the check runs every second.
    func healthy(_ dog: StallWatchdog, _ clock: Clock, seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(0.5); dog.beat()
            clock.advance(0.5); dog.beat()
            dog.check()
        }
    }

    // The live run's exit: the Mac (or the virtual Mac) slept 81 s under a cover; at wake the watchdog's check ran
    // first and late, and the main thread was busy for a moment (displays, capture restarting) before it beat again.
    // The late check was forgiven but the beat from before the sleep stayed the last one, so the next check, on time,
    // counted the whole sleep as silence and ended the app.
    @Test func aSleepThenABusyMainThreadAtWakeNeverEndsTheApp() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(true)
        healthy(dog, clock, seconds: 60)
        // Asleep: no beat, no check.
        clock.advance(81)
        // Awake: the check comes first, late.
        #expect(!dog.check())
        // The main thread is busy for 1.5 s, with two checks on time.
        clock.advance(1); #expect(!dog.check(), "the sleep counted as main-thread silence")
        clock.advance(0.5); dog.beat()
        clock.advance(0.5); #expect(!dog.check())
        healthy(dog, clock, seconds: 60)
        #expect(quits.value == 0)
    }

    // The same with every kind of hold-up the process can have: a short sleep, a long one, a paused virtual Mac
    // (minutes), a debugger (an hour), and a main thread that stays busy for up to 7 s after it.
    @Test func noPauseOfAnyLengthEndsTheAppWhileTheMainThreadComesBackInTime() {
        for pause in [3.0, 9, 81, 600, 3600] {
            for busy in [0, 1, 3, 7] {
                let clock = Clock(), quits = Count()
                let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
                dog.setCoverShown(true)
                healthy(dog, clock, seconds: 10)
                clock.advance(pause)
                dog.check()
                for _ in 0..<busy { clock.advance(1); dog.check() }
                dog.beat()
                healthy(dog, clock, seconds: 20)
                #expect(quits.value == 0, "pause \(pause) s, busy \(busy) s")
            }
        }
    }

    // Several late checks in a row (the Mac dozing in and out, App Nap), the main thread silent in between: each late
    // check counts as one interval, never as the whole gap.
    @Test func repeatedLateChecksNeverAddUpToAStall() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(true)
        healthy(dog, clock, seconds: 10)
        for _ in 0..<5 {
            clock.advance(30); dog.check()
            clock.advance(0.4); dog.beat()
        }
        healthy(dog, clock, seconds: 10)
        #expect(quits.value == 0)
    }

    // A monotonic clock never runs backwards, but if one ever did (or a wall clock were wired in by mistake and set
    // back), nothing is counted as silence and nothing ends.
    @Test func aClockThatJumpsBackwardsEndsNothing() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(true)
        healthy(dog, clock, seconds: 10)
        clock.advance(-3600)
        dog.check()
        clock.advance(1); dog.check()
        clock.advance(0.5); dog.beat()
        healthy(dog, clock, seconds: 20)
        #expect(quits.value == 0)
    }

    // A real stall is still found after a sleep: the main thread never comes back after wake, and the app ends once
    // the main thread has been silent for the limit while the watchdog itself ran on time.
    @Test func aRealStallAfterWakeStillEndsTheApp() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(true)
        healthy(dog, clock, seconds: 10)
        clock.advance(81)
        dog.check()
        var seconds = 0
        while quits.value == 0, seconds < 30 { clock.advance(1); dog.check(); seconds += 1 }
        #expect(quits.value == 1)
        #expect(seconds >= Int(limit) - 1 && seconds <= Int(limit) + 2, "ended \(seconds) s after wake")
    }

    // A main thread that is stuck before the sleep and stays stuck after it: still ended, at most one interval of the
    // sleep counted, so within the limit of time the watchdog was awake.
    @Test func aStallThatSpansASleepStillEndsTheApp() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(true)
        healthy(dog, clock, seconds: 10)
        for _ in 0..<4 { clock.advance(1); dog.check() }
        #expect(quits.value == 0)
        clock.advance(81); dog.check()
        var seconds = 0
        while quits.value == 0, seconds < 30 { clock.advance(1); dog.check(); seconds += 1 }
        #expect(quits.value == 1)
        #expect(seconds <= Int(limit) - 4 + 1, "ended \(seconds) s after wake")
    }

    // A stall on a Mac so loaded that every other check runs late: it still ends, each late check counting one interval.
    @Test func aStallOnAMacWhereChecksRunLateStillEnds() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(true)
        healthy(dog, clock, seconds: 10)
        var checks = 0
        while quits.value == 0, checks < 40 {
            clock.advance(checks % 2 == 0 ? 1 : 4); dog.check(); checks += 1
        }
        #expect(quits.value == 1, "ended after \(checks) checks")
    }

    @Test func coversGoneMeansNoQuitEvenWhenStuck() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(false)
        for _ in 0..<30 { clock.advance(1); dog.check() }
        #expect(quits.value == 0)
    }
}
