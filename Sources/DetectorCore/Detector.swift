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
    let voter = VideoVoter()
    let hot = HotContexts()
    /// Referee judgements made so far (for budgets and benchmarks).
    public private(set) var refereeCalls = 0
    var rng = SystemRandomNumberGenerator()
    #if KESTREL_LAB
    public var standIn: StandInDetector?
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

    /// Changes the detector rule. The verdict cache is emptied, because a cached outcome was made under
    /// the other rule (the tie-breaker is asked only under Balanced).
    public func setRule(_ rule: DetectorRule) {
        guard rule != config.rule else { return }
        config.rule = rule
        cache.removeAll()
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

    struct Task {
        var rect: PixelRect      // what the verdict applies to
        var pieces: [PixelRect]  // aspect-limited pieces actually judged
        var pass: Pass
        var gridMember: Bool
        var key: Data
        var outcome: TileOutcome?
        var judged = false
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

    static func slices(_ area: PixelRect, size: Int, stride: Int) -> [PixelRect] {
        if area.w <= size && area.h <= size { return [] }
        func starts(_ len: Int) -> [Int] {
            if len <= size { return [0] }
            var s = Array(Swift.stride(from: 0, through: len - size, by: stride))
            if s.last! != len - size { s.append(len - size) }
            return s
        }
        var out: [PixelRect] = []
        for y in starts(area.h) { for x in starts(area.w) {
            out.append(PixelRect(x: area.x + x, y: area.y + y, w: min(size, area.w), h: min(size, area.h)))
        } }
        return out
    }

    /// Judges one captured frame (or a still image) and returns classes only.
    /// `budget` is the caller's share of model judgements for this call; `DetectorConfig.maxJudgementsPerCall`
    /// (`DETECTOR_CALL_CAP`) stays as the backstop. A budget of 0 returns every uncached entry as `overload`.
    public func judge(_ frame: RGBAImage, context ctx: JudgeContext, within area: PixelRect? = nil, budget callerBudget: Int? = nil) -> FrameVerdict {
        let A = area?.clamped(width: frame.width, height: frame.height) ?? PixelRect(x: 0, y: 0, w: frame.width, h: frame.height)
        let found = finder.find(frame, within: A)
        let gridMembers = Set(found.grids.flatMap(\.members))
        var wasHot = hot.isHot(ctx.windowID, ctx.now)
        let v = models.bundleVersion

        // Build tasks in priority order: region pass (hot first, then small pictures near... all regions),
        // then the whole pass, then slices. Overflow lands on the last tasks, which are also covered by others.
        var tasks: [Task] = []
        let regionRects = found.regions.map(\.rect).sorted { $0.shortSide < $1.shortSide }
        for r in regionRects {
            tasks.append(Task(rect: r, pieces: Self.pieces(r), pass: .region, gridMember: gridMembers.contains(r),
                              key: VerdictCache.key(frame, r, pass: "region", version: v)))
        }
        tasks.append(Task(rect: A, pieces: Self.pieces(A), pass: .whole, gridMember: false, key: VerdictCache.key(frame, A, pass: "whole", version: v)))
        for s in Self.slices(A, size: config.sliceSize, stride: config.sliceStride) {
            tasks.append(Task(rect: s, pieces: [s], pass: .slice, gridMember: false, key: VerdictCache.key(frame, s, pass: "slice", version: v)))
        }

        // Cache, then judge within the budget.
        var budget = min(config.maxJudgementsPerCall, max(0, callerBudget ?? config.maxJudgementsPerCall))
        var judgements = 0
        for i in tasks.indices {
            if let o = cache.get(tasks[i].key) { tasks[i].outcome = o; tasks[i].judged = true; continue }
            let cost = tasks[i].pieces.count * (models.models.count + (tasks[i].rect.shortSide < config.containBelow ? models.students.count : 0))
            if cost > budget { continue }
            budget -= cost
            judgements += cost
            if let o = judgeTask(frame, tasks[i]) {
                tasks[i].outcome = o; tasks[i].judged = true
                cache.put(tasks[i].key, o)
            }
        }

        // A window turns hot only after a both-family hit (SD-125, C06-3 d). The lab's grid trigger
        // (several low-level tiles) and the tie-breaker-confirmed trigger are removed.
        var becameHot = false

        var out: [RegionVerdict] = []
        var coverWindow = false, strike = false, overloaded = 0
        let smallContain = ctx.startsCovered || ctx.display != .trusted
        for t in tasks {
            guard t.judged, let o = t.outcome else {
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
                reason = o.flagA && o.flagB ? .bothFamilies : .referee
                if o.flagA && o.flagB && t.rect.shortSide >= config.coverMinSide { becameHot = true }
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
            if display == .clear && t.pass == .region && !o.clean {
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
        return FrameVerdict(regions: out, coverWindow: coverWindow, strike: strike, hot: wasHot, judgements: judgements, overloaded: overloaded)
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

    /// Judges every piece of a task with every model (jitter before every judgement) and folds the
    /// scores into outcome flags. Scores do not outlive this function.
    func judgeTask(_ frame: RGBAImage, _ t: Task) -> TileOutcome? {
        let band = Band(shortSide: t.rect.shortSide)
        var o = TileOutcome(flagA: false, flagB: false, strikeBoth: false, clean: true, gridMember: false, gridLow: false, forced: false)
        #if KESTREL_LAB
        if let s = standIn, t.pieces.contains(where: { s.detects(frame, $0) }) { o.forced = true }
        #endif
        var strikeA = false, strikeB = false
        let small = t.rect.shortSide < config.containBelow
        let judges = models.models + (small ? models.students : [])
        for m in judges {
            let cut = table.cutoffs(model: m.id, band: band)
            var tensors: [[UInt8]] = []
            for p in t.pieces {
                guard let tensor = try? Preprocessor.run(frame, rect: p, side: m.side, jitterSeed: UInt32.random(in: 1...UInt32.max, using: &rng)) else { return nil }
                tensors.append(tensor)
            }
            guard let scores = try? m.flagScores(tensors) else { return nil }
            let top = scores.max() ?? 0
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
        o.strikeBoth = strikeA && strikeB
        o.disputed = o.flagA != o.flagB
        if o.disputed, config.rule == .balanced, let r = models.referee {
            let cut = table.cutoffs(model: r.id, band: band)
            var tensors: [[UInt8]] = []
            for p in t.pieces {
                guard let tensor = try? Preprocessor.run(frame, rect: p, side: r.side, jitterSeed: UInt32.random(in: 1...UInt32.max, using: &rng)) else { return nil }
                tensors.append(tensor)
            }
            if let scores = try? r.flagScores(tensors) {
                o.refereeRan = true
                o.refereeFlag = (scores.max() ?? 0) >= cut.cover
                refereeCalls += t.pieces.count
            }
        }
        return o
    }
}
