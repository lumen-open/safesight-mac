// SPDX-License-Identifier: Apache-2.0
// The cover layer for one display, show-first (chapter 05, sections 5.2, 5.5, 5.6, 5.11, 5.12).
//
// Every window is shown live and judged just after, on what changed. A flagged picture is covered as
// soon as its verdict arrives; a contained one is blurred. A picture can be seen for a moment first
// (SL-020). A covered region lifts only after `VIDEO_VOTE` clean judgements in a row of that region
// (SD-230). Slowness covers more, never shows more: unjudged regions are blurred or covered, a window
// left unjudged for longer than `TIME_TO_COVER` is covered whole, and a display that cannot be judged
// is covered whole.
//
// Nothing here stores a verdict, counts covers or sends anything. Frames stay in memory.
import CoreGraphics
import DetectorCore
import Foundation
import Preprocess

public final class DisplayPipeline {
    public private(set) var display: DisplayDescriptor
    let judger: Judging
    public var ignoredPIDs: Set<Int32>
    var bucket: TokenBucket

    /// A covered or blurred region waiting for its clean judgements. `rel` is relative to the target's
    /// origin (window or display), so a cover moves with its window.
    struct Held: Equatable {
        var target: JudgeTarget
        var rel: CGRect
        var whole: Bool
        var kind: CoverKind
        var clean: Int
    }
    var held: [Held] = []
    var pending: [CGRect] = []
    var lastImage: RGBAImage?
    var lastMap: CaptureMap?
    var lastFullPass: TimeInterval?
    var lastBounds: [JudgeTarget: CGRect] = [:]
    var overloadSince: [JudgeTarget: TimeInterval] = [:]
    var hot: Set<JudgeTarget> = []
    /// How far each target's content has scrolled, in frame pixels: the slice grid moves with it.
    var contentOffset: [JudgeTarget: Translation] = [:]
    /// The last complete frame's row hashes per target, for finding motion (valid for the next frame only).
    var rowCache: [JudgeTarget: (serial: Int, area: PixelRect, rows: [UInt64?])] = [:]
    var frameSerial = 0
    var lastFrameTime: TimeInterval?
    /// Cover first when judging a window's new pictures would end later than this after the frame arrived
    /// (`COVER_GOAL`; tests that run unoptimised builds raise it).
    public var coverGoalMs = Register.COVER_GOAL * 1000
    /// How long a judging run takes (the recent longest, fading by a fifth a run): how far ahead a moving
    /// cover must reach.
    var runEstimateMs = 0.0
    /// True once a frame of this display has been judged and drawn since it was last covered whole.
    public private(set) var judged = false
    /// Frames from streams older than this generation are never judged here: the display has changed since they
    /// were captured (raised by `cover(because:until:)`).
    public private(set) var requiredGeneration = 0
    /// The stream generation of the last frame judged. The first frame of another stream is judged whole: its changed
    /// areas say nothing about what this display showed before.
    var judgedGeneration: Int?
    public private(set) var lastPlan: CoverPlan
    /// Stage timings of the last `process` call (durations and counts only; nothing is written anywhere).
    public private(set) var lastTimings = PipelineTimings()

    public init(display: DisplayDescriptor, judger: Judging, budgetShare: Double, ignoredPIDs: Set<Int32>) {
        self.display = display; self.judger = judger; self.ignoredPIDs = ignoredPIDs
        self.bucket = TokenBucket(rate: budgetShare)
        // A display starts covered whole until its first judged frame.
        self.lastPlan = .covered(display, because: .notYetJudged)
    }

    public func setBudgetShare(_ rate: Double) { bucket.rate = rate }

    /// Covers the whole display: it cannot be judged. It stays covered until a frame is judged again; with `until`,
    /// until a frame from a stream of at least that generation is judged (a display change).
    @discardableResult
    public func cover(because cause: FaultCause, until generation: Int? = nil) -> CoverPlan {
        if let g = generation { requiredGeneration = max(requiredGeneration, g) }
        judged = false
        lastPlan = .covered(display, because: cause)
        return lastPlan
    }

