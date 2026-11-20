// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// The judging core: three scales, jitter before every judgement, the decision and strike rules, the
// video voting, containment for small pictures, hot contexts, the verdict cache, and an
// overload path that always falls toward covering. Outputs are classes only.
import Foundation
import Preprocess
import RegionFinder

public struct DetectorConfig: Sendable {
    public var sliceSize = 512
    public var sliceStride = 384
    /// Model judgements (tile x model) allowed per call; beyond it, unjudged pictures are covered or blurred.
    public var maxJudgementsPerCall = 400
    /// Containment applies below this short side (detail pixels).
    public var containBelow = 64
    /// In hot contexts, pictures below this are blurred until cleared.
    public var hotBelow = 128
    /// Strikes need pictures at least this big (small-picture rules never create strikes).
    public var strikeMinSide = 64
    /// Below this short side a model flag still covers (register SD-125, correction C06-3 b) but never
    /// makes the window hot: the models are least reliable on tiny upscaled tiles.
    public var coverMinSide = 32
    /// A hot window with more picture tiles than this blurs its whole picture area.
    public var blurAllAbove = 200
    /// The detector rule. Balanced is the default (founder decision S-01).
    public var rule: DetectorRule = .balanced
    /// Pixels judged clear but too near a cut-off for the verdict cache (`Reason.judgedEarlier`) are due to be judged
    /// again after this long (seconds), as a full re-judge would (`FULL_REJUDGE` for show-first).
    public var rejudgeAfter: TimeInterval = 30
    public init() {}
}

#if KESTREL_LAB
/// Lab-only hook: a synthetic pattern detector that can only force a cover. Absent from release builds.
public protocol StandInDetector: AnyObject {
    func detects(_ img: RGBAImage, _ rect: PixelRect) -> Bool
}
#endif

public final class Detector {
    let models: ModelSet
    let table: ThresholdTable
    public private(set) var config: DetectorConfig
    let finder: RegionFinder
    let cache = VerdictCache()
    let finderCache = FinderCache()
    /// Exact pixels last judged clear but kept out of the verdict cache by the margin rule, with when they were last
    /// judged. Never reused as a judgement (see `Reason.judgedEarlier`). It orders the work: entries never judged come
    /// before entries judged earlier, and those go oldest first, so a budget too small for every borderline picture
    /// re-judges them in turn instead of spending itself on the same ones for ever while the rest stay unjudged.
    let seenClear = SeenClear()
    let voter = VideoVoter()
    let hot = HotContexts()
    /// Referee judgements made so far (for budgets and benchmarks).
    public private(set) var refereeCalls = 0
    /// Model failures since this detector was made, per model id: a model threw, or gave a score that is not
    /// usable (`usable`). Counts only, never a score, so a self-check can read them. A failure is never clear:
    /// the entry is left unjudged (covered or blurred, and judged again, as for any fault), and a failed
    /// tie-breaker leaves the dispute unanswered, which covers.
    public private(set) var modelFaults: [String: Int] = [:]
    private var faultTotal = 0
    /// Stage timings since the last `resetTimings()` (durations and counts only).
    public private(set) var timings = JudgeTimings()
    public func resetTimings() { timings = JudgeTimings() }
    var rng = SystemRandomNumberGenerator()
    #if KESTREL_LAB
    public var standIn: StandInDetector?
    /// LAB ONLY (absent from release builds): changes the per-call cap, so the lab bench can judge a whole page in one
    /// call and count exactly what reuse costs.
    public func labSetCallCap(_ n: Int) { config.maxJudgementsPerCall = n }
    #endif

    public convenience init(models: ModelSet, thresholdsURL: URL?, config: DetectorConfig = DetectorConfig(), finder: RegionFinder = RegionFinder()) throws {
        let t = try thresholdsURL.map { try ThresholdTable.load($0) } ?? ThresholdTable(schema: "kestrel-thresholds/1", models: [:])
        self.init(models: models, table: t, config: config, finder: finder)
    }

    /// Builds a detector from a cut-off table given as JSON bytes (for a table sealed inside the app).
    public convenience init(models: ModelSet, thresholdsJSON: Data, config: DetectorConfig = DetectorConfig(), finder: RegionFinder = RegionFinder()) throws {
        let t = try JSONDecoder().decode(ThresholdTable.self, from: thresholdsJSON)
        self.init(models: models, table: t, config: config, finder: finder)
    }

    init(models: ModelSet, table: ThresholdTable, config: DetectorConfig, finder: RegionFinder) {
        self.models = models; self.table = table; self.config = config; self.finder = finder
    }

    typealias Pass = JudgePass

    /// A call area whose short side is below this and that is more than 2:1 is a thin strip: its whole pass is grown to
    /// this short side and it has no slices.
    static let thinBelow = 64

