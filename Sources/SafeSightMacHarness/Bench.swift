// SPDX-License-Identifier: Apache-2.0
// safesightmac-harness bench (lab builds only): times the chain from a frame handed to the cover layer to
// the cover plan and the cover layer update, with a stage breakdown, on synthetic frames. No screen is
// captured and nothing is drawn on a screen: the cover layer's layers are built on a detached layer.
//
// Not included, and only measurable on a test Mac (ST-031): ScreenCaptureKit's own capture latency (from a
// pixel changing on screen to the frame reaching the watcher) and real display time (from the layer update
// to light on the panel). The capture callback's frame copy is timed separately on a synthetic buffer.
//
// Harmless pictures only: built-in synthetic patterns, the lab stand-in (a magenta-and-green checker that
// forces a cover) and, with --pages, the lab's held-out composed pages of harmless photos.
#if SAFESIGHTMAC_LAB
import CoreGraphics
import DetectorCore
import Foundation
import LabStandIn
import Preprocess
import QuartzCore
import SafeSightMacCover
import SafeSightMacWatcher

struct BenchOptions {
    var trials = 8
    var pages: String?
    var json: String?
    var cases: Set<String> = ["single", "grid", "busy", "scroll", "reappear", "reuse"]
    var label = "bench"
    var busyPages = 6
    var scrollSpeeds = [8, 32, 96]
    var modelsNote = "null models (lab)"
    var backgroundChecks = true
}

// MARK: Small helpers

func median(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.sorted()[a.count / 2] }
func worst(_ a: [Double]) -> Double { a.max() ?? .nan }
func r1(_ x: Double) -> Double { x.isFinite ? (x * 10).rounded() / 10 : -1 }
func stat(_ a: [Double]) -> [String: Any] { ["median": r1(median(a)), "worst": r1(worst(a)), "n": a.count] }

/// The share of a global rectangle under the plan's covers or blurs (sampled on a 32 x 32 grid).
func coveredFraction(_ plan: CoverPlan, _ g: CGRect) -> Double {
    guard g.hasArea else { return 1 }
    if plan.wholeDisplay != nil { return 1 }
    let rects = plan.items.map(\.rect).filter { $0.intersects(g) }
    if rects.isEmpty { return 0 }
    let n = 32
    var hit = 0
    for i in 0..<n {
        for j in 0..<n {
            let p = CGPoint(x: g.minX + (CGFloat(i) + 0.5) * g.width / CGFloat(n), y: g.minY + (CGFloat(j) + 0.5) * g.height / CGFloat(n))
            if rects.contains(where: { $0.contains(p) }) { hit += 1 }
        }
    }
    return Double(hit) / Double(n * n)
}

/// The share of the display under covers or blurs.
func coveredShare(_ plan: CoverPlan) -> Double { coveredFraction(plan, plan.display.bounds) }

func paintTexture(_ img: inout RGBAImage, _ r: PixelRect, seed: UInt32) { Synthetic.texture(&img, r, seed: seed) }

// MARK: One processed frame

/// A plan as it would be shown: when it was ready (from the start of `process`) and how long the cover
/// layer update took.
struct ShownPlan { var ms: Double; var drawMs: Double; var plan: CoverPlan; var provisional: Bool }

struct BenchStep {
    var plans: [ShownPlan]           // provisional plans in order, then the final plan
    var totalMs: Double              // `process` end to end
    var pipe: PipelineTimings
    var judge: JudgeTimings
    var final: CoverPlan { plans.last!.plan }

    /// When a global rectangle was first under covers or blurs (fraction at least `need`), counting the
    /// cover layer update; nil if no plan of this step covers it.
    func coverMs(_ g: CGRect, need: Double = 0.999) -> Double? {
        for p in plans where coveredFraction(p.plan, g) >= need { return p.ms + p.drawMs }
        return nil
    }
}

