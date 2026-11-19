// SPDX-License-Identifier: Apache-2.0
// The Testing report: numbers a helper can read and copy by hand into a GitHub issue, so "it covered something" or "it
// made my Mac slow" comes with facts. It is shown in a window as text and kept in memory only: nothing is written to
// a file, put on the clipboard by the app, or sent anywhere.
//
// It holds only: the Mac's model and macOS version, the displays' sizes and how they are arranged, the edition, build
// and models, timings, counts of covers and faults, the CPU the app used, the Mac's heat and Low Power Mode, whether ⌃⌥⌘Q is the app's, and the note the
// helper types. Never a picture, a window title, an app's name, an address, or anything about what was covered.
import Foundation
import SafeSightMacCore

/// Counts and timings, gathered on the main thread as plans arrive. Bounded: the last `keep` timings.
public struct TestingStats: Sendable {
    public static let keep = 5000
    /// Frames judged: with new pixels, and "nothing changed" frames on which covers waiting to lift were judged again.
    public private(set) var judged = 0
    public private(set) var judgedNew = 0
    public private(set) var judgedIdle = 0
    /// Frames captured, by the status the capture gave them (complete, idle, started, blank, suspended, stopped).
    public private(set) var captured: [String: Int] = [:]
    /// Updates actually drawn on screen (every plan, early or final, after the display rule), and how many of them had a
    /// cover or a blur on some display. These count what was on screen, not only the final plan of each frame.
    public private(set) var drawn = 0
    public private(set) var framesWithCovers = 0
    /// Picture covers and blurs drawn, summed over the updates drawn.
    public private(set) var coversDrawn = 0
    public private(set) var blursDrawn = 0
    /// Whole-display covers drawn, by why, counted each time a display becomes covered whole on screen.
    public private(set) var wholeDisplay: [String: Int] = [:]
    /// What is on screen now: per display, covered whole (why), or how many covers and blurs.
    public private(set) var now: [UInt32: String] = [:]
    /// How often the slow paths fired: frames whose large changed parts were blurred at once, pictures blurred first
    /// because judging them would take too long, parts left for the next frame, entries left unjudged, covers judged on
    /// their own, and changes covered because they waited too long to be judged (on how many timer ticks).
    public private(set) var blurAtOnce = 0
    public private(set) var coveredFirst = 0
    public private(set) var leftForLater = 0
    public private(set) var unjudgedEntries = 0
    public private(set) var rechecks = 0
    public private(set) var waitingCovers = 0
    private(set) var judgeMs: [Double] = []
    private(set) var latencyMs: [Double] = []
    private var wholeNow: [UInt32: String] = [:]

    public init() {}

    /// What one judged frame cost and what the slow paths did (counts only).
    public struct Pass: Sendable {
        public var idle = false, blurAtOnce = false
        public var coveredFirst = 0, leftForLater = 0, unjudged = 0, rechecks = 0
        public init(idle: Bool = false, blurAtOnce: Bool = false, coveredFirst: Int = 0, leftForLater: Int = 0, unjudged: Int = 0, rechecks: Int = 0) {
            self.idle = idle; self.blurAtOnce = blurAtOnce; self.coveredFirst = coveredFirst; self.leftForLater = leftForLater
            self.unjudged = unjudged; self.rechecks = rechecks
        }
    }

    /// One judged frame: how long judging took, how long from capture to the plan, and what its slow paths did.
    public mutating func record(display: UInt32, judgeMs j: Double, latencyMs l: Double, pass: Pass = Pass()) {
        judged += 1
        if pass.idle { judgedIdle += 1 } else { judgedNew += 1 }
        if pass.blurAtOnce { blurAtOnce += 1 }
        coveredFirst += pass.coveredFirst; leftForLater += pass.leftForLater; unjudgedEntries += pass.unjudged; rechecks += pass.rechecks
        judgeMs.append(j); latencyMs.append(l)
        if judgeMs.count > Self.keep { judgeMs.removeFirst(judgeMs.count - Self.keep) }
        if latencyMs.count > Self.keep { latencyMs.removeFirst(latencyMs.count - Self.keep) }
    }

    /// One frame captured, with the status the capture gave it.
    public mutating func recordCaptured(_ status: String) { captured[status, default: 0] += 1 }

    /// One display as drawn: covered whole (why), or how many covers and blurs.
    public struct Shown: Sendable {
        public var display: UInt32, whole: String?, covers: Int, blurs: Int
        public init(display: UInt32, whole: String?, covers: Int, blurs: Int) {
            self.display = display; self.whole = whole; self.covers = covers; self.blurs = blurs
        }
    }

    /// One update drawn on screen, every display in it.
    public mutating func recordDrawn(_ shown: [Shown]) {
        drawn += 1
        if shown.contains(where: { $0.whole != nil || $0.covers + $0.blurs > 0 }) { framesWithCovers += 1 }
        var seen: Set<UInt32> = []
        for d in shown {
            seen.insert(d.display)
            coversDrawn += d.covers; blursDrawn += d.blurs
            if let w = d.whole, wholeNow[d.display] != w { wholeDisplay[w, default: 0] += 1 }
            wholeNow[d.display] = d.whole
            now[d.display] = d.whole.map { "covered whole (\($0))" } ?? (d.covers + d.blurs == 0 ? "nothing covered" : "\(d.covers) covers, \(d.blurs) blurs")
        }
        for id in wholeNow.keys where !seen.contains(id) { wholeNow[id] = nil; now[id] = nil }
    }

    /// A timer tick on which changes that waited too long to be judged were covered (or a display covered whole for it).
    public mutating func recordWaitingCover() { waitingCovers += 1 }

