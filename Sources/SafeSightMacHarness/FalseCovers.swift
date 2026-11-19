// SPDX-License-Identifier: Apache-2.0
// safesightmac-harness falsecovers: false covers and blurs on harmless screens, through the whole pipeline
// (cover layer, window split, the detector with every rule, the sealed cut-off table, all three models).
// Harmless pictures only. Works in release builds (no lab hook is used).
//
//   safesightmac-harness falsecovers --models DIR --list FILE [--root DIR] [--rule balanced|either]
//                                    [--jsonl FILE] [--json FILE]
//
// Each screen is shown in one window filling a display (2x when at least 2560 pixels wide, else 1x) and
// judged as a new frame; the cover layer then keeps judging what it left unjudged (budget unlimited, so
// that every tile is judged) until nothing is left. Every screen is harmless, so every model cover or
// blur is a false one. Records hold classes, reasons, passes and sizes only, never a score.
import CoreGraphics
import DetectorCore
import Foundation
import Preprocess
import SafeSightMacWatcher

/// Forwards to the detector and keeps every verdict (classes only).
final class RecordingJudger: Judging {
    let inner: Detector
    var verdicts: [FrameVerdict] = []
    init(_ d: Detector) { inner = d }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict {
        let v = inner.judgeArea(frame, context: context, within: area, budget: budget)
        verdicts.append(v)
        return v
    }
    func setRule(_ rule: DetectorRule) { inner.setRule(rule) }
}

enum FalseCovers {
    static let modelCoverReasons: Set<Reason> = [.bothFamilies, .referee, .disputed]
    static let modelBlurReasons: Set<Reason> = [.containedSmall, .hotContext]

    /// Wilson score interval, 95%.
    static func wilson(_ k: Int, _ n: Int) -> [Double] {
        guard n > 0 else { return [0, 1] }
        let z = 1.959964, p = Double(k) / Double(n), d = 1 + z * z / Double(n)
        let c = (p + z * z / (2 * Double(n))) / d, h = z * ((p * (1 - p) / Double(n) + z * z / (4 * Double(n) * Double(n))).squareRoot()) / d
        return [max(0, c - h), min(1, c + h)].map { ($0 * 1e6).rounded() / 1e6 }
    }

    static func group(of path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if path.contains("negatives") { return parts[parts.count - 2] }
        let name = parts.last ?? path
        let kind = name.split(separator: "-").first.map(String.init) ?? "other"
        return path.contains("synthetic-pages") ? "generated-pages-" + kind : "composed-" + kind
    }

    struct Counter {
        var screens = 0, screensWithFalseCover = 0, screensWithFalseCoverFirstCall = 0, screensWithFalseBlur = 0
        var screensWithLastingCover = 0, screensMadeHot = 0, strikes = 0, coverWindow = 0
        var falseCoverEntries = 0, falseCoverEntriesFirstCall = 0, falseBlurEntries = 0, judgedEntries = 0, judgedRegions = 0
        var byReason: [String: Int] = [:], byPass: [String: Int] = [:], byBand: [String: Int] = [:], judgedByBand: [String: Int] = [:]
        var under32Covers = 0, calls = 0, ms = 0.0, coveredShareSum = 0.0
        var firstCallOverloaded = 0

        func json() -> [String: Any] {
            ["screens": screens, "screensWithFalseCover": screensWithFalseCover, "screensWithFalseCover95": FalseCovers.wilson(screensWithFalseCover, screens),
             "screensWithFalseCoverFirstCallOnly": screensWithFalseCoverFirstCall, "screensWithFalseBlur": screensWithFalseBlur,
             "screensWithLastingCoverInFinalPlan": screensWithLastingCover, "screensMadeHot": screensMadeHot, "strikes": strikes,
             "wholeWindowCovers": coverWindow,
             "falseCoverEntries": falseCoverEntries, "falseCoverEntriesFirstCallOnly": falseCoverEntriesFirstCall, "falseBlurEntries": falseBlurEntries,
             "judgedEntries": judgedEntries, "falseCoverPerEntry95": FalseCovers.wilson(falseCoverEntries, judgedEntries),
             "judgedRegionEntries": judgedRegions,
             "falseCoversByReason": byReason, "falseCoversByPass": byPass, "falseCoverRegionsByBand": byBand, "judgedRegionsByBand": judgedByBand,
             "falseCoversUnder32px": under32Covers, "firstCallOverloadedEntries": firstCallOverloaded,
             "meanCoveredShareOfFinalPlan": screens > 0 ? (coveredShareSum / Double(screens) * 1e5).rounded() / 1e5 : 0,
             "calls": calls, "msPerScreen": screens > 0 ? (ms / Double(screens)).rounded() : 0]
        }
    }

