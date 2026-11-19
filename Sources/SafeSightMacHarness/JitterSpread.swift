// SPDX-License-Identifier: Apache-2.0
// safesightmac-harness jitter (lab builds only): how far the deliberate jitter moves each real model's score on
// harmless screens, per size band. The clean-cache margin (`VerdictCache.CLEAN_CACHE_MARGIN`) is checked against it.
//
//   SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness jitter \
//       --models DIR --list FILE --root DIR [--draws N] [--per-band K] [--background B] [--every K] [--json FILE]
//
// Harmless pictures only (the lab's held-out harmless screens). Every entry the detector's first call would
// judge on a screen (finder regions, the whole pass, the slices) is judged once with each scoring model, as in
// the product. Then a sample of entries is judged `--draws` more times, each with fresh jitter on every piece:
// per model and band, up to `--per-band` entries that came within `SELECT` of the entry's lowest action cut-off
// (cover, or containment where a blur can apply), and `--background` entries at random. The spread of each
// entry's scores (highest minus lowest, and the largest distance from its median) is summarised per model and
// band. Scores are summarised, never written one by one.
#if SAFESIGHTMAC_LAB
import DetectorCore
import Foundation
import Preprocess

enum JitterSpread {
    /// Entries whose single first score came within this share of the lowest action cut-off are candidates
    /// for the many-draw judging (below the margin's 0.5, so entries whose other draws may reach it are in).
    static let SELECT: Float = 0.35

    /// One entry of one screen, from the first pass.
    struct Seen {
        var screen: Int
        var entry: Detector.LabEntry
        var first: [String: Float]
    }

    /// One entry's many draws for one model, summarised.
    struct Spread {
        var model: String, band: String, pass: String, containable: Bool
        var cover: Float, clean: Float
        var lo: Float, hi: Float, median: Float, dev: Float
        /// The entry's single first score (pass 1), which chose it for the sample.
        var first: Float
        var selected: Bool, background: Bool
        var range: Float { hi - lo }
        /// The lowest cut-off at which this entry's outcome changes: containment where a blur can apply.
        var action: Float { containable ? min(cover, clean) : cover }
    }

