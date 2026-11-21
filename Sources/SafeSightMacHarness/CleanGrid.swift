// SPDX-License-Identifier: Apache-2.0
// Part of `safesightmac-harness jitter` (lab builds only): the clean-cache rule against the jitter draws, for a grid of
// settings. For each margin (`CLEAN_CACHE_MARGIN`, a share of the cut-off) and number of clean checks (`CLEAN_CHECKS`),
// and for two designs:
//
//   restart  today's design: a judgement at or over the margin starts the count again, so a picture shown often enough
//            can still be cached clean on `checks` lucky draws in a row.
//   sticky   the alternative (`VerdictCache.CleanRule.sticky`): a judgement at or over the margin marks the picture as
//            never to be cached clean while it is held, so only its first `checks` judgements can cache it.
//
// Protection: the crossings (harmless borderline entries with one draw under half their action cut-off and another at or
// over it), and how many of them each setting could cache clean. Cost: the share of ordinary harmless entries that the
// setting leaves uncacheable. Draws are taken in the order made, as successive showings; probabilities take them as
// independent, each under the margin with the entry's observed share. Counts and shares only: no score is written.
#if SAFESIGHTMAC_LAB
import DetectorCore
import Foundation

enum CleanGrid {
    static let margins: [Float] = [0.5, 0.4, 0.3, 0.25, 0.2, 0.1]
    static let checks = [2, 3]
    /// Showings over which "cached within N showings" is worked out (the earlier measurements had 20 draws).
    static let showings = 20

    /// One sampled entry's draws, as shares of each model's cut-offs (kept in memory only).
    struct Entry {
        var band: String, pass: String, containable: Bool, selected: Bool, background: Bool
        /// Per model, in the order made: draw / action cut-off, and draw / cover cut-off.
        var action: [String: [Float]], cover: [String: [Float]]
    }

    /// The chance of `k` successes in a row within `n` independent trials, each a success with `p`.
    static func runWithin(p: Double, k: Int, n: Int) -> Double {
        guard k > 0 else { return 1 }
        guard p > 0, n >= k else { return 0 }
        // state: current run length 0..<k; absorbed mass is the answer.
        var st = [Double](repeating: 0, count: k); st[0] = 1
        var done = 0.0
        for _ in 0..<n {
            var nx = [Double](repeating: 0, count: k)
            for r in 0..<k where st[r] > 0 {
                nx[0] += st[r] * (1 - p)
                if r + 1 == k { done += st[r] * p } else { nx[r + 1] += st[r] * p }
            }
            st = nx
        }
        return done
    }

    /// Whether `u` holds `k` trues in a row.
    static func hasRun(_ u: [Bool], _ k: Int) -> Bool {
        var r = 0
        for x in u { r = x ? r + 1 : 0; if r >= k { return true } }
        return false
    }

    /// The probability that a picture whose judgements are each clearly clean with `p` is ever cached clean: within
    /// `showings` showings for `restart`, and for good for `sticky` (only its first `k` can).
    static func pCached(p: Double, k: Int, sticky: Bool) -> Double { sticky ? pow(p, Double(k)) : runWithin(p: p, k: k, n: showings) }

    /// Whether the draws in order cached the picture: `k` in a row anywhere (restart), the first `k` (sticky).
    static func observed(_ u: [Bool], k: Int, sticky: Bool) -> Bool { sticky ? (u.count >= k && u.prefix(k).allSatisfy { $0 }) : hasRun(u, k) }

    static func r4(_ x: Double) -> Double { (x * 1e4).rounded() / 1e4 }

    struct Crossing {
        var label: String, band: String, pass: String
        /// Per draw: clearly clean at a margin is `share < margin` (the share is the largest over the models concerned).
        var shares: [Float]
    }

