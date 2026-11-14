// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import Testing
@testable import FernwickWatcher

@Suite struct StatusTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))

    @Test func withoutPermissionTheStatusSaysSo() {
        let s = WatcherStatus.compute(permission: false, paused: nil, pausedIndefinitely: false, detectorFailed: false, plans: [], running: false)
        #expect(s == .needsScreenRecording)
        #expect(s.title == "Needs Screen Recording")
    }

    @Test func runningWithJudgedDisplaysIsOn() {
        let s = WatcherStatus.compute(permission: true, paused: nil, pausedIndefinitely: false, detectorFailed: false, plans: [.clear(d)], running: true)
        #expect(s == .on && s.title == "Covering: on")
    }

    @Test func aWholeDisplayCoverIsReported() {
        let s = WatcherStatus.compute(permission: true, paused: nil, pausedIndefinitely: false, detectorFailed: false,
                                      plans: [.clear(d), .covered(d, because: .streamStopped)], running: true)
        #expect(s == .displayCovered(.streamStopped))
    }

    @Test func pauseAndDetectorFailureWin() {
        #expect(WatcherStatus.compute(permission: true, paused: Date(), pausedIndefinitely: false, detectorFailed: true, plans: [], running: false).title
                .hasPrefix("Paused"))
        #expect(WatcherStatus.compute(permission: true, paused: nil, pausedIndefinitely: false, detectorFailed: true, plans: [], running: true) == .detectorUnavailable)
    }
}
