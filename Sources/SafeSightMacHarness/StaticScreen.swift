// SPDX-License-Identifier: Apache-2.0
// LAB ONLY: a static screen, on a slow Mac, through the real cover layer. One harmless screenshot (a desktop, say) is
// the screen; it never changes. Frames arrive as a capture stream sends them for a still screen (`--frames idle`:
// "nothing changed"; `empty`: complete frames with no changed area; `none`: no frame after the first). The detector is
// slowed down by a fixed time per model judgement (`--slow-ms`), so a fast Mac can stand in for a slow one. It prints,
// every second, what the final plan and the provisional plans drew, and when the screen settled to no cover at all.
//
//   safesightmac-harness static FILE --models DIR [--slow-ms 25] [--seconds 60] [--fps 4] [--frames idle|empty|none]
//                                     [--windows FILE] [--scale 2]
//   (--windows: one window per line, front to back: "layer pid x,y,w,h" in global points)
// Lab switches, by environment: STATIC_BUDGET (judgements a second; default the register's), STATIC_WALL (ms a frame may
// judge for), STATIC_CALLS=1 (every judge call: area, budget, judgements, entries), STATIC_HELD=1 (every held cover, each
// second). Counts and rectangles only.
#if SAFESIGHTMAC_LAB
import CoreGraphics
import DetectorCore
import Foundation
import Preprocess
import SafeSightMacWatcher

/// A judge that takes `msPerJudgement` longer for every model judgement it makes (a slow Mac without a Neural Engine).
final class SlowJudger: Judging {
    let inner: Judging
    let msPerJudgement: Double
    init(_ inner: Judging, msPerJudgement: Double) { self.inner = inner; self.msPerJudgement = msPerJudgement }
    /// Entries left unjudged, by pass, and calls, since last read.
    var overloadByPass: [String: Int] = [:], calls = 0, budgets = 0, entries = 0
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        let v = inner.judgeArea(frame, context: context, within: area, budget: budget, progress: progress)
        calls += 1; budgets += budget; entries += v.regions.count
        if ProcessInfo.processInfo.environment["STATIC_CALLS"] == "1" {
            print("        call ctx=\(String(context.windowID, radix: 16)) area=\(area.x),\(area.y),\(area.w),\(area.h) budget=\(budget) judged=\(v.judgements) entries=\(v.regions.count) ovl=\(v.overloaded) notClear=\(v.regions.filter { $0.display != .clear && $0.reason != .overload }.count)")
        }
        for r in v.regions where r.reason == .overload { overloadByPass["\(r.pass)", default: 0] += 1 }
        if v.judgements > 0 { usleep(useconds_t(Double(v.judgements) * msPerJudgement * 1000)) }
        return v
    }
    func setRule(_ rule: DetectorRule) { inner.setRule(rule) }
    func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]? { inner.pictureRegions(frame, within: area) }
}

enum StaticScreen {
    struct Settings {
        var slowMs = 25.0
        var seconds = 60.0
        var fps = 4.0
        var frames = "idle"
        var windows: String?
    }