    /// `r` grown on its short side to at least `side` (centred, kept inside the frame).
    static func grown(_ r: PixelRect, to side: Int, width: Int, height: Int) -> PixelRect {
        func grow(_ lo: Int, _ len: Int, _ limit: Int) -> (Int, Int) {
            guard len < side else { return (lo, len) }
            let n = min(side, limit)
            let start = min(max(0, lo - (n - len) / 2), max(0, limit - n))
            return (start, n)
        }
        if r.h <= r.w { let (y, h) = grow(r.y, r.h, height); return PixelRect(x: r.x, y: y, w: r.w, h: h) }
        let (x, w) = grow(r.x, r.w, width); return PixelRect(x: x, y: r.y, w: w, h: r.h)
    }

    /// Changes the detector rule. The verdict cache is emptied, because a cached outcome was made under
    /// the other rule (the tie-breaker is asked only under Balanced).
    public func setRule(_ rule: DetectorRule) {
        guard rule != config.rule else { return }
        config.rule = rule
        cache.removeAll()
        seenClear.removeAll()
    }

    /// Empties the verdict cache (lab benches measure from scratch with it; pausing may use it). Emptying
    /// only ever means judging again.
    public func removeCachedVerdicts() { cache.removeAll(); finderCache.removeAll(); seenClear.removeAll() }

    /// Runs every model once on a blank tensor, so that the first real judgement does not pay for loading
    /// (the tie-breaker on the GPU costs about 0.2 s the first time). Used by the lab bench.
    public func warmUp() {
        for m in models.models + models.students + (models.referee.map { [$0] } ?? []) {
            _ = try? m.flagScores([[UInt8](repeating: 128, count: 3 * m.side * m.side)])
        }
    }

    /// Runs every model on a blank tensor before anything is judged, and says whether each gave a usable score, all
    /// within `limit` seconds. A model's first prediction pays for loading it (on the Neural Engine Core ML can time
    /// that one out under load), so a model that fails is asked once more while time is left; a second failure, or
    /// running past `limit`, is a fault. Every failure is counted in `modelFaults`. Nothing is judged and nothing is
    /// cached; the caller keeps every display covered until this returns true.
    public func warmUp(limit: TimeInterval) -> Bool {
        let start = Date()
        for m in models.models + models.students + (models.referee.map { [$0] } ?? []) {
            let blank = [[UInt8](repeating: 128, count: 3 * m.side * m.side)]
            var ok = usableScores(m, blank) != nil
            if !ok && Date().timeIntervalSince(start) < limit { ok = usableScores(m, blank) != nil }
            guard ok, Date().timeIntervalSince(start) <= limit else { return false }
        }
        return true
    }

    /// The picture regions the finder sees in `area`, through the finder cache, so the judge call that follows on the same
    /// pixels finds them there. No model runs.
    public func pictures(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect] {
        let A = area.clamped(width: frame.width, height: frame.height) ?? PixelRect(x: 0, y: 0, w: frame.width, h: frame.height)
        let key = FinderCache.key(frame, A)
        if let hit = finderCache.get(key, for: A) { return hit.regions.map(\.rect) }
        let found = finder.find(frame, within: A)
        finderCache.put(key, A, found)
        return found.regions.map(\.rect)
    }

    /// The picture finder alone (the contract's `find`). Cheap; no model.
    public func find(_ frame: RGBAImage, within area: PixelRect? = nil) -> RegionFinder.Output {
        finder.find(frame, within: area)
    }

    /// Whether an outcome covers under the current rule.
    func confirmed(_ o: TileOutcome) -> Bool {
        switch config.rule {
        case .balanced: return o.confirmed
        case .either: return o.forced || o.flagA || o.flagB
        }
    }

    /// Whether an outcome is covered under the current rule: confirmed, or (Balanced) a dispute no tie-breaker
    /// could settle (SD-125, C06-3 c).
    func covers(_ o: TileOutcome) -> Bool {
        confirmed(o) || (config.rule == .balanced && o.disputed && !o.refereeRan)
    }

    struct Task {
        var rect: PixelRect      // what the verdict applies to
        var pieces: [PixelRect]  // aspect-limited pieces actually judged
        var pass: Pass
        var gridMember: Bool
        var key: ExactKey
        var outcome: TileOutcome?
        var judged = false
        /// The outcome came from the verdict cache in this call.
        var fromCache = false
    }

    /// Splits a rectangle into overlapping pieces whose aspect ratio is at most 2:1 (spec section 4).
    static func pieces(_ r: PixelRect) -> [PixelRect] {
        let long = max(r.w, r.h), short = min(r.w, r.h)
        if long <= 2 * short { return [r] }
        let piece = 2 * short, n = Int((Double(long - piece) / Double(piece * 3 / 4)).rounded(.up)) + 1
        let step = n > 1 ? (long - piece) / (n - 1) : 0
        return (0..<n).map { i in
            let off = i == n - 1 ? long - piece : i * step  // the last piece always reaches the far edge
            return r.w >= r.h ? PixelRect(x: r.x + off, y: r.y, w: piece, h: r.h) : PixelRect(x: r.x, y: r.y + off, w: r.w, h: piece)
        }
    }

