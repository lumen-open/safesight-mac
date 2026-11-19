// SPDX-License-Identifier: Apache-2.0
// A capture that has been closed never starts again, so a start still on its way when the app stops watching
// (Pause, Quit or Remove while the models load) cannot begin capturing or report displays to cover. The screen is
// never captured here: a closed capture returns before it asks ScreenCaptureKit for anything.
import Foundation
import Testing
@testable import SafeSightMacCapture
@testable import SafeSightMacWatcher

final class RecordingSink: CaptureSink, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var recorded: [String] { lock.withLock { calls } }
    func capture(_ frame: CapturedFrame) { lock.withLock { calls.append("frame") } }
    func captureFault(display: UInt32, cause: FaultCause) { lock.withLock { calls.append("fault") } }
    func captureDisplays(_ displays: [DisplayDescriptor]) { lock.withLock { calls.append("displays") } }
}

@Suite struct CaptureCloseTests {
    @Test func aClosedCaptureNeverStartsAgain() async {
        let sink = RecordingSink()
        let capture = ScreenCapture(sink: sink)
        await capture.close()
        await capture.start()
        await capture.start()
        #expect(await capture.runningDisplays.isEmpty)
        #expect(sink.recorded.isEmpty, "no display reported, so nothing to cover")
    }
}
