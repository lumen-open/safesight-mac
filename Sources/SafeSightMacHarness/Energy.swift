// SPDX-License-Identifier: Apache-2.0
// LAB ONLY: what the watcher costs in CPU, memory and judgements, on a simulated clock. No screen is captured and
// nothing is drawn: frames are a harmless screenshot, the lab's harmless pages, or synthetic patterns, fed to the real
// cover layer and the real detector. Time is simulated, so a still screen's several minutes of settling run in the
// time the work itself takes, and only that work is counted.
//
//   safesightmac-harness energy FILE --models DIR [--windows FILE] [--pages DIR] [--power full|battery|low]
//                                     [--cases still,reuse,video,copy,tick] [--seconds REST] [--json FILE] [--check]
//                                     [--tick-while-covers-over N]
//
// - `still`: FILE (a harmless desktop screenshot) as a still screen. One complete frame, then the looks the watcher would
//   ask for (`EnergyMode.lookEvery`, only while the pipeline wants one) until nothing is drawn and no look is wanted, then
//   REST seconds (default 60) of rest. Judgements and CPU time while settling and at rest.
// - `reuse`: the busiest of the lab's harmless pages (`--pages`), judged until it rests, then shown again (a reload).
// - `video`: a 1280 x 720 pixel area changing every frame at 30 frames a second over a page, for 60 s; judged one frame
//   at a time as the watcher does (frames that come while one is judged wait, and only the newest is judged).
// - `copy`: the capture callback's frame copy (BGRA to RGBA) at 2880 x 1800 and 5120 x 2880, and what it costs at 60
//   and 120 frames a second.
// - `tick`: the main thread's quarter-second check (the OS's display lists and session state), per tick.
// - `finder`: the picture finder alone (no models) on a video frame's area, the busy page and FILE.
//
// ENERGY_DEBUG_CALLS=1 prints each judge call's area (frame pixels), budget and counts, nothing else.
//
// CPU time is the process's own (user and system, every thread, `getrusage`), counted around the watcher's work only.
// It includes Core ML's CPU side, not the Neural Engine's or the GPU's own work, and says nothing about battery drain:
// those need a real Mac (docs/ENERGY.md). Memory is the process's footprint as Activity Monitor counts it.
// With --check, exits 1 when a figure is over `EnergyBudget`.
// --tick-while-covers-over N turns on the option `LookPace.TICK_WHILE_COVERS_OVER` (off in the app) for the measurement.
#if SAFESIGHTMAC_LAB
import CoreGraphics
import Darwin
import DetectorCore
import Foundation
import Preprocess
import RegionFinder
import SafeSightMacCover
import SafeSightMacWatcher

struct EnergySettings {
    var power = EnergyMode.full
    var cases: [String] = ["still", "reuse", "video", "copy", "tick"]
    var restSeconds = 60.0
    var maxSettleSeconds = 1200.0
    var check = false
    /// The option `LookPace.TICK_WHILE_COVERS_OVER`, for measuring it (nil: the app's default, off).
    var tickWhileCoversOver: Int? = LookPace.TICK_WHILE_COVERS_OVER
}

/// The detector, counting judgements made beyond the budget each call was given (counts only).
final class BudgetWatch: Judging {
    let inner: Detector
    var calls = 0, overCalls = 0, overJudgements = 0, secondCheckOver = 0, units = 0
    init(_ d: Detector) { inner = d }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let v = inner.judgeArea(frame, context: context, within: area, budget: budget, progress: progress)
        if Energy.debugCalls { print("call \(area) budget \(budget) judged \(v.judgements) over \(v.overloaded) \((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) ms") }
        calls += 1; units += v.judgements
        if v.judgements > budget { overCalls += 1; overJudgements += v.judgements - budget }
        return v
    }
    func setRule(_ rule: DetectorRule) { inner.setRule(rule) }
    func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]? { inner.pictureRegions(frame, within: area) }
    func checkAgainInBackground(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict? {
        let v = inner.checkAgainInBackground(frame, context: context, within: area, budget: budget)
        if let v { units += v.judgements }
        if let v, v.judgements > budget { secondCheckOver += v.judgements - budget }
        return v
    }
    var summary: [String: Any] { ["calls": calls, "callsOverBudget": overCalls, "judgementsOverBudget": overJudgements,
                                  "secondCheckJudgementsOverBudget": secondCheckOver] }
}