    /// The analysis, as a JSON object. `first` is pass 1: every entry's single first draw, as (band, containable, per
    /// model draw / cover, draw / action).
    static func analyse(sampled: [Entry], first: [(band: String, containable: Bool, cover: [Float], action: [Float])], ids: [String], draws: Int) -> [String: Any] {
        // Crossings, per model (as the earlier measurements counted them) and per entry (the product's rule: every model
        // clearly clean in the same judgement; any model at or over its action cut-off).
        var perModel: [Crossing] = [], joint: [Crossing] = []
        for e in sampled {
            for m in ids {
                guard let a = e.action[m], let lo = a.min(), let hi = a.max() else { continue }
                if lo < 0.5 && hi >= 1 { perModel.append(Crossing(label: m, band: e.band, pass: e.pass, shares: a)) }
            }
            let n = ids.compactMap { e.action[$0]?.count }.min() ?? 0
            guard n > 0, ids.allSatisfy({ e.action[$0] != nil }) else { continue }
            let worst = (0..<n).map { j in ids.map { e.action[$0]![j] }.max()! }
            if worst.min()! < 0.5 && worst.max()! >= 1 { joint.append(Crossing(label: "all", band: e.band, pass: e.pass, shares: worst)) }
        }

        func protection(_ cs: [Crossing], margin: Float, k: Int, sticky: Bool) -> [String: Any] {
            var obs = 0, possible = 0, sumFirst = 0.0, sumCached = 0.0, worst = 0.0
            var each: [[String: Any]] = []
            for c in cs {
                let u = c.shares.map { $0 < margin }
                let under = u.filter { $0 }.count
                let p = Double(under) / Double(max(1, u.count))
                if observed(u, k: k, sticky: sticky) { obs += 1 }
                if under > 0 { possible += 1 }
                let pk = pow(p, Double(k)), pc = pCached(p: p, k: k, sticky: sticky)
                sumFirst += pk; sumCached += pc; worst = max(worst, pc)
                if under > 0 {
                    each.append(["model": c.label, "band": c.band, "pass": c.pass, "drawsUnderMargin": under, "draws": u.count,
                                 "pFirstChecks": r4(pk), "pCached": r4(pc), "cachedInTheseDraws": observed(u, k: k, sticky: sticky)])
                }
            }
            return ["crossings": cs.count, "withADrawUnderMargin": possible, "cachedInTheseDraws": obs,
                    "expectedCachedOnFirstChecks": r4(sumFirst), "expectedCached": r4(sumCached), "largestPCached": r4(worst),
                    "cacheableCrossings": each]
        }

        // Cost, pass 1: one draw of every entry. Not cacheable: any model at or over the margin of its cover cut-off. Not
        // settled for a blur (picture regions where one can apply): any model at or over the margin of its action cut-off.
        func cost1(margin: Float, k: Int, sticky: Bool) -> [String: Any] {
            var byBand: [String: [String: Any]] = [:]
            var all = 0, notCache = 0, cont = 0, notSettled = 0
            for b in Band.allCases.map(\.rawValue) {
                let es = first.filter { $0.band == b }
                if es.isEmpty { continue }
                let nc = es.filter { $0.cover.max()! >= margin }.count
                let cs = es.filter(\.containable)
                let ns = cs.filter { $0.action.max()! >= margin }.count
                byBand[b] = ["entries": es.count, "notCacheableOneDraw": r4(Double(nc) / Double(es.count)),
                             "containable": cs.count, "notSettledForBlurOneDraw": cs.isEmpty ? NSNull() as Any : r4(Double(ns) / Double(cs.count)) as Any]
                all += es.count; notCache += nc; cont += cs.count; notSettled += ns
            }
            // A picture judged clearly clean with `p` a showing needs `k` such showings; with one draw each, the share
            // that clears all `k` is estimated as (1 - notCacheable)^k only for independent draws, which ordinary pictures
            // far from a cut-off are not (they are clean every time). So pass 1 gives the one-draw share only.
            return ["entries": all, "notCacheableOneDraw": r4(Double(notCache) / Double(max(1, all))),
                    "containable": cont, "notSettledForBlurOneDraw": r4(Double(notSettled) / Double(max(1, cont))), "byBand": byBand]
        }

        // Cost, the random background sample (many draws): the share of ordinary entries the setting never caches clean
        // (cover cut-off; where no blur can apply), in these draws and as a probability, weighted by each band's share of
        // pass 1's entries.
        let bandCount = Dictionary(grouping: first, by: \.band).mapValues(\.count)
        let bg = sampled.filter(\.background)
        func cost2(margin: Float, k: Int, sticky: Bool) -> [String: Any] {
            var byBand: [String: Any] = [:]
            var wNever = 0.0, wP = 0.0, wTot = 0.0
            for (b, es) in Dictionary(grouping: bg, by: \.band) {
                var never = 0, pSum = 0.0, n = 0
                for e in es {
                    guard ids.allSatisfy({ e.cover[$0] != nil }) else { continue }
                    let d = ids.map { e.cover[$0]!.count }.min()!
                    let u = (0..<d).map { j in ids.map { e.cover[$0]![j] }.max()! < margin }
                    let p = Double(u.filter { $0 }.count) / Double(max(1, d))
                    if !observed(u, k: k, sticky: sticky) { never += 1 }
                    pSum += 1 - pCached(p: p, k: k, sticky: sticky)
                    n += 1
                }
                guard n > 0 else { continue }
                byBand[b] = ["entries": n, "neverCachedInTheseDraws": r4(Double(never) / Double(n)), "pNeverCached": r4(pSum / Double(n))]
                let w = Double(bandCount[b] ?? 0)
                wNever += w * Double(never) / Double(n); wP += w * pSum / Double(n); wTot += w
            }
            return ["neverCachedInTheseDraws": r4(wNever / max(1, wTot)), "pNeverCached": r4(wP / max(1, wTot)), "byBand": byBand,
                    "note": "random entries of the sampled bands, weighted by each band's share of pass 1's entries in those bands"]
        }

        var grid: [[String: Any]] = []
        for sticky in [false, true] {
            for k in checks {
                for m in margins {
                    let name = "\(sticky ? "sticky" : "restart") margin \(m) checks \(k)"
                    grid.append(["setting": name, "design": sticky ? "sticky" : "restart", "margin": Double(m), "checks": k,
                                 "today": !sticky && m == 0.5 && k == 2,
                                 "protectionPerModel": protection(perModel, margin: m, k: k, sticky: sticky),
                                 "protectionPerEntry": protection(joint, margin: m, k: k, sticky: sticky),
                                 "costOneDraw": cost1(margin: m, k: k, sticky: sticky),
                                 "costBackground": cost2(margin: m, k: k, sticky: sticky)])
                }
            }
        }
        // The lowest draw share of each crossing: a margin at or under it can never cache that crossing.
        let floors = perModel.map { Double($0.shares.min()!) }.sorted()
        return ["draws": draws, "showings": showings, "crossingsPerModel": perModel.count, "crossingsPerEntry": joint.count,
                "crossingLowestDrawShareOfActionCutoff": ["min": floors.first.map(r4) ?? -1, "p10": floors.isEmpty ? -1 : r4(floors[floors.count / 10]),
                                                         "median": floors.isEmpty ? -1 : r4(floors[floors.count / 2])],
                "method": "Crossings: per model, a sampled entry with a draw under half its action cut-off (containment where a blur can apply, else cover) and another at or over it; per entry, the same with every model's draws taken together (clearly clean only when every model is under the margin in the same draw; any model at or over its cut-off). Restart: cached when `checks` draws in a row are under the margin (cachedInTheseDraws: in this entry's draws in order; pCached: within \(showings) showings, the draws taken as independent with the entry's observed share under the margin). Sticky: cached only when its first `checks` draws are under the margin (pCached = share^checks, for good). expectedCachedOnFirstChecks: the sum of share^checks over the crossings. Cost: costOneDraw from pass 1 (every entry, one draw: share at or over the margin of the cover cut-off for any model, and of the action cut-off for picture regions where a blur can apply); costBackground from the random sample's draws (share never cached clean at the cover cut-off).",
                "grid": grid]
    }
}
#endif
