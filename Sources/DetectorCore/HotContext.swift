// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Hot contexts: a window with a confirmed hit (both families) in the last 15 minutes, or a grid with
// several low-level tiles. While hot, every picture under 128 px stays blurred until cleared.
import Foundation

final class HotContexts {
    private var until: [UInt64: Date] = [:]
    let duration: TimeInterval = 15 * 60
    func mark(_ w: UInt64, _ now: Date) { until[w] = now.addingTimeInterval(duration) }
    func isHot(_ w: UInt64, _ now: Date) -> Bool { (until[w] ?? .distantPast) > now }
}