enum Energy {
    static var watch: BudgetWatch?
    static let debugCalls = ProcessInfo.processInfo.environment["ENERGY_DEBUG_CALLS"] != nil
    // MARK: Process figures

    /// CPU seconds used by this process so far (user and system, every thread).
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// The process's memory footprint now (what Activity Monitor shows as Memory), in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// The highest footprint this process has had, in MB.
    static func peakFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
    }

    static func r2(_ x: Double) -> Double { x.isFinite ? (x * 100).rounded() / 100 : -1 }

    /// Judgements the detector made since its timings were last reset (second clean checks are among them).
    static func judgements(_ d: Detector) -> Int { d.timings.judgements }

    /// A simulated clock and the CPU time spent inside the watcher's work.
    struct Meter {
        var cpu = 0.0, judgements = 0, frames = 0, looks = 0, secondChecks = 0, budgetUnits = 0
        /// The detector's own stage timings (wall milliseconds), added up over every measured call.
        var stages = JudgeTimings()
        /// Wall time of the watcher's work, in all (milliseconds).
        var wallMs = 0.0
        mutating func measure<T>(_ d: Detector, _ body: () -> T) -> T {
            d.resetTimings()
            let u0 = Energy.watch?.units ?? 0
            let c0 = Energy.cpuSeconds()
            let w0 = DispatchTime.now().uptimeNanoseconds
            let out = body()
            cpu += Energy.cpuSeconds() - c0
            wallMs += Double(DispatchTime.now().uptimeNanoseconds - w0) / 1e6
            stages.add(d.timings)
            judgements += Energy.judgements(d)
            secondChecks += d.timings.secondCheckJudgements
            budgetUnits += Energy.watch.map { $0.units - u0 } ?? 0
            return out
        }
        /// Where the wall time went: the detector's stages, and the watcher's own work around them.
        var stageSummary: [String: Any] {
            let pre = stages.preprocessMs.values.reduce(0, +), inf = stages.inferenceMs.values.reduce(0, +)
            return ["all": Energy.r2(wallMs), "detector": Energy.r2(stages.totalMs), "finder": Energy.r2(stages.finderMs),
                    "hashingAndCache": Energy.r2(stages.cacheMs), "preprocess": Energy.r2(pre), "inference": Energy.r2(inf),
                    "decision": Energy.r2(stages.decisionMs), "outsideDetector": Energy.r2(wallMs - stages.totalMs),
                    "detectorCalls": stages.calls, "finderCacheHits": stages.finderCacheHits,
                    "cacheHits": stages.cacheHits, "cacheMisses": stages.cacheMisses]
        }
        func perMinute(_ seconds: Double) -> [String: Any] {
            let m = max(seconds, 1e-9) / 60
            return ["simulatedSeconds": Energy.r2(seconds), "cpuSeconds": Energy.r2(cpu), "cpuSecondsPerMinute": Energy.r2(cpu / m),
                    "cpuShareOfOneCore": Energy.r2(cpu / max(seconds, 1e-9)), "judgements": judgements,
                    "judgementsPerMinute": Energy.r2(Double(judgements) / m), "framesJudged": frames, "looks": looks,
                    "looksPerMinute": Energy.r2(Double(looks) / m), "secondCheckJudgements": secondChecks,
                    "budgetUnitsSpent": budgetUnits, "budgetUnitsPerSecond": Energy.r2(Double(budgetUnits) / max(seconds, 1e-9)),
                    "stagesWallMs": stageSummary,
                    "note": "judgements: the detector's own count, second clean checks included; budgetUnits: what the judge calls charged to the budget"]
        }
    }

    /// Runs a still screen on a simulated clock, as the watcher drives it: after `first`, a look at the last frame at the
    /// first quarter-second tick at least `mode.lookEvery` after the last one and after the last look's judging has ended,
    /// only while the pipeline wants one. Returns when nothing is drawn and no look is wanted, or at `until`.
    static func rest(_ p: DisplayPipeline, _ d: Detector, display: DisplayDescriptor, snapshot: WindowSnapshot, from start: Double,
                     until: Double, mode: EnergyMode, meter: inout Meter, plan: inout CoverPlan) -> Double? {
        var t = start, lastLook = start
        while t < until {
            if !p.needsAnotherLook && plan.wholeDisplay == nil && plan.items.isEmpty { return t }
            guard p.needsAnotherLook else { return nil }   // something drawn, nothing to look at: it will never settle
            // The next tick at which the app's own pace (`LookPace`) asks for a look.
            let tick = Register.TICK
            var next = (t / tick).rounded(.up) * tick
            while LookPace.due(now: next, mode: mode, wants: [1], leftOver: p.looksEveryTick ? [1] : [], lastAt: [1: lastLook],
                               busy: [], waiting: [], holding: false).offered.isEmpty { next += tick }
            t = next
            lastLook = t
            let f = CapturedFrame(display: display, status: .idle, image: nil, map: nil, dirty: [], time: t)
            let w0 = DispatchTime.now().uptimeNanoseconds
            plan = meter.measure(d) { p.process(f, snapshot: snapshot, now: t, date: Date(timeIntervalSinceReferenceDate: 800_000_000 + t)) }
            meter.looks += 1
            t += Double(DispatchTime.now().uptimeNanoseconds - w0) / 1e9
        }
        return nil
    }

    static func makePipeline(_ display: DisplayDescriptor, _ d: Detector, mode: EnergyMode) -> DisplayPipeline {
        let w = BudgetWatch(d)
        watch = w
        let p = DisplayPipeline(display: display, judger: w, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [])
        p.tickWhileCoversOver = tickWhileCoversOver
        return p
    }
    /// The option under measurement (`EnergySettings.tickWhileCoversOver`), set by `run`.
    static var tickWhileCoversOver: Int? = LookPace.TICK_WHILE_COVERS_OVER

    static func map(_ display: DisplayDescriptor, _ img: RGBAImage, scale: CGFloat) -> CaptureMap {
        CaptureMap(displayBounds: display.bounds, contentRect: CGRect(origin: .zero, size: display.bounds.size), contentScale: 1,
                   scaleFactor: scale, pixelWidth: img.width, pixelHeight: img.height)!
    }

    // MARK: Cases

    static func still(_ d: Detector, file: String, windows: String?, scale: CGFloat, s: EnergySettings, out: inout [String: Any], over: inout [String]) {
        guard let img = ImageLoading.load(URL(fileURLWithPath: file)) else { fail("unreadable image: \(file)") }
        let display = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
        let snap = windows.map { StaticScreen.windows($0, display: display.bounds) } ?? WindowSnapshot(windows: [WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: display.bounds)], time: 0)
        let p = makePipeline(display, d, mode: s.power)
        // The first frame of a display is judged before anything is shown (covered whole until then), at the per-call cap and
        // outside the budget: counted apart from the settling that follows.
        var firstFrame = Meter()
        var settling = Meter()
        var plan = firstFrame.measure(d) {
            p.process(CapturedFrame(display: display, status: .complete, image: img, map: map(display, img, scale: scale), dirty: nil, time: 0),
                      snapshot: snap, now: 0, date: Date(timeIntervalSinceReferenceDate: 800_000_000))
        }
        firstFrame.frames = 1
        let settledAt = rest(p, d, display: display, snapshot: snap, from: 0, until: s.maxSettleSeconds, mode: s.power, meter: &settling, plan: &plan)
        // At rest: the watcher asks for no look, and a frame that says nothing changed (were the capture to send one)
        // judges nothing.
        var resting = Meter()
        let t0 = settledAt ?? s.maxSettleSeconds
        var t = t0
        var wanted = 0
        while t < t0 + s.restSeconds {
            t += Register.TICK
            if p.needsAnotherLook { wanted += 1 }
            let f = CapturedFrame(display: display, status: .idle, image: nil, map: nil, dirty: [], time: t)
            _ = resting.measure(d) { p.process(f, snapshot: snap, now: t, date: Date(timeIntervalSinceReferenceDate: 800_000_000 + t)) }
        }
        resting.looks = wanted
        var settlingOut = settling.perMinute(settledAt ?? s.maxSettleSeconds)
        settlingOut["settledAtSeconds"] = settledAt.map(r2) ?? -1
        var restOut = resting.perMinute(s.restSeconds)
        restOut["note"] = "a 'nothing changed' frame every tick, as if the capture sent one; the watcher itself asks for none at rest"
        out["still"] = ["file": (file as NSString).lastPathComponent, "power": s.power.rawValue, "budgetWatch": watch?.summary ?? [:],
                        "firstFrame": ["judgements": firstFrame.judgements, "cpuSeconds": r2(firstFrame.cpu)],
                        "settling": settlingOut, "rest": restOut, "footprintMB": r2(footprintMB())]
        print("still: judge calls over their budget: \(watch?.summary ?? [:])")
        print(String(format: "still (%@): first frame %d judgements, %.2f CPU-s", s.power.rawValue, firstFrame.judgements, firstFrame.cpu))
        print(String(format: "still (%@): settling charged %d to the budget (%.1f a second); %d of the model runs were second clean checks", s.power.rawValue,
                     settling.budgetUnits, Double(settling.budgetUnits) / max(settledAt ?? s.maxSettleSeconds, 1), settling.secondChecks))
        print(String(format: "still (%@): settled at %@ s; settling %d judgements, %.1f a minute, %.2f CPU-s a simulated minute; at rest %d judgements, %d looks wanted",
                     s.power.rawValue, settledAt.map { String(format: "%.1f", $0) } ?? "never", settling.judgements,
                     Double(settling.judgements) / max(settledAt ?? s.maxSettleSeconds, 1) * 60,
                     settling.cpu / max(settledAt ?? s.maxSettleSeconds, 1) * 60, resting.judgements, wanted))
        let b = EnergyBudget.settleWithin(s.power)
        if settledAt == nil || settledAt! > b { over.append("still: settled at \(settledAt.map { "\($0) s" } ?? "never"), budget \(b) s") }
        let ceiling = EnergyBudget.settlingJudgements(seconds: settledAt ?? s.maxSettleSeconds)
        if Double(settling.budgetUnits) > ceiling { over.append("still: \(settling.budgetUnits) judgements charged while settling, budget \(Int(ceiling))") }
        let looksPerMin = Double(settling.looks) / max(settledAt ?? s.maxSettleSeconds, 1) * 60
        if looksPerMin > Double(EnergyBudget.SETTLING_LOOKS_PER_MINUTE) { over.append("still: \(Int(looksPerMin)) looks a minute while settling") }
        if resting.judgements > EnergyBudget.SETTLED_JUDGEMENTS_PER_MINUTE { over.append("still: \(resting.judgements) judgements at rest") }
        if Double(wanted) / s.restSeconds * 60 > Double(EnergyBudget.SETTLED_LOOKS_PER_MINUTE) { over.append("still: \(wanted) looks wanted at rest") }
        let cpuMin = settling.cpu / max(settledAt ?? s.maxSettleSeconds, 1) * 60
        if cpuMin > EnergyBudget.SETTLING_CPU_SECONDS_PER_MINUTE { over.append("still: \(r2(cpuMin)) CPU-s a minute while settling, budget \(EnergyBudget.SETTLING_CPU_SECONDS_PER_MINUTE)") }
    }

    static func busiestPage(_ dir: String) -> RGBAImage? {
        let truth = URL(fileURLWithPath: dir).deletingLastPathComponent().appendingPathComponent("truth.json")
        guard let data = try? Data(contentsOf: truth), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screens = j["screens"] as? [[String: Any]] else { return nil }
        let best = screens.filter { ($0["kind"] as? String) == "synthetic" && ($0["w"] as? Int) == 2880 && ($0["h"] as? Int) == 1800 }
            .max { (($0["photos"] as? [Any])?.count ?? 0, $1["file"] as? String ?? "") < (($1["photos"] as? [Any])?.count ?? 0, $0["file"] as? String ?? "") }
        return (best?["file"] as? String).flatMap { ImageLoading.load(URL(fileURLWithPath: dir).appendingPathComponent($0)) }
    }

    static func reuse(_ d: Detector, pages: String?, s: EnergySettings, out: inout [String: Any], over: inout [String]) {
        let img = pages.flatMap(busiestPage) ?? Synthetic.page(2880, 1800, seed: 21)
        let display = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let snap = WindowSnapshot(windows: [WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: display.bounds)], time: 0)
        let p = makePipeline(display, d, mode: s.power)
        let m = map(display, img, scale: 2)
        func show(at t0: Double) -> (Meter, Double?) {
            var meter = Meter()
            var plan = meter.measure(d) {
                p.process(CapturedFrame(display: display, status: .complete, image: img, map: m, dirty: nil, time: t0), snapshot: snap, now: t0,
                          date: Date(timeIntervalSinceReferenceDate: 800_000_000 + t0))
            }
            meter.frames = 1
            let at = rest(p, d, display: display, snapshot: snap, from: t0, until: t0 + s.maxSettleSeconds, mode: s.power, meter: &meter, plan: &plan)
            return (meter, at.map { $0 - t0 })
        }
        let (first, firstAt) = show(at: 0)
        let t1 = (firstAt ?? s.maxSettleSeconds) + 10
        let (again, againAt) = show(at: t1)
        var a = first.perMinute(firstAt ?? s.maxSettleSeconds); a["restedAfterSeconds"] = firstAt.map(r2) ?? -1
        var b = again.perMinute(againAt ?? s.maxSettleSeconds); b["restedAfterSeconds"] = againAt.map(r2) ?? -1
        out["reuse"] = ["page": pages == nil ? "synthetic" : "busiest held-out page", "power": s.power.rawValue,
                        "firstShowing": a, "reload": b, "footprintMB": r2(footprintMB())]
        print(String(format: "reuse: first showing %d judgements, %.2f CPU-s (rested after %@ s); reload %d judgements, %.2f CPU-s (rested after %@ s)",
                     first.judgements, first.cpu, firstAt.map { String(format: "%.1f", $0) } ?? "never",
                     again.judgements, again.cpu, againAt.map { String(format: "%.1f", $0) } ?? "never"))
        if again.cpu > EnergyBudget.RELOAD_CPU_SECONDS { over.append("reuse: reload cost \(r2(again.cpu)) CPU-s, budget \(EnergyBudget.RELOAD_CPU_SECONDS)") }
    }

    static func video(_ d: Detector, pages: String?, s: EnergySettings, out: inout [String: Any], over: inout [String]) {
        var img = pages.flatMap(busiestPage) ?? Synthetic.page(2880, 1800, seed: 21)
        let display = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let snap = WindowSnapshot(windows: [WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: display.bounds)], time: 0)
        let p = makePipeline(display, d, mode: s.power)
        let m = map(display, img, scale: 2)
        let area = PixelRect(x: 800, y: 500, w: 1280, h: 720)
        let fps = 30.0, seconds = 60.0
        var meter = Meter()
        var g = XorShift32(seed: 77)
        // The first frame is judged whole and left to rest, so only the video's own cost is counted.
        var plan = p.process(CapturedFrame(display: display, status: .complete, image: img, map: m, dirty: nil, time: 0), snapshot: snap, now: 0)
        var scratch = Meter()
        let t0 = (rest(p, d, display: display, snapshot: snap, from: 0, until: s.maxSettleSeconds, mode: s.power, meter: &scratch, plan: &plan) ?? s.maxSettleSeconds) + 1
        var t = t0, lastIndex = -1
        while t < t0 + seconds {
            let k = Int(((t - t0) * fps).rounded(.down))
            // The newest frame's pixels: a new, harmless noise-and-gradient picture each frame (as no two video frames match).
            let seed = g.next() | 1
            Synthetic.texture(&img, area, seed: seed)
            let f = CapturedFrame(display: display, status: .complete, image: img, map: m, dirty: [area], time: t)
            let w0 = DispatchTime.now().uptimeNanoseconds
            plan = meter.measure(d) { p.process(f, snapshot: snap, now: t, date: Date(timeIntervalSinceReferenceDate: 800_000_000 + t)) }
            meter.frames += 1
            let spent = Double(DispatchTime.now().uptimeNanoseconds - w0) / 1e9
            lastIndex = k
            // The next frame judged is the newest one to have come by the time this one is done.
            t = max(t + spent, t0 + Double(lastIndex + 1) / fps)
        }
        var o = meter.perMinute(seconds)
        o["framesCapturedPerMinute"] = Int(fps * 60)
        o["videoCoveredOrBlurredShareAtEnd"] = r2(coveredFraction(plan, m.toGlobal(area)))
        o["displayCoveredOrBlurredShareAtEnd"] = r2(coveredFraction(plan, display.bounds))
        o["cpuMsPerFrameJudged"] = r2(meter.cpu * 1000 / Double(max(1, meter.frames)))
        out["video"] = ["area": "1280x720 px at 30 fps over a 2880x1800 page", "power": s.power.rawValue, "judged": o, "footprintMB": r2(footprintMB())]
        print(String(format: "video: %d of %d frames judged, %d judgements a minute, %.2f CPU-s a simulated minute (%.0f%% of a core)",
                     meter.frames, Int(fps * seconds), meter.judgements, meter.cpu, meter.cpu / seconds * 100))
        if meter.cpu / seconds > EnergyBudget.VIDEO_CPU_SHARE { over.append("video: \(r2(meter.cpu / seconds * 100))% of a core, budget \(EnergyBudget.VIDEO_CPU_SHARE * 100)%") }
    }

    /// The picture finder alone (no models): a frame of the video case (its area, new noise over a busy page), the whole
    /// busy page, and the still desktop, each timed over a fresh call (nothing cached).
    static func finder(file: String?, pages: String?, out: inout [String: Any]) {
        let f = RegionFinder()
        var page = pages.flatMap(busiestPage) ?? Synthetic.page(2880, 1800, seed: 21)
        var cases: [(String, RGBAImage, PixelRect)] = []
        let videoArea = PixelRect(x: 800, y: 500, w: 1280, h: 720)
        cases.append(("busyPage", page, PixelRect(x: 0, y: 0, w: page.width, h: page.height)))
        Synthetic.texture(&page, videoArea, seed: 77)
        cases.append(("videoFrame", page, videoArea))
        if let file, let img = ImageLoading.load(URL(fileURLWithPath: file)) {
            cases.append(("stillDesktop", img, PixelRect(x: 0, y: 0, w: img.width, h: img.height)))
        }
        var o: [String: Any] = [:]
        for (name, img, area) in cases {
            var times: [Double] = []
            var regions = 0
            let c0 = cpuSeconds()
            for _ in 0..<10 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                regions = f.find(img, within: area).regions.count
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            let cpuMs = (cpuSeconds() - c0) * 1000 / 10
            o[name] = ["area": "\(area.w)x\(area.h)", "ms": r2(median(times)), "cpuMs": r2(cpuMs), "regions": regions]
            print(String(format: "finder %@ (%dx%d): %.1f ms (%.1f CPU-ms), %d regions", name, area.w, area.h, median(times), cpuMs, regions))
        }
        out["finder"] = o
    }

    static func copy(out: inout [String: Any], over: inout [String]) {
        var o: [String: Any] = [:]
        for (w, h) in [(2880, 1800), (5120, 2880)] {
            let bpr = w * 4 + 64
            var bgra = [UInt8](repeating: 0, count: bpr * h)
            var g = XorShift32(seed: 9)
            for i in stride(from: 0, to: bgra.count, by: 7) { bgra[i] = UInt8(truncatingIfNeeded: g.next()) }
            var times: [Double] = []
            let c0 = cpuSeconds()
            for _ in 0..<20 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let img = bgra.withUnsafeBufferPointer { RGBAImage.fromBGRA(width: w, height: h, bytesPerRow: bpr, base: $0.baseAddress!) }
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                precondition(img.width == w)
            }
            let cpuMs = (cpuSeconds() - c0) * 1000 / 20
            let ms = median(times)
            o["\(w)x\(h)"] = ["ms": r2(ms), "worstMs": r2(worst(times)), "cpuMsPerFrame": r2(cpuMs),
                              "coreShareAt60fps": r2(cpuMs * 60 / 1000), "coreShareAt120fps": r2(cpuMs * 120 / 1000)]
            print(String(format: "copy %dx%d: %.2f ms a frame (%.2f CPU-ms), %.0f%% of a core at 60 fps, %.0f%% at 120 fps", w, h, ms, cpuMs, cpuMs * 6, cpuMs * 12))
            if w == 2880, cpuMs > EnergyBudget.FRAME_COPY_CPU_MS { over.append("copy: \(r2(cpuMs)) CPU-ms a 2880x1800 frame, budget \(EnergyBudget.FRAME_COPY_CPU_MS) ms") }
        }
        out["copy"] = o
    }

    @MainActor static func tick(out: inout [String: Any]) {
        var times: [Double] = []
        let c0 = cpuSeconds()
        for _ in 0..<200 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let l = SystemDisplays.read()
            let s = SystemState.read(displays: l?.ids ?? [])
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            precondition(l != nil || !s.displaysAsleep || true)
        }
        let cpuMs = (cpuSeconds() - c0) * 1000 / 200
        let ms = median(times)
        out["tick"] = ["msPerTick": r2(ms), "cpuMsPerTick": r2(cpuMs), "ticksPerSecond": 1 / Register.TICK,
                       "cpuSecondsPerMinute": r2(cpuMs * 60 / Register.TICK / 1000),
                       "note": "the OS reads the quarter-second tick makes at a settled screen (display lists, session state); the stall and wait checks besides are arithmetic"]
        print(String(format: "tick: %.3f ms a tick (%.3f CPU-ms), %.3f CPU-s a minute at %.0f ticks a second", ms, cpuMs, cpuMs * 60 / Register.TICK / 1000, 1 / Register.TICK))
    }

    @MainActor static func run(detector d: Detector, files: [String], windows: String?, pages: String?, scale: CGFloat, s: EnergySettings, json: String?) {
        var out: [String: Any] = ["what": "safesightmac-harness energy", "simulatedClock": true,
                                  "machine": machine(), "footprintAfterModelsMB": r2(footprintMB())]
        tickWhileCoversOver = s.tickWhileCoversOver
        if let n = s.tickWhileCoversOver { out["tickWhileCoversOver"] = n }
        var over: [String] = []
        for c in s.cases {
            switch c {
            case "still":
                guard let f = files.first else { fail("energy still needs FILE (a harmless desktop screenshot)") }
                still(d, file: f, windows: windows, scale: scale, s: s, out: &out, over: &over)
            case "reuse": reuse(d, pages: pages, s: s, out: &out, over: &over)
            case "video": video(d, pages: pages, s: s, out: &out, over: &over)
            case "copy": copy(out: &out, over: &over)
            case "finder": finder(file: files.first, pages: pages, out: &out)
            case "tick": tick(out: &out)
            default: fail("unknown energy case \(c): still, reuse, video, copy, tick, finder")
            }
        }
        out["peakFootprintMB"] = r2(peakFootprintMB())
        out["budget"] = EnergyBudget.summary
        out["overBudget"] = over
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        if let json { try? data.write(to: URL(fileURLWithPath: json)) }
        print(String(decoding: data, as: UTF8.self))
        if s.check && !over.isEmpty {
            FileHandle.standardError.write(Data(("over the energy budget:\n" + over.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
    }

    static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var b = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &b, &size, nil, 0)
        return String(cString: b) + ", macOS " + ProcessInfo.processInfo.operatingSystemVersionString
    }
}
#endif