    /// Drops every cover and all memory of the screen (used when the owner pauses, in practice state only).
    public func reset() {
        held = []; pending = []; lastImage = nil; lastMap = nil; lastFullPass = nil
        lastBounds = [:]; overloadSince = [:]; hot = []; contentOffset = [:]; rowCache = [:]; lastFrameTime = nil
        judgedGeneration = nil
        cover(because: .notYetJudged)
    }

    /// Handles one frame and returns everything to draw on this display.
    ///
    /// `provisional`, when given, receives plans to draw at once, before judging ends: covers moved with
    /// content that scrolled; new pictures blurred first when judging them would take longer than
    /// `COVER_GOAL`; and a blur (a cover under Either) on any picture the fastest model flags, before the full
    /// rule decides. Every provisional plan holds every cover the last plan held (moved where its picture
    /// moved), plus every cover already decided in this frame, so drawing one never shows anything the last
    /// plan covered. The returned plan is the final one for this frame and replaces them: only the full rule
    /// lifts anything, and only by `VIDEO_VOTE`.
    ///
    /// `pointer` (global points), when known, puts the window under it, and the pictures nearest it, first.
    public func process(_ f: CapturedFrame, snapshot: WindowSnapshot, now: TimeInterval, date: Date = Date(),
                        pointer: CGPoint? = nil, provisional: ((CoverPlan) -> Void)? = nil) -> CoverPlan {
        // A frame captured before the last display change is never judged: the display stays as it was (covered).
        guard f.generation >= requiredGeneration else { return lastPlan }
        display = f.display
        switch f.status {
        case .blank, .suspended, .stopped:
            return cover(because: .frameNotJudgeable)
        case .started:
            return judged ? lastPlan : cover(because: .notYetJudged)
        case .idle:
            // Nothing changed. Keep judging regions waiting to lift, on the last frame's pixels (of this stream only).
            guard judged, judgedGeneration == f.generation, let img = lastImage, let map = lastMap, !(held.isEmpty && pending.isEmpty) else { return lastPlan }
            return run(img, previous: nil, frameInterval: 0, map: map, dirty: [], snapshot: snapshot, now: now, date: date, pointer: pointer, provisional: provisional)
        case .complete:
            guard let img = f.image, let map = f.map, map.pixelWidth == img.width, map.pixelHeight == img.height, map.coversDisplay else {
                return cover(because: .badFrameMetadata)
            }
            // The first frame of another stream is judged whole, with no motion carried over from the old stream.
            let sameStream = judgedGeneration == f.generation
            let previous = sameStream && lastMap.map { $0 == map } == true ? lastImage : nil
            let dt = lastFrameTime.map { f.time - $0 } ?? 0
            lastImage = img; lastMap = map; lastFrameTime = f.time
            judgedGeneration = f.generation
            frameSerial += 1
            return run(img, previous: previous, frameInterval: dt, map: map, dirty: sameStream ? f.dirty : nil, snapshot: snapshot, now: now, date: date, pointer: pointer, provisional: provisional)
        }
    }

    func origin(of t: JudgeTarget, _ snapshot: WindowSnapshot) -> CGPoint {
        snapshot.bounds(of: t)?.origin ?? display.bounds.origin
    }