    static func windows(_ path: String?, display: CGRect) -> WindowSnapshot {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return WindowSnapshot(windows: [], time: 0) }
        var out: [WindowInfo] = []
        for (i, line) in text.split(separator: "\n").enumerated() {
            let f = line.split(separator: " ")
            guard f.count == 3, let layer = Int(f[0]), let pid = Int32(f[1]) else { continue }
            let n = f[2].split(separator: ",").compactMap { Double($0) }
            guard n.count == 4 else { continue }
            out.append(WindowInfo(number: UInt32(100 + i), ownerPID: pid, layer: layer, bounds: CGRect(x: n[0], y: n[1], width: n[2], height: n[3])))
        }
        return WindowSnapshot(windows: out, time: 0)
    }

    static func run(detector: Detector, file: String, scale: CGFloat, s: Settings) {
        guard let img = ImageLoading.load(URL(fileURLWithPath: file)) else { fail("unreadable image: \(file)") }
        let size = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
        let display = DisplayDescriptor(id: 1, bounds: CGRect(origin: .zero, size: size))
        let map = CaptureMap(displayBounds: display.bounds, contentRect: display.bounds, contentScale: 1, scaleFactor: scale,
                             pixelWidth: img.width, pixelHeight: img.height)
        let snapshot = windows(s.windows, display: display.bounds)
        let judge = SlowJudger(detector, msPerJudgement: s.slowMs)
        let env = ProcessInfo.processInfo.environment
        let p = DisplayPipeline(display: display, judger: judge, budgetShare: env["STATIC_BUDGET"].flatMap(Double.init) ?? Register.JUDGEMENT_BUDGET,
                                ignoredPIDs: [], callWallMs: env["STATIC_WALL"].flatMap(Double.init) ?? Register.JUDGE_CALL_WALL * 1000)
        let start = ProcessInfo.processInfo.systemUptime
        var provisional: [CoverPlan] = [], finals = 0, settledAt: Double?, unsettled = 0
        var lastPrint = -1
        var n = 0
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let t = now - start
            if t >= s.seconds { break }
            let first = n == 0
            let status: FrameStatus = first || s.frames == "empty" ? .complete : .idle
            if !first && s.frames == "none" { usleep(useconds_t(1_000_000 / s.fps)); continue }
            let f = CapturedFrame(display: display, status: status, image: status == .complete ? img : nil, map: status == .complete ? map : nil,
                                  dirty: first ? nil : [], time: now)
            let plan = p.process(f, snapshot: snapshot, now: now) { provisional.append($0) }
            finals += 1
            n += 1
            let calm = plan.wholeDisplay == nil && plan.items.isEmpty && provisional.allSatisfy { $0.wholeDisplay == nil && $0.items.isEmpty }
            if calm { if settledAt == nil { settledAt = t } } else { if settledAt != nil { unsettled += 1 }; settledAt = nil }
            if Int(t) != lastPrint {
                lastPrint = Int(t)
                let g = p.diagnostics, tm = p.lastTimings
                print(String(format: "      calls=%d budget=%d entries=%d overload=%@ detector: hits=%d misses=%d judgements=%d", judge.calls, judge.budgets, judge.entries,
                             judge.overloadByPass.description, detector.timings.cacheHits, detector.timings.cacheMisses, detector.timings.judgements))
                if ProcessInfo.processInfo.environment["STATIC_HELD"] == "1" { for l in p.heldLines.prefix(40) { print("        held " + l) } }
                judge.calls = 0; judge.budgets = 0; judge.entries = 0; judge.overloadByPass = [:]; detector.resetTimings()
                print(String(format: "t=%5.1f final: items=%d plain=%d blur=%d whole=%@ | provisional=%d (with covers %d) | judged=%d ovl=%d atOnce=%d left=%d rechk=%d held=%d/%d/%d pend=%d tok=%d ms=%.0f",
                             t, plan.items.count, plan.plainCount, plan.blurCount, plan.wholeDisplay?.rawValue ?? "-",
                             provisional.count, provisional.filter { $0.wholeDisplay != nil || !$0.items.isEmpty }.count,
                             tm.judgements, tm.overloaded, tm.blurredAtOnce, tm.leftForLater, tm.rechecks,
                             g.heldPlain, g.heldBlur, g.heldWhole, g.pending, Int(g.tokens), tm.totalMs))
                fflush(stdout)
                provisional = []
            }
            let next = start + Double(n) / s.fps
            let wait = next - ProcessInfo.processInfo.systemUptime
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
        if let at = settledAt {
            print(String(format: "settled: no cover from t=%.1f s to the end (%.0f s); it came back %d times before that", at, s.seconds - at, unsettled))
        } else {
            print("NOT settled: covers still drawn at the end; \(finals) frames")
        }
    }
}
#endif
