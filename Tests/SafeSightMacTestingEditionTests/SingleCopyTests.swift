// SPDX-License-Identifier: Apache-2.0
// One copy of the Testing edition at a time: a second copy finds the first.
import Foundation
import Testing
@testable import SafeSightMacTestingEdition

@Suite struct SingleCopyTests {
    @Test func aSecondCopyFindsTheFirst() {
        #expect(SingleCopy.anotherCopyRunning(bundleID: "org.example.t", ownPID: 10, running: [10, 22]))
        #expect(!SingleCopy.anotherCopyRunning(bundleID: "org.example.t", ownPID: 10, running: [10]))
        #expect(!SingleCopy.anotherCopyRunning(bundleID: "org.example.t", ownPID: 10, running: []))
        #expect(!SingleCopy.anotherCopyRunning(bundleID: nil, ownPID: 10, running: [22]), "no bundle, nothing to compare")
    }

    /// A lab build and a normal build of the Testing edition both register ⌃⌥⌘Q: either finds the other.
    @Test func otherBuildsOfTheTestingEditionAreFound() {
        let running: [(id: String?, pid: pid_t)] = [("org.example.safesightmac.testing", 10), ("org.example.safesightmac.lab.testing", 22),
                                                    ("org.example.other.testing", 30), ("org.example.safesightmac.app", 40), (nil, 50)]
        #expect(SingleCopy.otherTestingCopies(ownID: "org.example.safesightmac.testing", ownPID: 10, running: running) == [22])
        #expect(SingleCopy.otherTestingCopies(ownID: "org.example.safesightmac.lab.testing", ownPID: 22, running: running) == [10])
        #expect(SingleCopy.otherTestingCopies(ownID: "org.example.safesightmac.testing", ownPID: 10, running: [("org.example.safesightmac.testing", 10)]).isEmpty)
        #expect(SingleCopy.otherTestingCopies(ownID: nil, ownPID: 10, running: running).isEmpty)
    }
}