    func run(_ img: RGBAImage, previous: RGBAImage?, frameInterval: TimeInterval, map: CaptureMap, dirty: [PixelRect]?, snapshot: WindowSnapshot,
             now: TimeInterval, date: Date, pointer: CGPoint? = nil, provisional: ((CoverPlan) -> Void)?) -> CoverPlan {
        var timing = PipelineTimings()
        let tRun = PipelineTimings.now()
        defer {
            timing.totalMs = PipelineTimings.ms(since: tRun); lastTimings = timing
            runEstimateMs = max(timing.totalMs, 0.8 * runEstimateMs)
        }
        var tStage = tRun
        let d = display.bounds
        let visible = visibleByTarget(snapshot)
        // Windows that moved or changed size since the last snapshot.
        var moved: [(JudgeTarget, CGRect, CGRect)] = []
        for (t, old) in lastBounds { if let nb = snapshot.bounds(of: t), nb != old { moved.append((t, old, nb)) } }

        // 1. What to judge: the changed areas; regions waiting to lift; overflow from earlier calls;
        //    old and new places of moved windows; and a full pass on the `FULL_REJUDGE` rhythm.
        var areas: [CGRect]
        let fullDue = lastFullPass.map { now - $0 >= Register.FULL_REJUDGE_SHOW_FIRST } ?? true
        if dirty == nil || fullDue || !judged {
            areas = [d]
            lastFullPass = now
        } else {
            areas = DirtyRegions.prepare(dirty!, width: img.width, height: img.height).map(map.toGlobal)
            areas += pending
            for h in held { if let g = globalRect(h, snapshot, visible) { areas.append(g) } }
            for (_, old, new) in moved { areas += [old.intersection(d), new.intersection(d)].filter(\.hasArea) }
        }
        pending = []

        // 2. Split by window: one judge call per window (C05-6). Hot windows first; then the window under the
        //    pointer and the ones nearest it; otherwise front to back (SD-120's order of work).
        var parts = snapshot.split(changed: areas, display: display, ignoring: ignoredPIDs)
        func pointerDistance(_ p: TargetArea) -> CGFloat {
            guard let q = pointer else { return 0 }
            return p.visible.map { r in hypot(max(0, max(r.minX - q.x, q.x - r.maxX)), max(0, max(r.minY - q.y, q.y - r.maxY))) }.min() ?? .infinity
        }
        let order = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($0.element.target, $0.offset) })
        parts.sort { a, b in
            let ha = hot.contains(a.target), hb = hot.contains(b.target)
            if ha != hb { return ha }
            let da = pointerDistance(a), db = pointerDistance(b)
            if da != db { return da < db }
            return order[a.target]! < order[b.target]!
        }
        timing.changeMs = PipelineTimings.ms(since: tStage)

        // 2b. Content that moved by a translation (scrolling): its covers move with it now, in this update,
        //     before the moved area is judged again. Each moved cover is also drawn reaching ahead along the
        //     motion, for this update, as far as the content will go before the next plan.
        var lead: [Held] = []
        if judged, let prev = previous, dirty != nil {
            tStage = PipelineTimings.now()
            lead = followMotion(prev, img, parts: parts, map: map, snapshot: snapshot, frameInterval: frameInterval)
            timing.translateMs = PipelineTimings.ms(since: tStage)
            if !lead.isEmpty, let provisional {
                provisional(CoverPlan(display: display, items: drawItems(snapshot, visible, map, moved: moved, lead: lead)))
                timing.provisionalMs.append(PipelineTimings.ms(since: tRun))
            }
        }

        // 3. Judge and turn classes into covers.
        var fresh: [Held] = []
        // Covers and blurs handed out early in this frame (cover first, fast flags): drawn in provisional plans
        // only. The final plan comes from the full rule alone.
        var early: [CoverItem] = []
        func publishEarly() {
            guard let provisional, judged else { return }
            provisional(CoverPlan(display: display, items: drawItems(snapshot, visible, map, moved: moved, lead: lead + fresh) + early))
            timing.provisionalMs.append(PipelineTimings.ms(since: tRun))
        }
        for p in parts {
            guard let changedBox = p.changed.boundingBox, let visBox = p.visible.boundingBox,
                  let area = map.toPixels(changedBox.intersection(visBox)) else { continue }
            bucket.refill(now: now)
            // The first judgement after the display was covered whole is not limited by the budget (SD-120).
            let budget = judged ? min(bucket.available, Register.DETECTOR_CALL_CAP) : Register.DETECTOR_CALL_CAP
            let focus = pointer.flatMap { q in map.toPixels(CGRect(x: q.x - 1, y: q.y - 1, width: 2, height: 2)) }
            let ctx = JudgeContext(windowID: p.target.contextID, startsCovered: false, display: .trusted, isVideo: false, now: date,
                                   sliceAnchor: sliceAnchor(p.target, snapshot, map), focus: focus)
            let vis = p.visible
            func item(_ r: PixelRect, _ kind: CoverKind) -> [CoverItem] {
                vis.clipped(to: map.toGlobal(r)).map { CoverItem(rect: CoordinateSpace.snapOutward($0, pointsPerPixel: map.pointsPerPixel), kind: kind) }
            }
            func blur(_ r: PixelRect) -> CoverKind { ContainBlur.make(img, r).map { .blur($0) } ?? .plain }
            let progress: ((JudgeProgress) -> Void)? = provisional == nil || !judged ? nil : { event in
                switch event {
                case let .found(pending, coveredByCache, estimatedMs):
                    // A cached cover is shown at once if it is not on screen already (a flagged picture seen
                    // before, back in view). Cover first: if judging the new pictures would overrun the goal,
                    // blur them until judged.
                    let shown = (self.held + lead + fresh).filter { $0.target == p.target }.compactMap { self.globalRect($0, snapshot, visible) }
                    var added = coveredByCache.filter { r in
                        let gr = map.toGlobal(r).insetBy(dx: map.pointsPerPixel, dy: map.pointsPerPixel)
                        return !shown.contains { $0.contains(gr) }
                    }.flatMap { item($0, .plain) }
                    let spent = PipelineTimings.ms(since: tRun)
                    if !pending.isEmpty && spent + estimatedMs > self.coverGoalMs {
                        added += pending.flatMap { item($0, blur($0)) }
                        timing.coveredFirst += pending.count
                    }
                    if !added.isEmpty { early += added; publishEarly() }
                case let .fastFlag(rv):
                    early += item(rv.rect, rv.display == .cover ? .plain : blur(rv.rect))
                    timing.fastFlags += 1
                    publishEarly()
                }
            }
            tStage = PipelineTimings.now()
            let v = judger.judgeArea(img, context: ctx, within: area, budget: budget, progress: progress)
            timing.judgeMs += PipelineTimings.ms(since: tStage)
            timing.calls += 1
            timing.judgements += v.judgements
            timing.overloaded += v.overloaded
            tStage = PipelineTimings.now()
            defer { timing.planMs += PipelineTimings.ms(since: tStage) }
            if judged { bucket.spend(v.judgements) }
            let wasHot = hot.contains(p.target)
            if v.hot { hot.insert(p.target) } else { hot.remove(p.target) }
            // A window that has just turned hot is judged again wherever it shows, so pictures judged before it turned
            // hot are held to the hot rule too.
            if v.hot && !wasHot { pending += p.visible }

            let o = origin(of: p.target, snapshot)
            countCleanJudgements(p.target, judgedArea: map.toGlobal(area).intersection(visBox), verdict: v, map: map, snapshot, visible)
            fresh += covers(from: v, target: p.target, origin: o, img: img, map: map,
                            callArea: map.toGlobal(area), visibleBox: visBox)

            // Slowness covers more: a window left with unjudged entries for longer than `TIME_TO_COVER`
            // is covered whole until it is judged (step 2).
            if v.overloaded > 0 {
                let since = overloadSince[p.target] ?? now
                overloadSince[p.target] = since
                if now - since >= Register.TIME_TO_COVER {
                    fresh.append(Held(target: p.target, rel: .null, whole: true, kind: .plain, clean: 0))
                }
                pending += v.regions.filter { $0.reason == .overload }.map { map.toGlobal($0.rect) }
            } else {
                overloadSince[p.target] = nil
            }
        }
        judged = true
        tStage = PipelineTimings.now()
        defer { timing.planMs += PipelineTimings.ms(since: tStage) }

        // 4. Lifted regions are gone; add the new covers, merging with any they overlap.
        held.removeAll { $0.clean >= Register.VIDEO_VOTE }
        for n in fresh { merge(n) }
        // A window that closed takes its covers with it; nothing of it is on screen any more.
        held.removeAll { visible[$0.target] == nil }
        contentOffset = contentOffset.filter { visible[$0.key] != nil }

        // 5. Draw.
        let items = drawItems(snapshot, visible, map, moved: moved, lead: lead)
        lastBounds = [:]
        for w in snapshot.windows where w.bounds.intersects(d) { lastBounds[.window(number: w.number, ownerPID: w.ownerPID)] = w.bounds }
        lastPlan = CoverPlan(display: display, items: items)
        return lastPlan
    }

    /// Every held region, clipped to where its target is visible; for a window that just moved, its old place
    /// too, for this update (old and new frames are both covered); and the lead of covers that moved with
    /// scrolled content.
    ///
    /// A whole-window cover leaves the window's control band (`WayOut.controlBand`) uncovered, so the owner
    /// can see how to leave. Every other cover is drawn in full, inside the band too.
    func drawItems(_ snapshot: WindowSnapshot, _ visible: [JudgeTarget: [CGRect]], _ map: CaptureMap,
                   moved: [(JudgeTarget, CGRect, CGRect)], lead: [Held]) -> [CoverItem] {
        let d = display.bounds
        var items: [CoverItem] = []
        for h in held + lead {
            guard let vis = visible[h.target] else { continue }
            let o = origin(of: h.target, snapshot)
            var rects: [CGRect]
            let w = h.whole ? snapshot.info(of: h.target) : nil
            if h.whole {
                rects = vis
                if let w, let band = WayOut.controlBand(of: w, display: d) { rects = rects.subtracting(band) }
            } else {
                rects = vis.clipped(to: h.rel.offsetBy(dx: o.x, dy: o.y))
            }
            var its = rects.map { CoverItem(rect: CoordinateSpace.snapOutward($0, pointsPerPixel: map.pointsPerPixel), kind: h.kind) }
            // The way-out line goes on the largest visible piece of a whole-window cover.
            if let w, WayOut.carriesLine(w), let i = its.indices.max(by: { its[$0].rect.width * its[$0].rect.height < its[$1].rect.width * its[$1].rect.height }) {
                its[i].wayOut = true
            }
            items += its
        }
        for (t, old, _) in moved {
            for h in held where h.target == t {
                let r = (h.whole ? old : h.rel.offsetBy(dx: old.minX, dy: old.minY)).intersection(d)
                if r.hasArea { items.append(CoverItem(rect: CoordinateSpace.snapOutward(r, pointsPerPixel: map.pointsPerPixel), kind: h.kind)) }
            }
        }
        return items
    }

    /// The slice grid's anchor for a target: its origin, plus how far its content has scrolled.
    func sliceAnchor(_ t: JudgeTarget, _ snapshot: WindowSnapshot, _ map: CaptureMap) -> SliceAnchor {
        let o = map.pixelPoint(global: origin(of: t, snapshot))
        let off = contentOffset[t] ?? Translation(dx: 0, dy: 0)
        return SliceAnchor(x: Int(o.x.rounded()) + off.dx, y: Int(o.y.rounded()) + off.dy)
    }

    /// Finds content that moved by a translation in each changed part, and moves the covers over it. A cover
    /// moves only when the pixels at its new place are exactly the pixels it covered; otherwise its new place
    /// is covered as well as its old one. Returns each moved cover stretched along the motion as far as the
    /// content will go before the next plan can be drawn (drawn for this update only). Nothing is lifted here.
    func followMotion(_ prev: RGBAImage, _ img: RGBAImage, parts: [TargetArea], map: CaptureMap, snapshot: WindowSnapshot,
                      frameInterval: TimeInterval) -> [Held] {
        var lead: [Held] = [], copies: [Held] = []
        let ppx = map.pointsPerPixel
        for p in parts {
            guard let changedBox = p.changed.boundingBox, let visBox = p.visible.boundingBox,
                  let area = map.toPixels(changedBox.intersection(visBox)), area.w >= 32, area.h >= 32 else { continue }
            let newRows = MotionFinder.rowLines(img, area)
            let cached = rowCache[p.target].flatMap { $0.serial == frameSerial - 1 && $0.area == area ? $0.rows : nil }
            rowCache[p.target] = (frameSerial, area, newRows)
            guard let t = MotionFinder.find(old: prev, new: img, area: area, oldRows: cached ?? MotionFinder.rowLines(prev, area), newRows: newRows)
            else { continue }
            let off = contentOffset[p.target] ?? Translation(dx: 0, dy: 0)
            contentOffset[p.target] = Translation(dx: off.dx + t.dx, dy: off.dy + t.dy)
            let o = origin(of: p.target, snapshot)
            let step = (dx: CGFloat(t.dx) * ppx, dy: CGFloat(t.dy) * ppx)
            // How far the content moves before the next plan: its speed times one judging run (at least 0.25 s)
            // and a margin; at least one step, at most 2 s of motion.
            let ahead = frameInterval > 0 ? min(2, (max(runEstimateMs, 250) + 50) / 1000) / frameInterval : 1
            let reach = (dx: step.dx * max(1, CGFloat(ahead)), dy: step.dy * max(1, CGFloat(ahead)))
            for i in held.indices where held[i].target == p.target && !held[i].whole {
                guard let px = map.toPixels(held[i].rel.offsetBy(dx: o.x, dy: o.y)), px.intersects(area) else { continue }
                let movedRel = held[i].rel.offsetBy(dx: step.dx, dy: step.dy)
                let dest = PixelRect(x: px.x + t.dx, y: px.y + t.dy, w: px.w, h: px.h).intersection(area)
                if let dest, MotionFinder.matches(old: prev, new: img, r: dest, t: t) {
                    held[i].rel = movedRel
                } else {
                    var c = held[i]; c.rel = movedRel; copies.append(c)
                }
                var l = held[i]
                l.rel = movedRel.union(movedRel.offsetBy(dx: reach.dx, dy: reach.dy))
                lead.append(l)
            }
        }
        held += copies
        return lead
    }

    /// Where each target is visible on this display.
    func visibleByTarget(_ snapshot: WindowSnapshot) -> [JudgeTarget: [CGRect]] {
        var out: [JudgeTarget: [CGRect]] = [:]
        for (t, vis) in snapshot.visibleAreas(on: display.bounds, ignoring: ignoredPIDs) {
            if case .surface = t { out[.surface(display: display.id)] = vis } else { out[t] = vis }
        }
        // The display surface always exists, even when windows cover all of it.
        if out[.surface(display: display.id)] == nil { out[.surface(display: display.id)] = [] }
        return out
    }

    func globalRect(_ h: Held, _ snapshot: WindowSnapshot, _ visible: [JudgeTarget: [CGRect]]) -> CGRect? {
        if h.whole { return visible[h.target]?.boundingBox }
        let o = origin(of: h.target, snapshot)
        return h.rel.offsetBy(dx: o.x, dy: o.y)
    }

    /// The contract's duties (SD-133): a region-pass `cover` covers that picture whole; a slice-pass
    /// `cover` covers every picture region the slice touches, or the whole window and the slice itself if it
    /// touches none (the whole-window cover leaves the control band, the slice cover does not); a
    /// whole-pass `cover` or the cover-window flag covers the whole window. `contain` is blurred. An
    /// entry left unjudged (`overload`) keeps the detector's class and is judged again.
    ///
    /// The whole pass is over the call's area. When the call spanned the window's visible area, a flagged
    /// whole pass covers the whole window. When the call covered only changed parts of the window, the
    /// flag is explained by any region cover in the same call; with none, the judged area is covered.
    func covers(from v: FrameVerdict, target: JudgeTarget, origin o: CGPoint, img: RGBAImage, map: CaptureMap,
                callArea: CGRect, visibleBox: CGRect) -> [Held] {
        func rel(_ r: PixelRect) -> CGRect { map.toGlobal(r).offsetBy(dx: -o.x, dy: -o.y) }
        let spansWindow = callArea.insetBy(dx: -map.pointsPerPixel, dy: -map.pointsPerPixel).contains(visibleBox)
        let regionCover = v.regions.contains { $0.pass == .region && $0.display == .cover && $0.reason != .overload }
        func wholeOrArea() -> [Held] {
            if spansWindow { return [Held(target: target, rel: .null, whole: true, kind: .plain, clean: 0)] }
            if regionCover { return [] }
            return [Held(target: target, rel: callArea.offsetBy(dx: -o.x, dy: -o.y), whole: false, kind: .plain, clean: 0)]
        }
        var out: [Held] = []
        if v.coverWindow { out += wholeOrArea() }
        let regionEntries = v.regions.filter { $0.pass == .region }
        for e in v.regions {
            switch e.display {
            case .clear:
                continue
            case .cover:
                if e.pass == .region || e.reason == .overload {
                    out.append(Held(target: target, rel: rel(e.rect), whole: false, kind: .plain, clean: 0))
                } else if e.pass == .slice {
                    let touched = regionEntries.filter { $0.rect.intersects(e.rect) }
                    if touched.isEmpty {
                        out.append(Held(target: target, rel: .null, whole: true, kind: .plain, clean: 0))
                        // The whole-window cover leaves the control band; the flagged slice stays covered there too.
                        out.append(Held(target: target, rel: rel(e.rect), whole: false, kind: .plain, clean: 0))
                    }
                    for r in touched { out.append(Held(target: target, rel: rel(r.rect), whole: false, kind: .plain, clean: 0)) }
                } else {
                    out += wholeOrArea()
                }
            case .contain:
                // A blurred copy of the region; if it cannot be made, a plain cover instead.
                let kind: CoverKind = ContainBlur.make(img, e.rect).map { .blur($0) } ?? .plain
                out.append(Held(target: target, rel: rel(e.rect), whole: false, kind: kind, clean: 0))
            }
        }
        return out
    }

    /// SD-230: a held region counts one clean judgement when a call that includes it returns only
    /// `clear` entries over it. Any `cover` or `contain` over it resets the count. Calls that do not
    /// include the region, and entries left unjudged, do not count.
    func countCleanJudgements(_ t: JudgeTarget, judgedArea: CGRect, verdict v: FrameVerdict, map: CaptureMap,
                              _ snapshot: WindowSnapshot, _ visible: [JudgeTarget: [CGRect]]) {
        let slack = judgedArea.insetBy(dx: -map.pointsPerPixel, dy: -map.pointsPerPixel)
        for i in held.indices where held[i].target == t {
            guard var g = globalRect(held[i], snapshot, visible) else { continue }
            if let vb = visible[t]?.boundingBox { g = g.intersection(vb) }
            guard g.hasArea, slack.contains(g) else { continue }
            if v.coverWindow { held[i].clean = 0; continue }
            let over = v.regions.filter { map.toGlobal($0.rect).intersects(g) }
            if over.contains(where: { $0.display != .clear && $0.reason != .overload }) {
                held[i].clean = 0
            } else if !over.isEmpty && !over.contains(where: { $0.reason == .overload }) {
                held[i].clean += 1
            }
        }
    }

    func merge(_ n: Held) {
        if let i = held.firstIndex(where: { $0.target == n.target && $0.whole == n.whole && (n.whole || $0.rel.intersects(n.rel)) }) {
            held[i].rel = n.whole ? .null : held[i].rel.union(n.rel)
            held[i].kind = held[i].kind.stronger(n.kind)
            held[i].clean = 0
        } else {
            held.append(n)
        }
    }
}