    /// Overlapping slices over `area`. With no anchor, the grid starts at the area's corner (the lab build).
    /// With an anchor, the grid passes through it, and a slice is added at each edge the grid does not reach:
    /// consecutive slices still overlap by at least `size - stride`, so every picture that fits in the overlap
    /// is whole in some slice, as before. It is at most one slice more per axis.
    static func slices(_ area: PixelRect, size: Int, stride: Int, anchor: SliceAnchor? = nil) -> [PixelRect] {
        if area.w <= size && area.h <= size { return [] }
        func starts(_ lo: Int, _ len: Int, _ a: Int?) -> [Int] {
            if len <= size { return [lo] }
            guard let a else {
                var s = Array(Swift.stride(from: lo, through: lo + len - size, by: stride))
                if s.last! != lo + len - size { s.append(lo + len - size) }
                return s
            }
            // The first grid line at or after `lo`.
            let k = lo - a >= 0 ? (lo - a + stride - 1) / stride : -((a - lo) / stride)
            var g = a + k * stride
            var s: [Int] = g > lo ? [lo] : []
            while g + size <= lo + len { s.append(g); g += stride }
            if s.last! + size < lo + len { s.append(lo + len - size) }
            return s
        }
        var out: [PixelRect] = []
        for y in starts(area.y, area.h, anchor?.y) { for x in starts(area.x, area.w, anchor?.x) {
            out.append(PixelRect(x: x, y: y, w: min(size, area.w), h: min(size, area.h)))
        } }
        return out
    }

    /// Judges one captured frame (or a still image) and returns classes only.
    /// `budget` is the caller's share of model judgements for this call; `DetectorConfig.maxJudgementsPerCall`
    /// (`DETECTOR_CALL_CAP`) stays as the backstop. A budget of 0 returns every uncached entry as `overload`, except
    /// entries judged clear earlier on exactly the same pixels, which come back as `judgedEarlier` (or `rejudgeDue`)
    /// where they may be shown.
    ///
    /// `progress`, when given, hears twice before the call returns, in classes only: once after the finder and
    /// the caches (`JudgeProgress.found`), and once per picture the fastest model flags (`fastFlag`). Then the
    /// fastest model runs first over every picture region this call will judge, and the other models after,
    /// in the same order. The same entries are judged within the same budget either way; only the order of
    /// the work changes, and every verdict comes from the full rule.
    public func judge(_ frame: RGBAImage, context ctx: JudgeContext, within area: PixelRect? = nil, budget callerBudget: Int? = nil,
                      progress: ((JudgeProgress) -> Void)? = nil) -> FrameVerdict {
        judge(frame, context: ctx, within: area, budget: callerBudget, progress: progress, secondChecksOnly: false)
    }