    /// A small deterministic generator for the sample (jitter itself comes from the system random source).
    struct SplitMix { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E37_79B9_7F4A_7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB; return z ^ (z >> 31) } }

    static func quantile(_ a: [Float], _ q: Double) -> Float {
        guard !a.isEmpty else { return .nan }
        let s = a.sorted()
        // The nearest-rank quantile, rounded up: on fewer than 1/(1-q) values it is the largest.
        let k = min(s.count - 1, Int((q * Double(s.count)).rounded(.up)) - 1)
        return s[max(0, k)]
    }

    static func r4(_ x: Float) -> Double { x.isFinite ? (Double(x) * 1e4).rounded() / 1e4 : -1 }

    static func run(detector d: Detector, list: String, root: String, o: JitterSettings, json: String?, modelsNote: String) {
        guard let text = try? String(contentsOfFile: list, encoding: .utf8) else { fail("unreadable list \(list)") }
        let all = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let files = all.enumerated().filter { $0.offset % max(1, o.every) == 0 }.map(\.element)
        let ids = d.labModelIDs
        func load(_ f: String) -> RGBAImage? {
            ImageLoading.load(URL(fileURLWithPath: f.hasPrefix("/") ? f : (root as NSString).appendingPathComponent(f)))
        }
        d.warmUp()
        let t0 = Date()

        // Batching is used only here, for speed: check that it gives the same scores as one at a time.
        var parity: [String: Float] = [:], parityEntries = 0
        if let f = files.first, let img = load(f) {
            for e in d.labEntries(img).prefix(40) {
                for (k, v) in d.labBatchParity(img, rect: e.rect, draws: 8) { parity[k] = max(parity[k] ?? 0, v) }
                parityEntries += 1
            }
        }
        print("batch parity: \(parityEntries) entries, largest difference \(parity)")

        // Pass 1: every entry, one judgement per model, as the product judges it.
        var seen: [Seen] = []
        var failed = 0
        for (i, f) in files.enumerated() {
            guard let img = load(f) else { print("unreadable: \(f)"); continue }
            let entries = d.labEntries(img)
            for (e, s) in zip(entries, d.labJitterDraws(img, rects: entries.map(\.rect), draws: 1)) {
                if s.count < ids.count { failed += 1; continue }
                seen.append(Seen(screen: i, entry: e, first: s.mapValues { $0[0] }))
            }
            if (i + 1) % 50 == 0 || i + 1 == files.count { print("pass 1: \(i + 1)/\(files.count) screens, \(seen.count) entries, \(Int(Date().timeIntervalSince(t0))) s") }
        }

        // The sample: per model and band, up to `perBand` entries near an action cut-off; and a background.
        var rng = SplitMix(s: o.seed)
        func shuffled<T>(_ a: [T]) -> [T] {
            var a = a
            if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, Int(rng.next() % UInt64(i + 1))) } }
            return a
        }
        func action(_ m: String, _ e: Detector.LabEntry) -> Float {
            let c = d.labCutoffs(model: m, shortSide: e.rect.shortSide)
            return e.containable ? min(c.cover, c.clean) : c.cover
        }
        var selected = Set<Int>(), background = Set<Int>()
        var candidates: [String: Int] = [:]
        for m in ids {
            for b in Band.allCases {
                let c = seen.indices.filter { Band(shortSide: seen[$0].entry.rect.shortSide) == b && seen[$0].first[m]! >= SELECT * action(m, seen[$0].entry) }
                candidates["\(m)|\(b.rawValue)"] = c.count
                selected.formUnion(shuffled(c).prefix(o.perBand))
            }
        }
        for b in Band.allCases {
            background.formUnion(shuffled(seen.indices.filter { Band(shortSide: seen[$0].entry.rect.shortSide) == b }).prefix(o.background))
        }
        let chosen = selected.union(background)
        print("sample: \(selected.count) entries near a cut-off, \(background.count) at random, \(chosen.count) in all, of \(seen.count)")

        // Pass 2: the sample, `draws` judgements each, fresh jitter every time.
        var spreads: [Spread] = []
        let byScreen = Dictionary(grouping: chosen.sorted(), by: { seen[$0].screen })
        var done = 0
        for (n, (screen, idx)) in byScreen.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let img = load(files[screen]) else { continue }
            for (k, s) in zip(idx, d.labJitterDraws(img, rects: idx.map { seen[$0].entry.rect }, draws: o.draws)) {
                let e = seen[k].entry
                if s.count < ids.count { failed += 1; continue }
                for m in ids {
                    let v = s[m]!.sorted()
                    let med = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
                    let c = d.labCutoffs(model: m, shortSide: e.rect.shortSide)
                    spreads.append(Spread(model: m, band: Band(shortSide: e.rect.shortSide).rawValue, pass: e.pass.rawValue, containable: e.containable,
                                          cover: c.cover, clean: c.clean, lo: v.first!, hi: v.last!, median: med,
                                          dev: max(med - v.first!, v.last! - med), first: seen[k].first[m]!,
                                          selected: selected.contains(k), background: background.contains(k)))
                }
                done += 1
            }
            if (n + 1) % 50 == 0 || n + 1 == byScreen.count { print("pass 2: \(n + 1)/\(byScreen.count) screens, \(done) entries, \(Int(Date().timeIntervalSince(t0))) s") }
        }

        // Summaries. The population that sets the margin: entries whose highest draw reached half the entry's
        // lowest action cut-off (the ones today's rule judges again, at least sometimes; only their caching can
        // change with the margin).
        func summary(_ a: [Spread]) -> [String: Any] {
            let r = a.map(\.range), dv = a.map(\.dev)
            return ["entries": a.count,
                    "range": ["p50": r4(quantile(r, 0.5)), "p90": r4(quantile(r, 0.9)), "p99": r4(quantile(r, 0.99)), "p999": r4(quantile(r, 0.999)), "max": r4(r.max() ?? .nan)],
                    "deviationFromMedian": ["p99": r4(quantile(dv, 0.99)), "p999": r4(quantile(dv, 0.999)), "max": r4(dv.max() ?? .nan)]]
        }
        var out: [String: Any] = [:]
        var table: [String: Any] = [:]
        for m in ids {
            var bands: [String: Any] = [:]
            for b in Band.allCases {
                let mine = spreads.filter { $0.model == m && $0.band == b.rawValue }
                if mine.isEmpty { continue }
                let border = mine.filter { $0.hi >= 0.5 * $0.action }
                let bg = mine.filter(\.background)
                // The spread that sets the gap: the 99.9th percentile of the range over the borderline population
                // (on fewer than 1,000 entries, that is the largest range seen).
                let spread = quantile(border.map(\.range), 0.999)
                let gap = 2 * spread
                // Empirical check on the borderline entries: one draw below the level, another at or above the
                // action cut-off. Today's level (half the cut-off) against the measured one.
                func crossings(_ level: (Spread) -> Float) -> Int { border.filter { $0.lo < level($0) && $0.hi >= $0.action }.count }
                let byPass = Dictionary(grouping: border, by: \.pass).mapValues { summary($0) }
                // What the selection could miss: random entries whose first score was under the selection level
                // but whose draws reached half the action cut-off.
                let missed = bg.filter { $0.first < SELECT * $0.action && $0.hi >= 0.5 * $0.action }
                let byLevel: [String: Any] = ["under0.5xAction": summary(border.filter { $0.median < 0.5 * $0.action }),
                                              "0.5to0.8xAction": summary(border.filter { $0.median >= 0.5 * $0.action && $0.median < 0.8 * $0.action }),
                                              "atLeast0.8xAction": summary(border.filter { $0.median >= 0.8 * $0.action })]
                let c = mine[0]
                bands[b.rawValue] = ["cutoffs": ["cover": r4(c.cover), "clean": r4(c.clean)],
                                     "candidatesNearACutoff": candidates["\(m)|\(b.rawValue)"] ?? 0,
                                     "borderline": summary(border), "borderlineByPass": byPass, "borderlineByMedian": byLevel,
                                     "background": summary(bg), "allSampled": summary(mine),
                                     "backgroundBorderlineNotSelectable": summary(missed),
                                     "spreadP999": r4(spread), "gap2xSpread": r4(gap),
                                     "levelAtCover": r4(c.cover - gap), "shareOfCover": r4((c.cover - gap) / c.cover),
                                     "levelAtClean": b == .b128 ? NSNull() as Any : r4(c.clean - gap) as Any,
                                     "shareOfClean": b == .b128 ? NSNull() as Any : r4((c.clean - gap) / c.clean) as Any,
                                     "crossingsAtToday0.5": crossings { 0.5 * $0.action },
                                     "crossingsAtMeasuredLevel": crossings { $0.action - gap },
                                     "borderlineEntriesWithRangeOverGap": border.filter { $0.range > gap }.count]
                print("\(m) \(b.rawValue): borderline \(border.count), range p999 \(r4(spread)), max \(r4(border.map(\.range).max() ?? .nan)), gap \(r4(gap)); background \(bg.count) p999 \(r4(quantile(bg.map(\.range), 0.999)))")
            }
            table[m] = bands
        }
        out["jitter"] = "safesightmac-jitter/1"
        out["date"] = ISO8601DateFormatter().string(from: Date())
        out["models"] = modelsNote
        out["list"] = (list as NSString).lastPathComponent
        out["screens"] = files.count
        out["every"] = o.every
        out["entriesJudgedOnce"] = seen.count
        out["entriesSampled"] = chosen.count
        out["draws"] = o.draws
        out["perBand"] = o.perBand
        out["backgroundPerBand"] = o.background
        out["select"] = Double(SELECT)
        out["modelFailures"] = failed
        out["seconds"] = Int(Date().timeIntervalSince(t0))
        out["batchParity"] = ["entries": parityEntries, "draws": 8, "largestDifference": parity.mapValues { r4($0) }] as [String: Any]
        out["method"] = "Harmless held-out screens only. Every entry of the detector's first call over each screen (finder regions, the whole pass, the slices; no anchor) judged once per scoring model with fresh jitter. Sampled: per model and band, up to perBand entries whose first score reached \(SELECT) of the entry's lowest action cut-off (containment for picture regions under 128 detail pixels, else cover), plus backgroundPerBand at random; each judged `draws` more times with fresh jitter on every piece (spec section 5), top score over the pieces per draw, as topScore. Range: highest minus lowest draw of an entry. deviationFromMedian: the largest distance of a draw from the entry's median. Borderline: entries whose highest draw reached half the entry's lowest action cut-off; the gap is twice the 99.9th percentile of their range (the largest range on fewer than 1,000 entries). Crossings: borderline entries with one draw below the level and another at or above the action cut-off."
        out["byModel"] = table
        if let j = json, let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: j))
            print("wrote \(j)")
        }
    }
}
#endif
