// SPDX-License-Identifier: Apache-2.0
// LAB ONLY (compiled only with SAFESIGHTMAC_LAB, never in a release or Testing build): an event log for diagnosing the
// cover on a real screen. It writes, inside the app's own sandbox container (Library/Caches/lab-events.log), counts,
// timings, frame statuses, window layers and rectangles in points. Never a pixel, a window title, an app's name or
// an address.
#if SAFESIGHTMAC_LAB
import Foundation
import SafeSightMacWatcher

final class LabEventLog: @unchecked Sendable {
    static let shared = LabEventLog()
    private let queue = DispatchQueue(label: "safesightmac.lab.log", qos: .utility)
    private var handle: FileHandle?
    private var buffer: [String] = []
    /// The log stops growing at this size (a last line says so).
    static let maxBytes = 64 << 20
    private var written = 0
    private let start = ProcessInfo.processInfo.systemUptime

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = caches.appendingPathComponent("lab-events.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }
    private var timer: DispatchSourceTimer?

    /// One line, stamped with seconds since the app started.
    func log(_ s: @autoclosure () -> String) {
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime - start) + s()
        queue.async { self.buffer.append(line) }
    }

    private func flush() {
        guard !buffer.isEmpty, let h = handle else { return }
        var data = Data((buffer.joined(separator: "\n") + "\n").utf8)
        buffer = []
        if written + data.count > Self.maxBytes {
            data = Data("log full: nothing more is written\n".utf8)
            handle = nil
        }
        written += data.count
        h.write(data)
    }

    /// The share of a display a plan hides (whole: 1), on an 8-point grid. Geometry only.
    static func coveredShare(_ p: CoverPlan) -> Double {
        if p.wholeDisplay != nil { return 1 }
        let b = p.display.bounds, step: CGFloat = 8
        let cols = Int((b.width / step).rounded(.up)), rows = Int((b.height / step).rounded(.up))
        guard cols > 0, rows > 0, !p.items.isEmpty else { return 0 }
        var hit = 0
        for j in 0..<rows { for i in 0..<cols {
            let c = CGPoint(x: b.minX + (CGFloat(i) + 0.5) * step, y: b.minY + (CGFloat(j) + 0.5) * step)
            if p.items.contains(where: { $0.rect.contains(c) }) { hit += 1 }
        } }
        return Double(hit) / Double(cols * rows)
    }

    static func rect(_ r: CGRect) -> String { String(format: "%.0f,%.0f,%.0f,%.0f", r.minX, r.minY, r.width, r.height) }
}
#endif
