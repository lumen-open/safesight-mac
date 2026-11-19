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
}
