// SPDX-License-Identifier: Apache-2.0
// A stuck main thread under a cover ends the Testing edition; a beating one, or one with no cover up, never does.
import Foundation
import Testing
@testable import SafeSightMacTestingEdition

@Suite struct StallWatchdogTests {
    let limit = StallWatchdog.limit

    @Test func itQuitsOnlyWhenACoverIsUpAndTheMainThreadIsSilent() {
        // Main thread silent for longer than the limit, a cover up, the check on time: quit.
        #expect(StallWatchdog.shouldQuit(now: 100, lastBeat: 100 - limit - 0.1, lastCheck: 99, coverShown: true))
        // No cover: nobody is stuck behind anything.
        #expect(!StallWatchdog.shouldQuit(now: 100, lastBeat: 0, lastCheck: 99, coverShown: false))
        // Silent, but not yet for the limit.
        #expect(!StallWatchdog.shouldQuit(now: 100, lastBeat: 100 - limit + 0.5, lastCheck: 99, coverShown: true))
        // The check itself ran late (the Mac slept, App Nap, a debugger): wait and look again.
        #expect(!StallWatchdog.shouldQuit(now: 100, lastBeat: 0, lastCheck: 90, coverShown: true))
        // The first check has nothing to compare with.
        #expect(!StallWatchdog.shouldQuit(now: 100, lastBeat: 0, lastCheck: nil, coverShown: true))
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

    @Test func coversGoneMeansNoQuitEvenWhenStuck() {
        let clock = Clock(), quits = Count()
        let dog = StallWatchdog(clock: { clock.read() }) { quits.add() }
        dog.setCoverShown(false)
        for _ in 0..<30 { clock.advance(1); dog.check() }
        #expect(quits.value == 0)
    }
}