    /// Second clean checks in the background (`VerdictCache.CLEAN_CHECKS`): within `budget`, judges once more,
    /// with fresh jitter, only the entries of `area` that are seen clean once, so that when they come back they
    /// are served from the cache. Every other entry is left as it is and not reported. The verdict holds only the
    /// entries judged here: a flag (or a blur) is reported to cover at once; a clean result only adds to the
    /// entry's count, and lifts or clears nothing. `secondChecksLeft` says how many are still waiting.
    public func secondChecks(_ frame: RGBAImage, context ctx: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict {
        judge(frame, context: ctx, within: area, budget: budget, progress: nil, secondChecksOnly: true)
    }

    func judge(_ frame: RGBAImage, context ctx: JudgeContext, within area: PixelRect?, budget callerBudget: Int?,
               progress: ((JudgeProgress) -> Void)?, secondChecksOnly: Bool) -> FrameVerdict {
        let tCall = nowNs()
        let faultsBefore = faultTotal
        timings.calls += 1
        defer { timings.totalMs += msSince(tCall) }
        let A = area?.clamped(width: frame.width, height: frame.height) ?? PixelRect(x: 0, y: 0, w: frame.width, h: frame.height)
        var t0 = nowNs()
        // The finder's proposals are reused only when every pixel it reads is exactly as before.
        let finderKey = FinderCache.key(frame, A)
        timings.cacheMs += msSince(t0)
        t0 = nowNs()
        let found: RegionFinder.Output
        if let hit = finderCache.get(finderKey, for: A) {
            found = hit
            timings.finderCacheHits += 1
        } else {
            found = finder.find(frame, within: A)
            finderCache.put(finderKey, A, found)
        }
        timings.finderMs += msSince(t0)
        t0 = nowNs()
        let gridMembers = Set(found.grids.flatMap(\.members))
        var wasHot = hot.isHot(ctx.windowID, ctx.now)
        let v = models.bundleVersion

        // Build tasks in priority order: region pass (hot first, then small pictures near... all regions),
        // then the whole pass, then slices. Overflow lands on the last tasks, which are also covered by others.
        // With a focus (the pointer, in frame pixels), pictures nearest it come first (SD-120's order of
        // work); otherwise the smallest first, as in the lab build.
        var tasks: [Task] = []
        let regionRects: [PixelRect]
        if let f = ctx.focus {
            func dist(_ r: PixelRect) -> Int {
                let dx = max(0, max(r.x - f.maxX, f.x - r.maxX)), dy = max(0, max(r.y - f.maxY, f.y - r.maxY))
                return dx * dx + dy * dy
            }
            regionRects = found.regions.map(\.rect).sorted { (dist($0), $0.shortSide) < (dist($1), $1.shortSide) }
        } else {
            regionRects = found.regions.map(\.rect).sorted { $0.shortSide < $1.shortSide }
        }
        for r in regionRects {
            tasks.append(Task(rect: r, pieces: Self.pieces(r), pass: .region, gridMember: gridMembers.contains(r),
                              key: VerdictCache.key(frame, r, pass: "region", version: v)))
        }
        // A thin strip (a wide, short changed area) would cost dozens of tiny whole-pass pieces, and slices over it would
        // reach the models stretched many times over. Its whole pass is grown to `thinBelow` on the short side with the
        // pixels around it (within the frame) and judged in pieces of at most 2:1, and it has no slices: every part of it
        // is still judged, never stretched beyond 2:1.
        let thin = A.shortSide < Self.thinBelow && max(A.w, A.h) > 2 * A.shortSide
        let W = thin ? Self.grown(A, to: Self.thinBelow, width: frame.width, height: frame.height) : A
        tasks.append(Task(rect: W, pieces: Self.pieces(W), pass: .whole, gridMember: false, key: VerdictCache.key(frame, W, pass: "whole", version: v)))
        for s in thin ? [] : Self.slices(A, size: config.sliceSize, stride: config.sliceStride, anchor: ctx.sliceAnchor) {
            tasks.append(Task(rect: s, pieces: [s], pass: .slice, gridMember: false, key: VerdictCache.key(frame, s, pass: "slice", version: v)))
        }

        // Where a blur can apply to a picture region in this call: a small picture in a covered-start context
        // or on an untrusted display, or a picture under `hotBelow` in a hot window.
        let smallContain = ctx.startsCovered || ctx.display != .trusted
        func blurCanApply(_ t: Task) -> Bool {
            t.pass == .region && ((smallContain && t.rect.shortSide < config.containBelow) || (wasHot && t.rect.shortSide < config.hotBelow))
        }

        // Cache, then choose what to judge within the budget: in task order, every uncached task whose cost
        // still fits (as the lab build did, judging as it went). A task with the same pixels as one chosen
        // earlier in this call takes that task's outcome, as the cache would have given it. A picture seen
        // clean only once is not in the cache for this (`VerdictCache.CLEAN_CHECKS`): it is judged again, with
        // fresh jitter. Where a blur can apply, a cached clean outcome is used only if it was settled for the
        // blur too (the margin rule, `TileOutcome.settledForBlur`); otherwise the picture is judged again.
        //
        // Entries never judged go first, in task order; entries judged clear earlier on exactly these pixels but not yet
        // reusable from the cache (`seenClear`: too near a cut-off, or clearly clean only once) after them, the longest ago
        // first. Every entry is judged in turn whatever the budget: a budget smaller than the borderline pictures on
        // screen never stops the rest being judged.
        var budget = min(config.maxJudgementsPerCall, max(0, callerBudget ?? config.maxJudgementsPerCall))
        var judgements = 0
        var chosen: [Int] = [], sameAs: [Int: Int] = [:], firstWithKey: [ExactKey: Int] = [:]
        var fresh: [Int] = [], again: [(Int, UInt64)] = []
        var pendingCost = 0
        for i in tasks.indices {
            if secondChecksOnly {
                // Only pictures seen clean once; nothing else is looked up, judged or reported.
                guard cache.seenCleanOnce(tasks[i].key) else { continue }
            } else if let o = cache.get(tasks[i].key), o.settledForBlur || !blurCanApply(tasks[i]) {
                tasks[i].outcome = o; tasks[i].judged = true; tasks[i].fromCache = true; timings.cacheHits += 1; continue
            }
            timings.cacheMisses += 1
            if let j = firstWithKey[tasks[i].key] { sameAs[i] = j; continue }
            firstWithKey[tasks[i].key] = i
            if let seen = seenClear.get(tasks[i].key) { again.append((i, seen.serial)) } else { fresh.append(i) }
        }
        // The whole pass, never judged, comes right after the first picture (the one nearest the pointer, or the smallest):
        // it costs little, and left unjudged it covers the whole call area plainly, where an unjudged picture is only
        // blurred where it is.
        if let w = fresh.firstIndex(where: { tasks[$0].pass == .whole }), w > 1 {
            let whole = fresh.remove(at: w)
            fresh.insert(whole, at: 1)
        }
        var nextCost = 0
        for i in fresh + again.sorted(by: { $0.1 < $1.1 }).map(\.0) {
            let cost = tasks[i].pieces.count * (models.models.count + (tasks[i].rect.shortSide < config.containBelow ? models.students.count : 0))
            if cost > budget { if nextCost == 0 { nextCost = cost }; continue }
            budget -= cost
            judgements += cost
            pendingCost += cost
            if cache.seenCleanOnce(tasks[i].key) { timings.secondCheckJudgements += cost }
            chosen.append(i)
        }
        chosen.sort()
        // What an entry the budget did not reach shows: as judged earlier on these pixels, where that may be shown (a
        // show-first window, no blur rule, not video); otherwise unjudged (`overload`).
        func earlier(_ t: Task) -> SeenClear.Entry? {
            guard !ctx.startsCovered, !ctx.isVideo, !blurCanApply(t) else { return nil }
            return seenClear.get(t.key)
        }
        timings.cacheMs += msSince(t0)

        if let progress {
            let coveredByCache = tasks.filter { t in t.pass == .region && t.outcome.map { covers($0) } ?? false }
            // Pictures judged clear earlier on exactly these pixels are not new: they are not blurred first.
            progress(.found(pending: tasks.filter { $0.pass == .region && !$0.judged && earlier($0) == nil }.map(\.rect),
                            coveredByCache: coveredByCache.map(\.rect), estimatedMs: Double(pendingCost) * msPerJudgement))
        }

        // The fastest model first, over every chosen picture region; a flag is shown at once (provisional).
        var fast: [Int: [String: Float]] = [:]
        // Tasks the fastest model failed on: left unjudged in this call (a fault), never judged clear.
        var fastFailed: Set<Int> = []
        if progress != nil, let fm = fastestModel {
            for i in chosen where tasks[i].pass == .region {
                guard let top = topScore(frame, tasks[i], fm) else { fastFailed.insert(i); continue }
                fast[i] = [fm.id: top]
                var flagged = top >= table.cutoffs(model: fm.id, band: Band(shortSide: tasks[i].rect.shortSide)).cover
                #if KESTREL_LAB
                // The lab stand-in stands in for the fast model's flag (it is checked after the model ran).
                if let s = standIn, tasks[i].pieces.contains(where: { s.detects(frame, $0) }) { flagged = true }
                #endif
                if flagged {
                    progress?(.fastFlag(RegionVerdict(rect: tasks[i].rect, display: config.rule == .either || models.singleFamily ? .cover : .contain,
                                                      reason: .provisional, pass: .region)))
                }
            }
        }

        // Then every model the full rule needs (the fast model's score is not judged twice). A task a model
        // failed on stays unjudged: it is covered or blurred as overload and judged again in a later call.
        // Every task a model failed on in this call, the fastest model's failures included. A failure is never shown as
        // judged earlier: it is unjudged, covered or blurred and counted, and what was seen of it before is forgotten.
        var failed = fastFailed
        for i in chosen where !fastFailed.contains(i) {
            guard let o = judgeTask(frame, tasks[i], precomputed: fast[i] ?? [:]) else { failed.insert(i); continue }
            tasks[i].outcome = o; tasks[i].judged = true
            // A cover is kept; a clearly clean judgement adds to the entry's clean count (two in a row make it
            // reusable); anything else starts the count again (the margin rule and `CLEAN_CHECKS`).
            cache.put(tasks[i].key, o)
            // Judged clear but not reusable from the cache yet (too near a cut-off, or clearly clean only once): these exact
            // pixels may be shown as judged earlier when a later call's budget does not reach them (`Reason.judgedEarlier`,
            // a display rule with its own limits, never a cached verdict). A cover, or a verdict now reusable, ends that.
            if !covers(o) && !o.forced && !cache.isReusable(tasks[i].key) { seenClear.put(tasks[i].key, at: ctx.now) } else { seenClear.remove(tasks[i].key) }
        }
        // A model failure forgets both what was seen clear and any clean count: the next clean judgement starts again.
        for i in failed { seenClear.remove(tasks[i].key); cache.forget(tasks[i].key) }
        for (i, j) in sameAs where tasks[j].judged { tasks[i].outcome = tasks[j].outcome; tasks[i].judged = true }

        // A window turns hot only after a both-family hit (SD-125, C06-3 d). The lab's grid trigger
        // (several low-level tiles) and the tie-breaker-confirmed trigger are removed.
        let tDecide = nowNs()
        defer { timings.decisionMs += msSince(tDecide) }
        // Decided over every outcome before any is classified, so a small picture judged before the hit in this call
        // is held to the hot rule too.
        let becameHot = tasks.contains { t in
            guard t.judged, let o = t.outcome, !o.forced else { return false }
            return confirmed(o) && o.flagA && o.flagB && t.rect.shortSide >= config.coverMinSide
        }

        var out: [RegionVerdict] = []
        var coverWindow = false, strike = false, overloaded = 0
        // Background second checks report only the entries asked about; one a model failed on is reported unjudged.
        let asked = Set(chosen)
        for (k, t) in tasks.enumerated() {
            guard t.judged, let o = t.outcome else {
                let r = sameAs[k] ?? k, rep = tasks[r]
                if secondChecksOnly && !asked.contains(r) { continue }
                // Shown as judged earlier only if no model failed on it in this call, and not a small picture in a window
                // that turned hot in this call (judged earlier under the rule for a window that was not hot).
                let hotNow = becameHot && rep.pass == .region && rep.rect.shortSide < config.hotBelow
                if !failed.contains(r), !hotNow, let e = earlier(rep) {
                    let due = ctx.now.timeIntervalSince(e.at) >= config.rejudgeAfter
                    out.append(RegionVerdict(rect: t.rect, display: .clear, reason: due ? .rejudgeDue : .judgedEarlier, pass: t.pass))
                    timings.judgedEarlier += 1
                    continue
                }
                overloaded += 1
                // Never show a picture unjudged: cover in covered-start contexts and for the whole/slice
                // passes; blur regions in show-first windows (the judged copy takes over there).
                let d: DisplayClass = (ctx.startsCovered || t.pass != .region) ? .cover : .contain
                out.append(RegionVerdict(rect: t.rect, display: d, reason: .overload, pass: t.pass))
                continue
            }
            let band = Band(shortSide: t.rect.shortSide)
            var display = DisplayClass.clear
            var reason = Reason.judgedClean
            // Agreement policy: cover when both families agree, or when the referee confirms a dispute.
            // A dispute nobody could settle is covered too (SD-125, C06-3 c), but makes nothing hot.
            #if KESTREL_LAB
            if o.forced { display = .cover; reason = .labForced }
            #endif
            let covers = confirmed(o)
            if display == .clear && covers {
                // A flagged picture under 32 detail pixels is covered too (SD-125), but makes nothing hot.
                display = .cover
                reason = models.singleFamily && !o.forced ? .oneFamily : o.flagA && o.flagB ? .bothFamilies : .referee
                if t.pass == .whole { coverWindow = true }
            } else if display == .clear && config.rule == .balanced && o.disputed && !o.refereeRan {
                display = .cover
                reason = .disputed
                if t.pass == .whole { coverWindow = true }
            }
            if ctx.isVideo {
                let (hold, vstrike) = voter.vote(VideoVoter.key(ctx.windowID, t.rect), o, confirmed: covers)
                if hold && display == .clear { display = .cover; reason = .videoHold }
                if vstrike && t.rect.shortSide >= config.strikeMinSide && !o.forced { strike = true }
            } else if o.strikeBoth && t.rect.shortSide >= config.strikeMinSide && !o.forced {
                strike = true
            }
            // A cached clean outcome not settled for a blur counts as not clean wherever a blur applies. It can
            // reach here only when the window turned hot in this call; it is blurred until judged again.
            let clean = o.clean && (o.settledForBlur || !t.fromCache)
            if display == .clear && t.pass == .region && !clean {
                if t.rect.shortSide < config.containBelow && smallContain { display = .contain; reason = .containedSmall }
                else if (wasHot || becameHot) && t.rect.shortSide < config.hotBelow { display = .contain; reason = .hotContext }
            }
            _ = band
            out.append(RegionVerdict(rect: t.rect, display: display, reason: reason, pass: t.pass))
        }
        if becameHot { hot.mark(ctx.windowID, ctx.now); wasHot = true }
        // A hot window with very many picture tiles blurs its whole picture area.
        if wasHot && regionRects.count > config.blurAllAbove {
            for i in out.indices where out[i].display == .clear && tasks.first(where: { $0.rect == out[i].rect })?.pass == .region {
                out[i].display = .contain; out[i].reason = .hotContext
            }
        }
        timings.judgements += judgements
        timings.overloaded += overloaded
        // Pictures of this call still seen clean once, waiting for their second check (counted once per key).
        var waiting = Set<ExactKey>()
        for t in tasks where cache.seenCleanOnce(t.key) { waiting.insert(t.key) }
        return FrameVerdict(regions: out, coverWindow: coverWindow, strike: strike, hot: wasHot, judgements: judgements, overloaded: overloaded,
                            modelFaults: faultTotal - faultsBefore, nextCost: nextCost, secondChecksLeft: waiting.count)
    }

    #if KESTREL_LAB
    /// LAB ONLY (absent from release builds): every piece the pipeline would judge on this frame, with each
    /// model's flag score, for tuning cut-offs on the real tile distribution. `withReferee` scores the
    /// referee too. No jitter, so runs are repeatable.
    public struct LabTile: Sendable { public var pass: String; public var rect: PixelRect; public var piece: PixelRect; public var gridMember: Bool; public var scores: [String: Float] }
    public func labTileScores(_ frame: RGBAImage, withReferee: Bool) -> [LabTile] {
        let A = PixelRect(x: 0, y: 0, w: frame.width, h: frame.height)
        let found = finder.find(frame, within: A)
        let gm = Set(found.grids.flatMap(\.members))
        var tasks: [(String, PixelRect, Bool)] = found.regions.map { ("region", $0.rect, gm.contains($0.rect)) }
        tasks.append(("whole", A, false))
        tasks += Self.slices(A, size: config.sliceSize, stride: config.sliceStride).map { ("slice", $0, false) }
        var out: [LabTile] = []
        for (pass, r, g) in tasks {
            for piece in Self.pieces(r) {
                var sc: [String: Float] = [:]
                for m in models.models {
                    if let t = try? Preprocessor.run(frame, rect: piece, side: m.side, jitterSeed: nil), let s = try? m.flagScores([t]) { sc[m.id] = s[0] }
                }
                // The slow referee is scored only where a family reaches a loose pre-filter (Marqo >= 0.3 or
                // NSFWJS >= 0.6); tuned cut-offs are kept at or above these, so no dispute is missed.
                if withReferee, let ref = models.referee, (sc["marqo-vit-tiny-384"] ?? 0) >= 0.3 || sc.contains { $0.key != "marqo-vit-tiny-384" && $0.value >= 0.6 },
                   let t = try? Preprocessor.run(frame, rect: piece, side: ref.side, jitterSeed: nil), let s = try? ref.flagScores([t]) {
                    sc[ref.id] = s[0]
                }
                out.append(LabTile(pass: pass, rect: r, piece: piece, gridMember: g, scores: sc))
            }
        }
        return out
    }
    #endif

    /// Lifetime cost per model (preprocessing and inference), to pick the fastest and to estimate.
    var modelCost: [String: (ms: Double, tiles: Int)] = [:]

    /// About how long one judgement takes (all models alike), from what judging has cost so far.
    var msPerJudgement: Double {
        let ms = modelCost.values.reduce(0) { $0 + $1.ms }, n = modelCost.values.reduce(0) { $0 + $1.tiles }
        return n > 0 ? ms / Double(n) : 10
    }

    /// The model of the pair that has cost least per tile so far (before any measure, the one with the
    /// smallest input).
    var fastestModel: ScoringModel? {
        models.models.min { a, b in
            let ca = modelCost[a.id].map { $0.ms / Double(max(1, $0.tiles)) } ?? Double(a.side), cb = modelCost[b.id].map { $0.ms / Double(max(1, $0.tiles)) } ?? Double(b.side)
            return ca < cb
        }
    }

    /// How far above 1 a flag score may be and still be usable: rounding, when two half-precision class
    /// probabilities are summed (NSFWJS sums two classes).
    static let scoreSlack: Float = 0.001

    /// Whether a model's flag score can be used. It is a sum of class probabilities, so a working model gives a
    /// number from 0 to 1. Not a number, infinite, negative or above 1 (beyond `scoreSlack`) means the model
    /// failed for that entry. A failure is never read as "not flagged".
    static func usable(_ s: Float) -> Bool { s.isFinite && s >= 0 && s <= 1 + scoreSlack }

    /// One model's scores for `tensors`, or nil when the model failed: it threw, gave not one score per
    /// tensor, or gave any unusable score (one is enough: the highest of the rest could look clean). Every
    /// failure is counted in `modelFaults`.
    func usableScores(_ m: ScoringModel, _ tensors: [[UInt8]]) -> [Float]? {
        guard let s = try? m.flagScores(tensors), s.count == tensors.count, !s.isEmpty, s.allSatisfy(Self.usable) else {
            modelFaults[m.id, default: 0] += 1
            timings.modelFaults[m.id, default: 0] += 1
            faultTotal += 1
            return nil
        }
        return s
    }

    /// One model's highest score over a task's pieces, each with fresh jitter; nil when the model failed
    /// (`usableScores`). The score stays here.
    func topScore(_ frame: RGBAImage, _ t: Task, _ m: ScoringModel) -> Float? {
        var tensors: [[UInt8]] = []
        var t0 = nowNs()
        for p in t.pieces {
            guard let tensor = try? Preprocessor.run(frame, rect: p, side: m.side, jitterSeed: UInt32.random(in: 1...UInt32.max, using: &rng)) else { return nil }
            tensors.append(tensor)
        }
        let pre = msSince(t0)
        timings.preprocessMs[m.id, default: 0] += pre
        t0 = nowNs()
        let scores = usableScores(m, tensors)
        let inf = msSince(t0)
        timings.inferenceMs[m.id, default: 0] += inf
        timings.tiles[m.id, default: 0] += tensors.count
        let c = modelCost[m.id] ?? (0, 0)
        modelCost[m.id] = (c.ms + pre + inf, c.tiles + tensors.count)
        return scores?.max()
    }

    /// Judges every piece of a task with every model (jitter before every judgement) and folds the
    /// scores into outcome flags. Scores do not outlive this function. `precomputed` holds scores already
    /// made for this task in this call (the fastest model's), so no model judges the same task twice.
    /// The outcome is marked cacheable here, where the scores are, and only a flag leaves (the margin rule,
    /// `VerdictCache.cleanLevel`).
    func judgeTask(_ frame: RGBAImage, _ t: Task, precomputed: [String: Float] = [:]) -> TileOutcome? {
        let band = Band(shortSide: t.rect.shortSide)
        var o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false)
        #if KESTREL_LAB
        if let s = standIn, t.pieces.contains(where: { s.detects(frame, $0) }) { o.forced = true }
        #endif
        var strikeA = false, strikeB = false
        // Clearly clean: every model's top score below half its cover cut-off for this band. Settled for a blur
        // too: below half its lowest action cut-off. A picture region this small can be blurred (in a hot window
        // or a covered-start context) when a score passes the containment cut-off, so that cut-off acts on it.
        var clearlyClean = true, settledForBlur = true
        let containable = t.pass == .region && t.rect.shortSide < max(config.containBelow, config.hotBelow)
        let small = t.rect.shortSide < config.containBelow
        let judges = models.models + (small ? models.students : [])
        for m in judges {
            let cut = table.cutoffs(model: m.id, band: band)
            guard let top = precomputed[m.id] ?? topScore(frame, t, m) else { return nil }
            if !(top < VerdictCache.cleanLevel(cut, containable: false)) { clearlyClean = false }
            if !(top < VerdictCache.cleanLevel(cut, containable: containable)) { settledForBlur = false }
            let flag = top >= cut.cover
            if top > cut.clean { o.clean = false }
            if top >= cut.gridMember { o.gridMember = true }
            if top >= cut.gridLow { o.gridLow = true }
            switch m.family {
            case .a: o.flagA = o.flagA || flag; strikeA = strikeA || top >= cut.strike
            case .b: o.flagB = o.flagB || flag; strikeB = strikeB || top >= cut.strike
            case .student: o.flagB = o.flagB || flag  // a student can add a cover; it never makes a strike
            }
        }
        if models.singleFamily {
            // Single-family mode: the one family stands for both. Its flag alone covers under every rule (as Either
            // does), makes a window hot as both families' agreement would, and there is never a dispute, so fewer
            // models never means less covering.
            let flag = o.flagA || o.flagB, hard = strikeA || strikeB
            o.flagA = flag; o.flagB = flag; strikeA = hard; strikeB = hard
        }
        o.strikeBoth = strikeA && strikeB
        o.disputed = o.flagA != o.flagB
        if o.disputed, config.rule == .balanced, let r = models.referee {
            let cut = table.cutoffs(model: r.id, band: band)
            var tensors: [[UInt8]] = []
            var t0 = nowNs()
            for p in t.pieces {
                guard let tensor = try? Preprocessor.run(frame, rect: p, side: r.side, jitterSeed: UInt32.random(in: 1...UInt32.max, using: &rng)) else { return nil }
                tensors.append(tensor)
            }
            timings.preprocessMs[r.id, default: 0] += msSince(t0)
            t0 = nowNs()
            // A tie-breaker that failed (`usableScores`) has not answered: the dispute stays unanswered and covers.
            let refScores = usableScores(r, tensors)
            timings.inferenceMs[r.id, default: 0] += msSince(t0)
            timings.tiles[r.id, default: 0] += tensors.count
            if let top = refScores?.max() {
                o.refereeRan = true
                o.refereeFlag = top >= cut.cover
                refereeCalls += t.pieces.count
            }
        }
        // Cache a cover (reusing it only ever covers) or count a clearly clean outcome towards the two clean
        // checks a clean verdict needs (`VerdictCache.CLEAN_CHECKS`). A borderline-clean one, a dispute the
        // tie-breaker declined among them, is judged again with fresh jitter when it comes back; one not settled
        // for a blur is judged again wherever a blur can apply.
        let c = covers(o)
        o.covering = c
        o.cacheable = c || clearlyClean
        o.settledForBlur = c || (clearlyClean && settledForBlur)
        return o
    }
}