    /// The value below which `p` (0 to 1) of the values fall, or nil with no values.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }

    func summary(_ v: [Double]) -> String {
        guard let p50 = Self.percentile(v, 0.5), let p90 = Self.percentile(v, 0.9), let p99 = Self.percentile(v, 0.99) else { return "none yet" }
        return String(format: "median %.0f ms, 90%% %.0f ms, 99%% %.0f ms (last %d)", p50, p90, p99, v.count)
    }
}

/// Facts about the Mac and this build, read once.
public struct TestingFacts: Sendable {
    public struct Display: Sendable {
        public var width: Int, height: Int, scale: Double, builtIn: Bool, mirrored: Bool
        public init(width: Int, height: Int, scale: Double, builtIn: Bool, mirrored: Bool) {
            self.width = width; self.height = height; self.scale = scale; self.builtIn = builtIn; self.mirrored = mirrored
        }
    }
    public var macModel: String, macOS: String, edition: String, version: String, executableSHA: String, modelsStamp: String
    public var displays: [Display]
    public var shortcutRegistered: Bool
    public init(macModel: String, macOS: String, edition: String, version: String, executableSHA: String, modelsStamp: String,
                displays: [Display], shortcutRegistered: Bool) {
        self.macModel = macModel; self.macOS = macOS; self.edition = edition; self.version = version
        self.executableSHA = executableSHA; self.modelsStamp = modelsStamp; self.displays = displays
        self.shortcutRegistered = shortcutRegistered
    }

    /// The Mac's model identifier (such as "Mac14,2"), from sysctl.
    public static func macModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    /// The CPU time this process has used, in seconds (user and system).
    public static func cpuSeconds() -> Double {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return 0 }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// How warm the Mac is and whether Low Power Mode is on, as macOS tells any app. The battery's charge is not read:
    /// that needs IOKit, which the Testing app may not link.
    public static func power(_ info: ProcessInfo = .processInfo) -> String {
        let heat: String
        switch info.thermalState {
        case .nominal: heat = "nominal"
        case .fair: heat = "fair"
        case .serious: heat = "serious"
        case .critical: heat = "critical"
        @unknown default: heat = "unknown"
        }
        return "heat \(heat), Low Power Mode " + (info.isLowPowerModeEnabled ? "on" : "off")
    }
}

public enum TestingReport {
    /// The report as plain text. `running`: seconds since covering started; `cpu`: CPU seconds used in that time.
    public static func text(facts f: TestingFacts, stats s: TestingStats, running: TimeInterval, cpu: Double, note: String,
                            power: String? = nil) -> String {
        var lines = [AppText.testingReportTitle, ""]
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Note: " + (n.isEmpty ? "(none)" : n))
        lines.append("")
        lines.append("Mac: \(f.macModel), macOS \(f.macOS)")
        let shown = f.displays.map { d in
            "\(d.width) x \(d.height) pt at \(String(format: "%.0f", d.scale))x\(d.builtIn ? ", built in" : ", external")\(d.mirrored ? ", mirrored" : "")"
        }
        lines.append("Displays: \(f.displays.count)" + (shown.isEmpty ? "" : " (" + shown.joined(separator: "; ") + ")"))
        lines.append("Build: \(f.edition) \(f.version), app \(String(f.executableSHA.prefix(12))), models \(String(f.modelsStamp.prefix(12)))")
        lines.append("⌃⌥⌘Q: " + (f.shortcutRegistered ? "registered" : "not registered (another app holds it)"))
        lines.append("")
        let minutes = running / 60
        lines.append(String(format: "Covering for %.1f min; frames judged %d (%.1f a second)", minutes, s.judged,
                            running > 0 ? Double(s.judged) / running : 0))
        lines.append(String(format: "CPU: %.0f%% of one core on average", running > 0 ? 100 * cpu / running : 0))
        if let power { lines.append("Power: " + power) }
        lines.append("Capture to cover plan: " + s.summary(s.latencyMs))
        lines.append("Judging a frame: " + s.summary(s.judgeMs))
        let order = ["complete", "idle", "started", "blank", "suspended", "stopped"]
        let caps = s.captured.sorted { (order.firstIndex(of: $0.key) ?? 9, $0.key) < (order.firstIndex(of: $1.key) ?? 9, $1.key) }.map { "\($0.key) \($0.value)" }
        lines.append("Frames captured: " + (caps.isEmpty ? "none" : caps.joined(separator: ", ")))
        lines.append("Frames judged: \(s.judgedNew) with new pixels, \(s.judgedIdle) judged again with nothing new")
        lines.append("Updates drawn: \(s.drawn)")
        lines.append("Frames with a cover or blur: \(s.framesWithCovers)")
        lines.append("Covers and blurs drawn (summed over updates): \(s.coversDrawn) covers, \(s.blursDrawn) blurs")
        let now = s.now.sorted { $0.key < $1.key }.map { $0.value }
        lines.append("On screen now: " + (now.isEmpty ? "nothing drawn" : now.joined(separator: "; ")))
        let whole = s.wholeDisplay.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        lines.append("Whole-display covers: " + (whole.isEmpty ? "none" : whole.joined(separator: ", ")))
        lines.append("Slow paths: blurred at once \(s.blurAtOnce) frames, blurred first \(s.coveredFirst) pictures, left for later \(s.leftForLater) parts, unjudged \(s.unjudgedEntries) entries, covers judged on their own \(s.rechecks), waiting covers \(s.waitingCovers) ticks")
        return lines.joined(separator: "\n")
    }
}