    static func run(detector: Detector, list: String, root: String, rule: DetectorRule, jsonl: String?, json: String?, modelsNote: String) {
        detector.setRule(rule)
        guard let text = try? String(contentsOfFile: list, encoding: .utf8) else { fail("unreadable list \(list)") }
        let files = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: FileHandle? = nil
        if let j = jsonl { FileManager.default.createFile(atPath: j, contents: nil); out = FileHandle(forWritingAtPath: j) }
        var groups: [String: Counter] = [:], total = Counter()
        let t0 = Date()
        for (i, f) in files.enumerated() {
            let path = f.hasPrefix("/") ? f : (root as NSString).appendingPathComponent(f)
            guard let img = ImageLoading.load(URL(fileURLWithPath: path)) else { print("unreadable: \(f)"); continue }
            let scale: CGFloat = img.width >= 2560 ? 2 : 1
            let size = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
            let display = DisplayDescriptor(id: 1, bounds: CGRect(origin: .zero, size: size))
            guard let map = CaptureMap(displayBounds: display.bounds, contentRect: CGRect(origin: .zero, size: size), contentScale: 1,
                                       scaleFactor: scale, pixelWidth: img.width, pixelHeight: img.height) else { continue }
            // A window number of its own per screen, so that no state (hot windows) carries between screens.
            let snap = WindowSnapshot(windows: [WindowInfo(number: UInt32(i + 1), ownerPID: 500, layer: 0, bounds: display.bounds)], time: 0)
            let rec = RecordingJudger(detector)
            let p = DisplayPipeline(display: display, judger: rec, budgetShare: 1e9, ignoredPIDs: [])
            let start = Date()
            var t = 0.0
            var plan = p.process(CapturedFrame(display: display, status: .complete, image: img, map: map, dirty: nil, time: t), snapshot: snap, now: t)
            let firstCallCount = rec.verdicts.count
            // Keep judging what was left unjudged. Small time steps, so that no slowness rule fires: this run
            // measures the models' verdicts, not the budget.
            // Then a few more still frames, so that covers left over from unjudged entries can lift (four
            // clean judgements); what stays after that is lasting.
            var settled = 0
            for _ in 0..<80 {
                let overloaded = rec.verdicts.last.map { $0.overloaded > 0 } ?? false
                if !overloaded { if plan.items.isEmpty || settled >= Register.VIDEO_VOTE + 1 { break }; settled += 1 }
                t += 0.001
                plan = p.process(CapturedFrame(display: display, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t)
            }
            let ms = Date().timeIntervalSince(start) * 1000
            // Entries by (pass, rect): the strongest judged class over all calls.
            struct Key: Hashable { var pass: JudgePass; var rect: PixelRect }
            var best: [Key: RegionVerdict] = [:]
            var firstCallCovers = 0
            for (k, v) in rec.verdicts.enumerated() {
                for e in v.regions where e.reason != .overload {
                    let key = Key(pass: e.pass, rect: e.rect)
                    if let b = best[key], b.display >= e.display { continue }
                    best[key] = e
                }
                if k < firstCallCount { firstCallCovers += v.regions.filter { $0.display == .cover && modelCoverReasons.contains($0.reason) }.count }
            }
            let entries = Array(best.values)
            let covers = entries.filter { $0.display == .cover && modelCoverReasons.contains($0.reason) }
            let blurs = entries.filter { $0.display == .contain && modelBlurReasons.contains($0.reason) }
            let coverWindow = rec.verdicts.contains { $0.coverWindow }
            let hot = rec.verdicts.contains { $0.hot }
            let strike = rec.verdicts.contains { $0.strike }
            let share = plan.wholeDisplay != nil ? 1.0 : coveredArea(plan) / Double(size.width * size.height)
            let g = group(of: f)
            for c in [g, "_total"] {
                var k = c == "_total" ? total : (groups[c] ?? Counter())
                k.screens += 1
                if !covers.isEmpty || coverWindow { k.screensWithFalseCover += 1 }
                if firstCallCovers > 0 { k.screensWithFalseCoverFirstCall += 1 }
                if !blurs.isEmpty { k.screensWithFalseBlur += 1 }
                if !plan.items.isEmpty || plan.wholeDisplay != nil { k.screensWithLastingCover += 1 }
                if hot { k.screensMadeHot += 1 }
                if strike { k.strikes += 1 }
                if coverWindow { k.coverWindow += 1 }
                k.falseCoverEntries += covers.count
                k.falseCoverEntriesFirstCall += firstCallCovers
                k.falseBlurEntries += blurs.count
                k.judgedEntries += entries.count
                k.judgedRegions += entries.filter { $0.pass == .region }.count
                for e in covers {
                    k.byReason[e.reason.rawValue, default: 0] += 1
                    k.byPass[e.pass.rawValue, default: 0] += 1
                    if e.pass == .region { k.byBand[Band(shortSide: e.rect.shortSide).rawValue, default: 0] += 1 }
                    if e.rect.shortSide < 32 { k.under32Covers += 1 }
                }
                for e in entries where e.pass == .region { k.judgedByBand[Band(shortSide: e.rect.shortSide).rawValue, default: 0] += 1 }
                k.calls += rec.verdicts.count
                k.ms += ms
                k.coveredShareSum += share
                k.firstCallOverloaded += rec.verdicts.prefix(firstCallCount).reduce(0) { $0 + $1.overloaded }
                if c == "_total" { total = k } else { groups[c] = k }
            }
            let line: [String: Any] = ["file": f, "group": g, "w": img.width, "h": img.height,
                                       "falseCovers": covers.count, "falseCoversFirstCall": firstCallCovers, "falseBlurs": blurs.count,
                                       "coverReasons": Dictionary(grouping: covers, by: { $0.reason.rawValue }).mapValues(\.count),
                                       "coverPasses": Dictionary(grouping: covers, by: { $0.pass.rawValue }).mapValues(\.count),
                                       "coverSides": covers.map { $0.rect.shortSide }.sorted(),
                                       "coverWindow": coverWindow, "hot": hot, "strike": strike, "judgedEntries": entries.count,
                                       "calls": rec.verdicts.count, "finalPlanItems": plan.items.count, "finalCoveredShare": (share * 1e4).rounded() / 1e4,
                                       "ms": Int(ms)]
            if let o = out, let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                o.write(d); o.write(Data("\n".utf8))
            }
            if (i + 1) % 25 == 0 || i + 1 == files.count {
                print("\(rule.rawValue): \(i + 1)/\(files.count) screens, \(total.screensWithFalseCover) with a false cover, \(total.falseCoverEntries) false-cover entries, \(Int(Date().timeIntervalSince(t0))) s")
            }
        }
        try? out?.close()
        var doc: [String: Any] = ["run": "safesightmac-falsecovers/1", "rule": rule.rawValue, "models": modelsNote,
                                  "cutoffTable": "models/thresholds.json as sealed in the build (agreement+referee/1)",
                                  "list": (list as NSString).lastPathComponent, "date": ISO8601DateFormatter().string(from: Date()),
                                  "method": "Each harmless screen in one window filling a display; judged through DisplayPipeline (window split, every detector rule, all three models under Balanced), then re-judged until nothing is left unjudged (budget unlimited). A false cover is an entry the models covered (both families, tie-breaker, or an unanswered dispute); a false blur is a contained small picture or a hot-window blur. Overload covers are not counted. Classes only; no score recorded.",
                                  "total": total.json()]
        doc["groups"] = groups.mapValues { $0.json() }
        if let j = json, let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: j))
        }
        print("done: \(total.screens) screens; \(total.screensWithFalseCover) with a false cover; \(total.falseCoverEntries) false-cover entries of \(total.judgedEntries) judged")
    }

    /// The union area of a plan's items, in square points (sampled on a 2-point grid).
    static func coveredArea(_ plan: CoverPlan) -> Double {
        let d = plan.display.bounds
        let rects = plan.items.map(\.rect)
        if rects.isEmpty { return 0 }
        var n = 0, hit = 0
        var y = d.minY + 1
        while y < d.maxY {
            var x = d.minX + 1
            while x < d.maxX {
                n += 1
                if rects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { hit += 1 }
                x += 2
            }
            y += 2
        }
        return n == 0 ? 0 : Double(hit) / Double(n) * Double(d.width * d.height)
    }
}
