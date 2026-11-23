// SPDX-License-Identifier: Apache-2.0
// LAB ONLY (compiled only with SAFESIGHTMAC_LAB, never in a release or Testing build): an event log for diagnosing the
// cover on a real screen. It writes, inside the app's own sandbox container (Library/Application Support/SafeSight
// Mac/lab-events.log; outside the sandbox, the same folder in the home folder), counts, timings, frame statuses,
// window layers and rectangles in points. Never a pixel, a window title, an app's name or an address. Not in Library/Caches: macOS empties a container's caches when the disk runs low (cache_delete), and
// did so in the middle of a run. Lines reach the file within about a quarter of a second, so `tail -f` keeps up.
#if SAFESIGHTMAC_LAB
import Foundation
import SafeSightMacCore
import SafeSightMacWatcher

final class LabEventLog: @unchecked Sendable {
    static let shared = LabEventLog()
    private let queue = DispatchQueue(label: "safesightmac.lab.log", qos: .userInitiated)
    private var handle: FileHandle?
    private var buffer: [String] = []
    /// The log stops growing at this size (a last line says so).
    static let maxBytes = 64 << 20
    private var written = 0
    private let start = ProcessInfo.processInfo.systemUptime
    /// Lines wait at most this long before they are written (seconds).
    static let flushEvery: TimeInterval = 0.25
    private var lastFlush = ProcessInfo.processInfo.systemUptime

    private init() {
        let fm = FileManager.default
        let folder = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent(AppText.productName, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("lab-events.log")
        fm.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        // A strict timer, so macOS does not put it off to save energy (App Nap can hold ordinary timers back by many
        // seconds; the last run's `tail` was about 30 s behind). Lab builds only.
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + Self.flushEvery, repeating: Self.flushEvery, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }
    private var timer: DispatchSourceTimer?

    /// One line, stamped with seconds since the app started.
    func log(_ s: @autoclosure () -> String) {
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime - start) + s()
        queue.async {
            self.buffer.append(line)
            // Written at once when the last write is old enough, so a timer that runs late never holds lines back.
            if ProcessInfo.processInfo.systemUptime - self.lastFlush >= Self.flushEvery { self.flush() }
        }
    }

    private func flush() {
        lastFlush = ProcessInfo.processInfo.systemUptime
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