final class Bench {
    let detector: Detector
    let o: BenchOptions
    let scale: CGFloat = 2
    let display = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
    var W: Int { Int(display.bounds.width * scale) }
    var H: Int { Int(display.bounds.height * scale) }
    var snapshot: WindowSnapshot { WindowSnapshot(windows: [WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: display.bounds)], time: 0) }
    let root = CALayer()
    var doc: [String: Any] = [:]

    init(detector: Detector, options: BenchOptions) {
        self.detector = detector; self.o = options
        detector.standIn = CheckerStandIn()
    }

    func pipeline(unlimited: Bool) -> DisplayPipeline {
        let p = DisplayPipeline(display: display, judger: detector, budgetShare: unlimited ? 1e9 : Register.JUDGEMENT_BUDGET, ignoredPIDs: [])
        p.backgroundSecondChecks = o.backgroundChecks
        return p
    }

    func frame(_ img: RGBAImage?, dirty: [PixelRect]?, status: FrameStatus = .complete, t: TimeInterval) -> CapturedFrame {
        let map = CaptureMap(displayBounds: display.bounds, contentRect: CGRect(origin: .zero, size: display.bounds.size), contentScale: 1,
                             scaleFactor: scale, pixelWidth: W, pixelHeight: H)
        return CapturedFrame(display: display, status: status, image: img, map: img == nil ? nil : map, dirty: dirty, time: t)
    }

    func toGlobal(_ r: PixelRect) -> CGRect {
        CGRect(x: display.bounds.minX + CGFloat(r.x) / scale, y: display.bounds.minY + CGFloat(r.y) / scale,
               width: CGFloat(r.w) / scale, height: CGFloat(r.h) / scale)
    }

    func draw(_ plan: CoverPlan) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        CoverDrawing.apply(plan, to: root)
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// Runs one frame through the pipeline, timing every stage and every plan it hands out.
    func step(_ p: DisplayPipeline, _ f: CapturedFrame, now: TimeInterval, pointer: CGPoint? = nil, snapshot snap: WindowSnapshot? = nil) -> BenchStep {
        detector.resetTimings()
        var early: [(Double, CoverPlan)] = []
        let t0 = DispatchTime.now().uptimeNanoseconds
        let plan = p.process(f, snapshot: snap ?? snapshot, now: now, pointer: pointer) { pl in
            early.append((Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6, pl))
        }
        let total = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        // Plans handed out early are drawn when they arrive (on the main thread in the app); here each is
        // built after the call and its building time is added to when it arrived.
        let plans = early.map { ShownPlan(ms: $0.0, drawMs: draw($0.1), plan: $0.1, provisional: true) }
            + [ShownPlan(ms: total, drawMs: draw(plan), plan: plan, provisional: false)]
        return BenchStep(plans: plans, totalMs: total, pipe: p.lastTimings, judge: detector.timings)
    }

    /// Stage medians over a set of steps.
    func stages(_ steps: [BenchStep]) -> [String: Any] {
        var out: [String: Any] = [:]
        func m(_ k: String, _ f: (BenchStep) -> Double) { out[k] = r1(median(steps.map(f))) }
        m("changeDetectionMs") { $0.pipe.changeMs }
        m("translationMs") { $0.pipe.translateMs }
        m("finderMs") { $0.judge.finderMs }
        m("cacheHashMs") { $0.judge.cacheMs }
        var ids = Set<String>()
        for s in steps { ids.formUnion(s.judge.inferenceMs.keys) }
        for id in ids.sorted() {
            m("model.\(id).preprocessMs") { $0.judge.preprocessMs[id] ?? 0 }
            m("model.\(id).inferenceMs") { $0.judge.inferenceMs[id] ?? 0 }
            m("model.\(id).tiles") { Double($0.judge.tiles[id] ?? 0) }
        }
        m("decisionMs") { $0.judge.decisionMs }
        m("judgeTotalMs") { $0.judge.totalMs }
        m("planningMs") { $0.pipe.planMs }
        m("coverDrawMs") { $0.plans.last!.drawMs }
        m("processTotalMs") { $0.totalMs }
        m("judgements") { Double($0.pipe.judgements) }
        m("secondCheckJudgements") { Double($0.judge.secondCheckJudgements) }
        m("overloaded") { Double($0.pipe.overloaded) }
        m("modelFaults") { Double($0.pipe.modelFaults) }
        m("cacheHits") { Double($0.judge.cacheHits) }
        m("cacheMisses") { Double($0.judge.cacheMisses) }
        return out
    }

    // MARK: The frame copy in the capture callback

    func frameCopy() {
        let bpr = W * 4
        var bgra = [UInt8](repeating: 0, count: bpr * H)
        var g = XorShift32(seed: 9)
        for i in stride(from: 0, to: bgra.count, by: 7) { bgra[i] = UInt8(truncatingIfNeeded: g.next()) }
        var times: [Double] = []
        for _ in 0..<10 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let img = bgra.withUnsafeBufferPointer { RGBAImage.fromBGRA(width: W, height: H, bytesPerRow: bpr, base: $0.baseAddress!) }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            precondition(img.width == W)
        }
        doc["frameCopy"] = ["frame": "\(W)x\(H)", "ms": stat(times),
                            "note": "RGBAImage.fromBGRA in the capture callback, on a synthetic buffer; runs on the capture queue before the frame reaches the judging queue"]
        print("frame copy \(W)x\(H): median \(r1(median(times))) ms")
    }

    // MARK: Base page

    lazy var base: RGBAImage = Synthetic.page(W, H, seed: 11)

    /// A fresh pipeline that has judged the still base page (its first judgement is not budget-limited).
    func primed(unlimited: Bool = false) -> DisplayPipeline {
        let p = pipeline(unlimited: unlimited)
        _ = p.process(frame(base, dirty: nil, t: 0), snapshot: snapshot, now: 0)
        return p
    }

    // MARK: Case 1: one new picture on an otherwise still screen, per size band

    func single() {
        let bands: [(String, [Int])] = [("16-31", [16, 24]), ("32-63", [32, 48]), ("64-127", [64, 96]), ("128+", [128, 256])]
        var out: [String: Any] = [:]
        var seed: UInt32 = 100
        for (band, sides) in bands {
            var cover: [Double] = [], planMs: [Double] = [], steps: [BenchStep] = []
            var covered = 0, trials = 0
            for side in sides {
                for k in 0..<o.trials {
                    seed &+= 1
                    let p = primed()
                    var img = base
                    let r = PixelRect(x: 200 + (k * 331 + side * 7) % (W - 600), y: 260 + (k * 197 + side * 3) % (H - 560), w: side, h: side)
                    CheckerStandIn.paint(&img, r, seed: seed)
                    let s = step(p, frame(img, dirty: [r], t: 1.0), now: 1.0)
                    trials += 1
                    planMs.append(s.totalMs + s.plans.last!.drawMs)
                    steps.append(s)
                    if let c = s.coverMs(toGlobal(r)) { covered += 1; cover.append(c) }
                }
            }
            out[band] = ["trials": trials, "covered": covered, "timeToCoverMs": stat(cover), "finalPlanMs": stat(planMs), "stages": stages(steps)]
            print("single \(band): covered \(covered)/\(trials), time to cover median \(r1(median(cover))) ms, worst \(r1(worst(cover))) ms")
        }
        doc["single"] = out
    }

    // MARK: Case 2: a 32-tile grid with one stand-in tile

    func grid() {
        var cover: [Double] = [], planMs: [Double] = [], steps: [BenchStep] = []
        var covered = 0, harmlessCovered = 0
        for k in 0..<o.trials {
            let p = primed()
            var img = base
            let ox = 300 + k * 211 % (W - 900), oy = 300 + k * 113 % (H - 700)
            var tiles: [PixelRect] = []
            for i in 0..<4 { for j in 0..<8 { tiles.append(PixelRect(x: ox + j * 54, y: oy + i * 54, w: 48, h: 48)) } }
            for (n, r) in tiles.enumerated() {
                if n == 13 { CheckerStandIn.paint(&img, r, seed: UInt32(900 + k)) } else { paintTexture(&img, r, seed: UInt32(1000 + k * 40 + n)) }
            }
            let bounds = tiles.dropFirst().reduce(tiles[0]) { $0.union($1) }
            let s = step(p, frame(img, dirty: [bounds], t: 1.0), now: 1.0)
            steps.append(s)
            planMs.append(s.totalMs + s.plans.last!.drawMs)
            if let c = s.coverMs(toGlobal(tiles[13])) { covered += 1; cover.append(c) }
            harmlessCovered += tiles.enumerated().filter { $0.offset != 13 && coveredFraction(s.final, toGlobal($0.element)) >= 0.5 }.count
        }
        doc["grid"] = ["trials": o.trials, "tiles": 32, "standInCovered": covered, "timeToCoverMs": stat(cover), "finalPlanMs": stat(planMs),
                       "harmlessTilesCoveredOrBlurredInFinalPlan": harmlessCovered, "stages": stages(steps)]
        print("grid: covered \(covered)/\(o.trials), time to cover median \(r1(median(cover))) ms, worst \(r1(worst(cover))) ms")
    }

    // MARK: Case 3: a full busy Retina page, from scratch

    struct Page { var name: String; var img: RGBAImage; var photos: [PixelRect] }

    func busyPages() -> [Page] {
        guard let dir = o.pages else {
            // Generated: 160 harmless textured pictures in a grid of cards.
            var img = Synthetic.page(W, H, seed: 21)
            var photos: [PixelRect] = []
            for i in 0..<10 { for j in 0..<16 {
                let r = PixelRect(x: 60 + j * 172, y: 60 + i * 172, w: 150, h: 150)
                paintTexture(&img, r, seed: UInt32(5000 + i * 16 + j)); photos.append(r)
            } }
            return [Page(name: "generated-160", img: img, photos: photos)]
        }
        let truthURL = URL(fileURLWithPath: dir).deletingLastPathComponent().appendingPathComponent("truth.json")
        var rows: [(String, [PixelRect])] = []
        if let d = try? Data(contentsOf: truthURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let screens = j["screens"] as? [[String: Any]] {
            for s in screens {
                guard let f = s["file"] as? String, (s["kind"] as? String) == "synthetic", (s["w"] as? Int) == W, (s["h"] as? Int) == H else { continue }
                let photos = (s["photos"] as? [[String: Any]] ?? []).compactMap { p -> PixelRect? in
                    guard let r = p["rect"] as? [Int], r.count == 4 else { return nil }
                    return PixelRect(x: r[0], y: r[1], w: r[2], h: r[3])
                }
                rows.append((f, photos))
            }
        }
        rows.sort { ($0.1.count, $0.0) > ($1.1.count, $1.0) }
        return rows.prefix(o.busyPages).compactMap { f, photos in
            ImageLoading.load(URL(fileURLWithPath: dir).appendingPathComponent(f)).map { Page(name: f, img: $0, photos: photos) }
        }
    }

    /// A timeline of shown plans (absolute virtual times), for exposure and late-reveal measures.
    struct Timeline {
        var shown: [(t: Double, plan: CoverPlan)] = []
        mutating func add(_ s: BenchStep, start: Double) { for p in s.plans { shown.append((start + (p.ms + p.drawMs) / 1000, p.plan)) } }
        /// The plan on screen at time t (the last one shown at or before t).
        func plan(at t: Double) -> CoverPlan? { shown.last { $0.t <= t }?.plan }
    }

    /// Where the pointer rests in the pointer runs (bottom right of the page), and how near a photo must be.
    var probe: CGPoint { CGPoint(x: display.bounds.width * 0.75, y: display.bounds.height * 0.75) }
    let nearPoints: CGFloat = 220

    func busy(unlimited: Bool, pointer: CGPoint? = nil) -> [String: Any] {
        var perPage: [[String: Any]] = []
        var nearShown: [Double] = [], provisionalFirst: [Double] = [], coveredFirst: [Double] = [], fastFlags: [Double] = []
        var firstPlan: [Double] = [], standIn: [Double] = [], fully: [Double] = [], clearAt: [Double] = []
        var lateMedian: [Double] = [], lateWorst: [Double] = [], sharpUnjudged: [Double] = [], blurredShare: [Double] = []
        var textHidden: [Double] = [], textHiddenPlans: [Double] = []
        var firstSteps: [BenchStep] = []
        for page in busyPages() {
            let p = primed(unlimited: unlimited)
            detector.removeCachedVerdicts()   // from scratch: nothing of this page has been judged before
            var img = page.img
            let spot = PixelRect(x: W / 2 - 48, y: H / 2 - 48, w: 96, h: 96)
            CheckerStandIn.paint(&img, spot, seed: 77)
            let photos = page.photos.filter { !$0.intersects(spot) }
            let appear = 1.0
            var tl = Timeline()
            tl.shown.append((0, p.lastPlan))
            var t = appear
            var s = step(p, frame(img, dirty: [PixelRect(x: 0, y: 0, w: W, h: H)], t: t), now: t, pointer: pointer)
            firstSteps.append(s)
            provisionalFirst.append(s.pipe.provisionalMs.first ?? s.totalMs)
            coveredFirst.append(Double(s.pipe.coveredFirst)); fastFlags.append(Double(s.pipe.fastFlags))
            tl.add(s, start: t)
            let standInAt = s.coverMs(toGlobal(spot)).map { $0 / 1000 }
            var calls = 1, computeMs = s.totalMs
            var lastOverload = s.pipe.overloaded > 0 ? t + s.totalMs / 1000 : nil as Double?
            var fullyAt: Double? = s.pipe.overloaded == 0 ? t + s.totalMs / 1000 : nil
            var standInCovered = standInAt.map { t + $0 }
            // Idle frames (nothing changes on screen) every 0.1 s, or as soon as judging is free.
            while calls < 600 && t < appear + 90 {
                t += max(0.1, s.totalMs / 1000)
                s = step(p, frame(nil, dirty: [], status: .idle, t: t), now: t, pointer: pointer)
                calls += 1; computeMs += s.totalMs
                tl.add(s, start: t)
                if standInCovered == nil, let c = s.coverMs(toGlobal(spot)) { standInCovered = t + c / 1000 }
                if s.pipe.overloaded > 0 { lastOverload = t; fullyAt = nil } else if fullyAt == nil { fullyAt = t + s.totalMs / 1000 }
                // Done once judging is complete and only the stand-in's cover is left.
                let others = s.final.items.filter { !$0.rect.intersects(toGlobal(spot)) }
                if fullyAt != nil && others.isEmpty && s.final.wholeDisplay == nil { break }
            }
            let clear = tl.shown.last { tp in tp.plan.items.contains { !$0.rect.intersects(toGlobal(spot)) } || tp.plan.wholeDisplay != nil }
            let clearTime = tl.shown.first { $0.t > (clear?.t ?? appear) }?.t ?? t
            // Harmless photos: when each was last under a cover or blur, and so shown late; and how long it
            // was shown sharp before its first judgement (show-first exposure).
            var late: [Double] = [], unjudged: [Double] = []
            var blurred = 0
            for ph in photos {
                let g = toGlobal(ph)
                let near = hypot(max(0, max(g.minX - probe.x, probe.x - g.maxX)), max(0, max(g.minY - probe.y, probe.y - g.maxY))) <= nearPoints
                var lastCovered: Double? = nil, firstCovered: Double? = nil
                for (i, sp) in tl.shown.enumerated() where sp.t >= appear {
                    if coveredFraction(sp.plan, g) >= 0.5 {
                        firstCovered = firstCovered ?? sp.t
                        lastCovered = i + 1 < tl.shown.count ? tl.shown[i + 1].t : sp.t
                    }
                }
                if let l = lastCovered { blurred += 1; late.append(l - appear) } else { late.append(0) }
                if near { nearShown.append(lastCovered.map { $0 - appear } ?? 0) }
                unjudged.append((firstCovered ?? tl.shown.first { $0.t >= appear }?.t ?? appear) - appear)
            }
            let ff = (s.plans.first?.ms ?? 0)
            _ = ff
            firstPlan.append(firstSteps.last!.totalMs)
            if let c = standInCovered { standIn.append((c - appear) * 1000) }
            if let f = fullyAt { fully.append(f - appear) }
            clearAt.append(clearTime - appear)
            lateMedian.append(median(late)); lateWorst.append(worst(late))
            sharpUnjudged.append(median(unjudged)); blurredShare.append(photos.isEmpty ? 0 : Double(blurred) / Double(photos.count))
            // The page's text (everything that is not a photo or the stand-in): the largest share of it under a cover or
            // blur in any plan shown after the page appeared, and the share of those plans that hide a tenth of it or more.
            let notText = (photos + [spot]).map(toGlobal)
            var textPoints: [CGPoint] = []
            for i in 0..<48 { for j in 0..<30 {
                let q = CGPoint(x: display.bounds.minX + (CGFloat(i) + 0.5) * display.bounds.width / 48,
                                y: display.bounds.minY + (CGFloat(j) + 0.5) * display.bounds.height / 30)
                if !notText.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(q) }) { textPoints.append(q) }
            } }
            let hiddenShares = tl.shown.filter { $0.t >= appear }.map { sp -> Double in
                if sp.plan.wholeDisplay != nil { return 1 }
                let hit = textPoints.filter { q in sp.plan.items.contains { $0.rect.contains(q) } }.count
                return textPoints.isEmpty ? 0 : Double(hit) / Double(textPoints.count)
            }
            textHidden.append(hiddenShares.max() ?? 0)
            textHiddenPlans.append(hiddenShares.isEmpty ? 0 : Double(hiddenShares.filter { $0 >= 0.1 }.count) / Double(hiddenShares.count))
            perPage.append(["page": page.name, "photos": photos.count, "firstCallMs": r1(firstSteps.last!.totalMs),
                            "firstCallJudgements": firstSteps.last!.pipe.judgements, "firstCallOverloaded": firstSteps.last!.pipe.overloaded,
                            "standInCoveredAfterMs": standInCovered.map { r1(($0 - appear) * 1000) } ?? NSNull(),
                            "fullyJudgedAfterS": fullyAt.map { r1($0 - appear) } ?? NSNull(), "lastOverloadAfterS": lastOverload.map { r1($0 - appear) } ?? NSNull(),
                            "harmlessClearAfterS": r1(clearTime - appear), "calls": calls, "computeMs": r1(computeMs),
                            "photosCoveredOrBlurredAtSomePoint": blurred,
                            "photoShownLateS": ["median": r1(median(late)), "worst": r1(worst(late))]])
            print("busy \(unlimited ? "unlimited" : "register") \(page.name): first call \(Int(firstSteps.last!.totalMs)) ms (\(firstSteps.last!.pipe.overloaded) overloaded), stand-in covered after \(standInCovered.map { Int(($0 - appear) * 1000) } ?? -1) ms, fully judged after \(fullyAt.map { r1($0 - appear) } ?? -1) s, all harmless shown after \(r1(clearTime - appear)) s, text hidden at most \(r1((textHidden.last ?? 0) * 100)) %, plans hiding a tenth of the text \(r1((textHiddenPlans.last ?? 0) * 100)) %")
        }
        return ["budget": unlimited ? "unlimited (compute-bound; DETECTOR_CALL_CAP still applies)" : "register (JUDGEMENT_BUDGET 40/s, JUDGEMENT_BURST 400)",
                "pointer": pointer.map { "at \(Int($0.x)), \(Int($0.y)) points" } ?? "none",
                "photosNearProbeShownAfterS": stat(nearShown), "probe": "photos within \(Int(nearPoints)) points of \(Int(probe.x)), \(Int(probe.y))",
                "firstPlanHandedOutMs": stat(provisionalFirst), "regionsCoveredFirst": stat(coveredFirst), "fastModelFlags": stat(fastFlags),
                "pages": perPage.count, "firstCallMs": stat(firstPlan), "standInTimeToCoverMs": stat(standIn),
                "fullyJudgedAfterS": stat(fully), "allHarmlessShownAfterS": stat(clearAt),
                "photoShownLateMedianS": stat(lateMedian), "photoShownLateWorstS": stat(lateWorst),
                "photoShownSharpBeforeFirstCoverS": stat(sharpUnjudged), "photosCoveredOrBlurredShare": stat(blurredShare),
                "textHiddenMaxShare": stat(textHidden), "plansHidingATenthOfTheText": stat(textHiddenPlans),
                "firstCallStages": stages(firstSteps), "perPage": perPage,
                "assumption": "idle frames every 0.1 s while nothing changes (whether a still screen sends idle frames is unproven, chapter 05)"]
    }

    // MARK: Case 4: scrolling

    /// A tall article: text bars and harmless pictures, with two stand-ins (one in view at the start, one
    /// further down that scrolls into view).
    lazy var article: (img: RGBAImage, standIns: [PixelRect], photos: [PixelRect]) = {
        let h = H * 3
        var img = Synthetic.page(W, h, seed: 31)
        var photos: [PixelRect] = []
        let sizes = [(480, 320), (320, 320), (640, 400), (240, 240), (400, 300), (560, 360), (300, 420)]
        var y = 200, k = 0
        while y < h - 500 {
            let (w, hh) = sizes[k % sizes.count]
            let x = 240 + (k * 677) % (W - w - 480)
            let r = PixelRect(x: x, y: y, w: w, h: hh)
            paintTexture(&img, r, seed: UInt32(7000 + k)); photos.append(r)
            y += hh + 260; k += 1
        }
        let a = PixelRect(x: W - 700, y: 700, w: 192, h: 192), b = PixelRect(x: W - 700, y: H + 900, w: 192, h: 192)
        CheckerStandIn.paint(&img, a, seed: 41); CheckerStandIn.paint(&img, b, seed: 42)
        photos.removeAll { $0.intersects(a) || $0.intersects(b) }
        return (img, [a, b], photos)
    }()

    func viewport(_ offset: Int) -> RGBAImage {
        let a = article.img
        var px = [UInt8](repeating: 0, count: W * H * 4)
        a.pixels.withUnsafeBufferPointer { src in
            px.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src.baseAddress! + offset * W * 4, count: W * H * 4)
            }
        }
        return RGBAImage(width: W, height: H, pixels: px)
    }

    func scroll(speed: Int, unlimited: Bool) -> [String: Any] {
        let p = primed(unlimited: unlimited)
        detector.removeCachedVerdicts()
        let maxOffset = article.img.height - H
        let v = Double(speed) * 60  // pixels per second
        // The page at offset 0 is judged first, and scrolling starts once its plan is shown, so the first
        // stand-in starts covered.
        var tl = Timeline()
        let s0 = step(p, frame(viewport(0), dirty: [PixelRect(x: 0, y: 0, w: W, h: H)], t: 0.5), now: 0.5)
        tl.add(s0, start: 0.5)
        let start = (tl.shown.last!.t * 10).rounded(.up) / 10 + 0.1
        let stopAt = start + min(Double(maxOffset) / v, 5.0)
        func offset(_ t: Double) -> Int { min(maxOffset, max(0, Int((min(t, stopAt) - start) * v))) }
        var t = start, lastFrame = start - 1.0 / 60
        var steps: [BenchStep] = []
        // Scroll for up to 5 s, then 1 s more with the page still, so the covers can settle.
        let end = stopAt + 1.0
        while t < end {
            // The newest frame when judging is free: 60 Hz frames, coalesced while busy.
            let ft = max(t, lastFrame + 1.0 / 60)
            lastFrame = ft
            let s = step(p, frame(viewport(offset(ft)), dirty: [PixelRect(x: 0, y: 0, w: W, h: H)], t: ft), now: ft)
            steps.append(s)
            tl.add(s, start: ft)
            if ProcessInfo.processInfo.environment["BENCH_TRACE"] != nil {
                print("  frame t=\(r1(ft * 1000)) ms offset \(offset(ft)) total \(r1(s.totalMs)) motion \(r1(s.pipe.translateMs)) finder \(r1(s.judge.finderMs)) hash \(r1(s.judge.cacheMs)) hits \(s.judge.cacheHits) misses \(s.judge.cacheMisses) early \(s.plans.count - 1)")
            }
            t = ft + (s.totalMs + s.plans.last!.drawMs) / 1000
        }
        tl.shown.sort { $0.t < $1.t }
        // Exposure of each stand-in on the live screen: at each shown plan's start and just before the next.
        func live(_ r: PixelRect, _ t: Double) -> CGRect? {
            let y = r.y - offset(t)
            guard let c = PixelRect(x: r.x, y: y, w: r.w, h: r.h).clamped(width: W, height: H) else { return nil }
            return toGlobal(c)
        }
        var res: [String: Any] = [:]
        for (n, sIn) in article.standIns.enumerated() {
            var maxExposed = 0.0, exposedTime = 0.0
            var firstVisible: Double? = nil, firstCovered: Double? = nil
            var samples: [Double] = []
            var tt = start
            while tt < t {
                if let g = live(sIn, tt), let pl = tl.plan(at: tt) {
                    let visShare = Double(g.width * g.height) / Double(sIn.w * sIn.h) * Double(scale * scale)
                    let e = (1 - coveredFraction(pl, g)) * visShare
                    if visShare > 0.05 && firstVisible == nil { firstVisible = tt }
                    if firstVisible != nil && firstCovered == nil && e < 0.05 { firstCovered = tt }
                    maxExposed = max(maxExposed, e)
                    if e > 0.05 { exposedTime += 0.004 }
                    samples.append(e)
                }
                tt += 0.004
            }
            res[n == 0 ? "standInInView" : "standInScrollingIn"] = ["maxShareExposed": r1(maxExposed * 100) / 100, "exposedS": r1(exposedTime * 10) / 10,
                                                                      "firstVisibleS": firstVisible.map { r1(($0 - start) * 100) / 100 as Any } ?? NSNull(),
                                                                      "coveredAfterVisibleS": (firstVisible != nil && firstCovered != nil) ? r1((firstCovered! - firstVisible!) * 100) / 100 : NSNull()]
        }
        // How much of the display is covered or blurred, and how many harmless pictures, while scrolling.
        let shares = tl.shown.filter { $0.t >= start }.map { coveredShare($0.plan) }
        res["coveredDisplayShare"] = ["median": r1(median(shares) * 100) / 100, "worst": r1(worst(shares) * 100) / 100]
        res["framesJudged"] = steps.count
        res["simulatedS"] = r1((t - start) * 10) / 10
        res["scrollingS"] = r1((stopAt - start) * 100) / 100
        res["perFrameMs"] = stat(steps.map { $0.totalMs })
        res["stages"] = stages(steps)
        res["speed"] = "\(speed) px per frame at 60 Hz (\(Int(v / Double(scale))) points per second)"
        let inView = res["standInInView"] as? [String: Any] ?? [:], scrollingIn = res["standInScrollingIn"] as? [String: Any] ?? [:]
        print("scroll \(speed) px/frame \(unlimited ? "unlimited" : "register"): \(steps.count) frames judged, \(r1(median(steps.map { $0.totalMs }))) ms each; in-view stand-in max exposed \(inView["maxShareExposed"] ?? "-"), exposed \(inView["exposedS"] ?? "-") s; scrolling-in stand-in covered after \(scrollingIn["coveredAfterVisibleS"] ?? "-") s; display covered median \(r1(median(shares) * 100))%")
        return res
    }

    // MARK: Case 5: pictures already judged reappear (reload, window move, scrolling back)

    /// Judges until nothing is left unjudged (budget unlimited), so that every picture has a verdict.
    /// Frames where nothing changes also give pictures seen clean once their second clean check in the background
    /// (`DisplayPipeline`, step 3c), unless --no-background-checks.
    func settle(_ p: DisplayPipeline, from t: inout Double, snapshot snap: WindowSnapshot? = nil) {
        for _ in 0..<50 {
            t += 0.01
            let s = step(p, frame(nil, dirty: [], status: .idle, t: t), now: t, snapshot: snap)
            if s.pipe.overloaded == 0 && !p.secondChecksDue { return }
        }
    }

    func reappear() -> [String: Any] {
        var out: [String: Any] = [:]
        let pages = busyPages()
        // Reload: the same busy page drawn again, every pixel the same.
        var reload: [BenchStep] = [], first: [BenchStep] = []
        for page in pages {
            detector.removeCachedVerdicts()
            let p = primed(unlimited: true)
            var t = 1.0
            let whole = [PixelRect(x: 0, y: 0, w: W, h: H)]
            first.append(step(p, frame(page.img, dirty: whole, t: t), now: t))
            settle(p, from: &t)
            t += 1
            _ = step(p, frame(base, dirty: whole, t: t), now: t)   // the page goes blank while loading
            t += 0.1
            reload.append(step(p, frame(page.img, dirty: whole, t: t), now: t))
        }
        out["reload"] = ["pages": pages.count, "firstShowMs": stat(first.map(\.totalMs)), "reloadMs": stat(reload.map(\.totalMs)),
                         "reloadStages": stages(reload), "firstShowStages": stages(first)]
        print("reload: first show median \(r1(median(first.map(\.totalMs)))) ms, reload median \(r1(median(reload.map(\.totalMs)))) ms")

        // Window move: a 1000 x 700 point window showing part of a busy page moves 120 x 30 points.
        var moves: [BenchStep] = []
        for page in pages {
            detector.removeCachedVerdicts()
            let p = primed(unlimited: true)
            let a = CGRect(x: 100, y: 80, width: 1000, height: 700), b = a.offsetBy(dx: 120, dy: 30)
            func scene(_ w: CGRect) -> RGBAImage {
                var img = base
                let x0 = Int(w.minX * scale), y0 = Int(w.minY * scale), ww = Int(w.width * scale), hh = Int(w.height * scale)
                for y in 0..<hh { for x in 0..<ww {
                    let d = ((y0 + y) * W + x0 + x) * 4, s = (y * W + x) * 4
                    img.pixels[d] = page.img.pixels[s]; img.pixels[d + 1] = page.img.pixels[s + 1]; img.pixels[d + 2] = page.img.pixels[s + 2]
                } }
                return img
            }
            func snap(_ w: CGRect) -> WindowSnapshot { WindowSnapshot(windows: [WindowInfo(number: 7, ownerPID: 501, layer: 0, bounds: w)], time: 0) }
            func px(_ w: CGRect) -> PixelRect { PixelRect(x: Int(w.minX * scale), y: Int(w.minY * scale), w: Int(w.width * scale), h: Int(w.height * scale)) }
            var t = 1.0
            _ = step(p, frame(scene(a), dirty: [px(a)], t: t), now: t, snapshot: snap(a))
            settle(p, from: &t, snapshot: snap(a))
            t += 1
            moves.append(step(p, frame(scene(b), dirty: [px(a), px(b)], t: t), now: t, snapshot: snap(b)))
        }
        out["windowMove"] = ["pages": pages.count, "moveMs": stat(moves.map(\.totalMs)), "stages": stages(moves)]
        print("window move: median \(r1(median(moves.map(\.totalMs)))) ms")

        // Scrolling back: down 900 pixels in steps of 150, then back up, in steps of 150 (the same places)
        // and of 100 (other places).
        for (name, upStep) in [("sameOffsets", 150), ("otherOffsets", 100)] {
            detector.removeCachedVerdicts()
            let p = primed(unlimited: true)
            var t = 1.0
            var down: [BenchStep] = [], up: [BenchStep] = []
            let whole = [PixelRect(x: 0, y: 0, w: W, h: H)]
            for off in stride(from: 0, through: 900, by: 150) {
                t += 0.5
                down.append(step(p, frame(viewport(off), dirty: whole, t: t), now: t))
                settle(p, from: &t)
            }
            for off in stride(from: 900 - upStep, through: 0, by: -upStep) {
                t += 0.5
                up.append(step(p, frame(viewport(off), dirty: whole, t: t), now: t))
                settle(p, from: &t)
            }
            out["scrollBack-\(name)"] = ["downMs": stat(down.map(\.totalMs)), "backMs": stat(up.map(\.totalMs)), "backStages": stages(up)]
            print("scroll back (\(name)): down median \(r1(median(down.map(\.totalMs)))) ms, back median \(r1(median(up.map(\.totalMs)))) ms")
        }
        return out
    }

    // MARK: Case 6: what reuse costs the detector, in judgements (exact counts)

    /// Judges `img` within `area` until nothing is left unjudged (in one call, with no cap and no time limit):
    /// the judgements, calls and time that took. Counts are exact and stable; only times vary from run to run.
    func judgeFully(_ img: RGBAImage, _ ctx: JudgeContext, _ area: PixelRect) -> (judgements: Int, calls: Int, ms: Double, left: Int) {
        var j = 0, calls = 0, ms = 0.0, left = 0
        for _ in 0..<40 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let v = detector.judge(img, context: ctx, within: area, budget: Self.wholeCall)
            ms += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            j += v.judgements; calls += 1; left = v.overloaded
            if v.overloaded == 0 { break }
        }
        return (j, calls, ms, left)
    }

    /// Second clean checks in the background for everything seen clean once in `area` (none in builds without them).
    func checkInBackground(_ img: RGBAImage, _ ctx: JudgeContext, _ area: PixelRect) -> Int {
        guard o.backgroundChecks else { return 0 }
        var n = 0
        for _ in 0..<40 {
            let v = detector.secondChecks(img, context: ctx, within: area, budget: Self.wholeCall)
            n += v.judgements
            if v.secondChecksLeft == 0 { break }
        }
        return n
    }

    /// Reload of a busy page, a window moved with the same content, and scrolling back, each judged in full at the
    /// detector (no cover layer budget or time limit), so the judgements reuse costs are counted exactly. Each page is
    /// first judged in full; with background checks, pictures seen clean once then get their second check (counted
    /// apart); then the reuse is judged in full.
    /// The reuse case judges in calls with no cap, so each picture is judged once per showing and nothing is left over.
    static let wholeCall = 1_000_000

    func reuse() -> [String: Any] {
        let cap = detector.config.maxJudgementsPerCall
        detector.labSetCallCap(Self.wholeCall)
        defer { detector.labSetCallCap(cap) }
        var out: [String: Any] = [:]
        let pages = busyPages()
        let whole = PixelRect(x: 0, y: 0, w: W, h: H)
        var rows: [String: [Double]] = [:]
        func add(_ k: String, _ v: Double) { rows[k, default: []].append(v) }
        for page in pages {
            detector.removeCachedVerdicts()
            let ctx = JudgeContext(windowID: 1, startsCovered: false)
            let first = judgeFully(page.img, ctx, whole)
            add("firstJudgements", Double(first.judgements)); add("firstMs", first.ms)
            add("backgroundJudgements", Double(checkInBackground(page.img, ctx, whole)))
            let reload = judgeFully(page.img, ctx, whole)
            add("reloadJudgements", Double(reload.judgements)); add("reloadMs", reload.ms); add("reloadCalls", Double(reload.calls))
            let third = judgeFully(page.img, ctx, whole)
            add("thirdShowJudgements", Double(third.judgements)); add("thirdShowMs", third.ms)
        }
        // Window move: a 1000 x 700 point window showing part of a busy page moves 120 x 30 points.
        for page in pages {
            detector.removeCachedVerdicts()
            let a = CGRect(x: 100, y: 80, width: 1000, height: 700), b = a.offsetBy(dx: 120, dy: 30)
            func scene(_ w: CGRect) -> RGBAImage {
                var img = base
                let x0 = Int(w.minX * scale), y0 = Int(w.minY * scale), ww = Int(w.width * scale), hh = Int(w.height * scale)
                for y in 0..<hh { for x in 0..<ww {
                    let d = ((y0 + y) * W + x0 + x) * 4, s = (y * W + x) * 4
                    img.pixels[d] = page.img.pixels[s]; img.pixels[d + 1] = page.img.pixels[s + 1]; img.pixels[d + 2] = page.img.pixels[s + 2]
                } }
                return img
            }
            func px(_ w: CGRect) -> PixelRect { PixelRect(x: Int(w.minX * scale), y: Int(w.minY * scale), w: Int(w.width * scale), h: Int(w.height * scale)) }
            func ctx(_ w: CGRect) -> JudgeContext { JudgeContext(windowID: 7, startsCovered: false, sliceAnchor: SliceAnchor(x: Int(w.minX * scale), y: Int(w.minY * scale))) }
            let one = scene(a), two = scene(b)
            _ = judgeFully(one, ctx(a), px(a))
            add("moveBackgroundJudgements", Double(checkInBackground(one, ctx(a), px(a))))
            let moved = judgeFully(two, ctx(b), px(b))
            add("moveJudgements", Double(moved.judgements)); add("moveMs", moved.ms)
        }
        // Scrolling: down 900 pixels in steps of 150, then back up in steps of 150 (the same places) and of 100 (others).
        for (name, upStep) in [("sameOffsets", 150), ("otherOffsets", 100)] {
            detector.removeCachedVerdicts()
            func ctx(_ off: Int) -> JudgeContext { JudgeContext(windowID: 1, startsCovered: false, sliceAnchor: SliceAnchor(x: 0, y: -off)) }
            var bg = 0, back = 0, backMs = 0.0
            for off in stride(from: 0, through: 900, by: 150) {
                _ = judgeFully(viewport(off), ctx(off), whole)
                bg += checkInBackground(viewport(off), ctx(off), whole)
            }
            for off in stride(from: 900 - upStep, through: 0, by: -upStep) {
                let r = judgeFully(viewport(off), ctx(off), whole)
                back += r.judgements; backMs += r.ms
                bg += checkInBackground(viewport(off), ctx(off), whole)
            }
            out["scrollBack-\(name)"] = ["backJudgementsTotal": back, "backMsTotal": r1(backMs), "backgroundJudgementsTotal": bg]
            print("reuse scroll back (\(name)): \(back) judgements, \(r1(backMs)) ms; background \(bg)")
        }
        for (k, v) in rows { out[k] = ["median": r1(median(v)), "worst": r1(worst(v)), "total": r1(v.reduce(0, +)), "n": v.count] }
        print("reuse: reload median \(r1(median(rows["reloadJudgements"] ?? []))) judgements, \(r1(median(rows["reloadMs"] ?? []))) ms; window move median \(r1(median(rows["moveJudgements"] ?? []))) judgements")
        return out
    }

    // MARK: Run

    func run() {
        var cpu = [CChar](repeating: 0, count: 128); var size = 128
        sysctlbyname("machdep.cpu.brand_string", &cpu, &size, nil, 0)
        doc["bench"] = "safesightmac-bench/1"
        doc["label"] = o.label
        doc["chip"] = String(cString: cpu)
        doc["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        doc["models"] = o.modelsNote
        doc["rule"] = detector.config.rule.rawValue
        doc["backgroundSecondChecks"] = o.backgroundChecks
        doc["display"] = "1440 x 900 points at 2x (2880 x 1800 pixels), one window filling it"
        doc["notIncluded"] = "ScreenCaptureKit capture latency and real display time are not included: they need ST-031 on a test Mac. Times run from the frame handed to the cover layer to the cover layer's layers built on a detached layer (no window)."
        frameCopy()
        // Warm-up: models load lazily on first use (the tie-breaker on the GPU too).
        detector.warmUp()
        _ = primed()
        if o.cases.contains("single") { single() }
        if o.cases.contains("grid") { grid() }
        if o.cases.contains("busy") {
            doc["busy"] = ["register": busy(unlimited: false), "unlimited": busy(unlimited: true), "registerPointer": busy(unlimited: false, pointer: probe)]
        }
        if o.cases.contains("scroll") {
            var sc: [String: Any] = [:]
            for sp in o.scrollSpeeds { sc["\(sp)px-register"] = scroll(speed: sp, unlimited: false); sc["\(sp)px-unlimited"] = scroll(speed: sp, unlimited: true) }
            doc["scroll"] = sc
        }
        if o.cases.contains("reappear") { doc["reappear"] = reappear() }
        if o.cases.contains("reuse") { doc["reuse"] = reuse() }
        if let j = o.json {
            let data = try! JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: j))
            print("wrote \(j)")
        }
    }
}
#endif
