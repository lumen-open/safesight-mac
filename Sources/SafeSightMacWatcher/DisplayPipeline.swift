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
        /// Where the cover last stood on screen (global points), for when its window is missing from the window list.
        var lastGlobal: CGRect? = nil
        /// Since when its window has been missing from the window list (a closed window, or a list read that left it out).
        var missingSince: TimeInterval? = nil
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
    /// When the reported changed areas were last checked against the pixels (`DIRTY_CHECK_EVERY`), and how often they
    /// were found wrong (a count only).
    var lastDirtyCheck: TimeInterval?
    public private(set) var dirtyMismatches = 0
    var lastFrameTime: TimeInterval?
    /// Cover first when judging a window's new pictures would end later than this after the frame arrived
    /// (`COVER_GOAL`; tests that run unoptimised builds raise it).
    public var coverGoalMs = Register.COVER_GOAL * 1000
    /// How long one `process` call may judge (`JUDGE_CALL_WALL`); what is left is blurred and judged next time.
    public var callWallMs = DisplayPipeline.defaultCallWallMs
    /// The starting value of `callWallMs`. Tests that run unoptimised builds raise it.
    nonisolated(unsafe) public static var defaultCallWallMs = Register.JUDGE_CALL_WALL * 1000
    /// About how long one model judgement takes here (fading average), to keep a call within `callWallMs`.
    var msPerJudgement = 5.0
    /// The covers' window level (`CoverLevel.canvas`). Another app's window at or above it that overlaps a cover would
    /// show over that cover: the display is then covered whole, under that window, until it goes. Nil turns this off.
    public var canvasLevel: Int? = CoverLevel.canvas
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
        judgedGeneration = nil; lastDirtyCheck = nil
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
        // A window list that cannot be read is a fault, never an empty screen: no cover may be placed or lifted on it.
        // Every held cover is kept for when it can be read again.
        guard snapshot.readable else { return cover(because: .windowListUnreadable) }
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
            // The reported changed areas are checked against the pixels now and then: a change anywhere else means they
            // cannot be trusted, and the whole frame is judged.
            var dirty = sameStream ? f.dirty : nil
            if let reported = dirty, let prev = previous, f.time - (lastDirtyCheck ?? -.infinity) >= Register.DIRTY_CHECK_EVERY {
                lastDirtyCheck = f.time
                if DirtyRegions.changedOutside(old: prev, new: img, reported: reported) { dirty = nil; dirtyMismatches += 1 }
            }
            let dt = lastFrameTime.map { f.time - $0 } ?? 0
            lastImage = img; lastMap = map; lastFrameTime = f.time
            judgedGeneration = f.generation
            frameSerial += 1
            return run(img, previous: previous, frameInterval: dt, map: map, dirty: dirty, snapshot: snapshot, now: now, date: date, pointer: pointer, provisional: provisional)
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
        // A cover whose window is missing from this list stays where it last stood (see `fullRect`).
        for i in held.indices {
            if present(held[i].target, snapshot) { held[i].missingSince = nil } else if held[i].missingSince == nil { held[i].missingSince = now }
        }
        // Windows that moved or changed size since the last snapshot.
        var moved: [(JudgeTarget, CGRect, CGRect)] = []
        for (t, old) in lastBounds { if let nb = snapshot.bounds(of: t), nb != old { moved.append((t, old, nb)) } }

        // 1. What to judge: the changed areas; regions waiting to lift; overflow from earlier calls;
        //    old and new places of moved windows; and a full pass on the `FULL_REJUDGE` rhythm.
        var areas: [CGRect]
        // What the frame itself reports as changed (global points), without the areas added for re-judging.
        var reported: [CGRect] = [d]
        let fullDue = lastFullPass.map { now - $0 >= Register.FULL_REJUDGE_SHOW_FIRST } ?? true
        if dirty == nil || fullDue || !judged {
            areas = [d]
            lastFullPass = now
        } else {
            areas = DirtyRegions.prepare(dirty!, width: img.width, height: img.height).map(map.toGlobal)
            reported = areas
            areas += pending
            for h in held { if let g = fullRect(h, snapshot, visible) { areas.append(g) } }
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

        // 2a. A window moved: its covers are drawn at its new place (and its old one) now, before anything is judged.
        if judged, !moved.isEmpty, let provisional {
            provisional(CoverPlan(display: display, items: drawItems(snapshot, visible, map, moved: moved, lead: [])))
            timing.provisionalMs.append(PipelineTimings.ms(since: tRun))
        }

        // 2b. Content that moved by a translation (scrolling): its covers move with it now, in this update,
        //     before the moved area is judged again. Each moved cover is also drawn reaching ahead along the
        //     motion, for this update, as far as the content will go before the next plan.
        var lead: [Held] = []
        if judged, let prev = previous, dirty != nil {
            tStage = PipelineTimings.now()
            lead = followMotion(prev, img, parts: parts, map: map, snapshot: snapshot, frameInterval: frameInterval, reported: reported)
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
        // Cover first, for the whole frame: when recent frames took longer than the goal to judge, every changed part is
        // blurred now, before any judging, and shown as its verdicts come in.
        if judged, provisional != nil, runEstimateMs > coverGoalMs {
            for p in parts {
                for r in p.changed { if let px = map.toPixels(r) {
                    let kind: CoverKind = ContainBlur.make(img, px).map { .blur($0) } ?? .plain
                    early.append(CoverItem(rect: CoordinateSpace.snapOutward(r, pointsPerPixel: map.pointsPerPixel), kind: kind))
                    timing.blurredAtOnce += 1
                } }
            }
            publishEarly()
        }
        // Parts this call had no time for: blurred in this plan, and judged in the next call.
        var leftOver: [CoverItem] = []
        // The first frame after the display was covered whole is judged within one call's worth in all.
        let firstFrame = !judged
        var firstLeft = Register.DETECTOR_CALL_CAP
        for p in parts {
            guard let changedBox = p.changed.boundingBox, let visBox = p.visible.boundingBox,
                  let area = map.toPixels(changedBox.intersection(visBox)) else { continue }
            let spentMs = PipelineTimings.ms(since: tRun)
            if spentMs >= callWallMs {
                pending += p.changed
                leftOver += p.changed.compactMap { r in
                    map.toPixels(r).map { px in
                        CoverItem(rect: CoordinateSpace.snapOutward(r, pointsPerPixel: map.pointsPerPixel),
                                  kind: ContainBlur.make(img, px).map { .blur($0) } ?? .plain)
                    }
                }
                timing.leftForLater += 1
                continue
            }
            bucket.refill(now: now)
            // The first judgement after the display was covered whole is not limited by the budget (SD-120), but by one
            // call's worth over the whole frame; every call is kept within the time left.
            var budget = firstFrame ? firstLeft : min(bucket.available, Register.DETECTOR_CALL_CAP)
            budget = min(budget, Int(min(Double(Register.DETECTOR_CALL_CAP), max(0, (callWallMs - spentMs) / msPerJudgement))))
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
                    let shown = (self.held + lead + fresh).filter { $0.target == p.target }.compactMap { self.fullRect($0, snapshot, visible) }
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
            let callMs = PipelineTimings.ms(since: tStage)
            timing.judgeMs += callMs
            if v.judgements > 0 { msPerJudgement = 0.7 * msPerJudgement + 0.3 * callMs / Double(v.judgements) }
            if firstFrame { firstLeft = max(0, firstLeft - v.judgements) }
            timing.calls += 1
            timing.judgements += v.judgements
            timing.overloaded += v.overloaded
            timing.modelFaults += v.modelFaults
            tStage = PipelineTimings.now()
            defer { timing.planMs += PipelineTimings.ms(since: tStage) }
            if judged { bucket.spend(v.judgements) }
            let wasHot = hot.contains(p.target)
            if v.hot { hot.insert(p.target) } else { hot.remove(p.target) }
            // A window that has just turned hot is judged again wherever it shows, so pictures judged before it turned
            // hot are held to the hot rule too.
            if v.hot && !wasHot { pending += p.visible }

            let o = origin(of: p.target, snapshot)
            countCleanJudgements(p.target, judgedArea: map.toGlobal(area).intersection(visBox), verdict: v, map: map, img: img, snapshot, visible)
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
        // 3b. A cover whose full rectangle is not all on show as its own window (a window in front of it, or its window
        //     missing from the list) is judged on its own, over that whole rectangle where it stands on screen: only
        //     clean judgements of every pixel it hides count towards lifting it.
        for i in held.indices where !shownWhole(held[i], snapshot, visible) {
            // Only within the call's time: a cover not judged now simply stays.
            guard PipelineTimings.ms(since: tRun) < callWallMs,
                  let g = fullRect(held[i], snapshot, visible), let area = map.toPixels(g) else { continue }
            bucket.refill(now: now)
            let budget = judged ? min(bucket.available, Register.DETECTOR_CALL_CAP) : Register.DETECTOR_CALL_CAP
            let ctx = JudgeContext(windowID: held[i].target.contextID, startsCovered: false, display: .trusted, isVideo: false, now: date)
            tStage = PipelineTimings.now()
            let v = judger.judgeArea(img, context: ctx, within: area, budget: budget, progress: nil)
            timing.judgeMs += PipelineTimings.ms(since: tStage)
            timing.calls += 1; timing.judgements += v.judgements; timing.overloaded += v.overloaded
            if judged { bucket.spend(v.judgements) }
            if v.coverWindow || v.regions.contains(where: { $0.display != .clear && $0.reason != .overload }) {
                held[i].clean = 0
            } else if !v.regions.isEmpty && v.overloaded == 0, !OwnCoverColours.shown(in: img, area) {
                held[i].clean += 1
            }
        }
        judged = true
        tStage = PipelineTimings.now()
        defer { timing.planMs += PipelineTimings.ms(since: tStage) }

        // 4. Lifted regions are gone; add the new covers, merging with any they overlap. A cover whose window has gone
        //    from the list stays where it stood until that place has been judged clean `VIDEO_VOTE` times, or the window
        //    has been gone `WINDOW_GONE` and the place has been judged clean since.
        held.removeAll { h in
            h.clean >= Register.VIDEO_VOTE || (h.missingSince.map { now - $0 >= Register.WINDOW_GONE } ?? false && h.clean >= 1)
        }
        for n in fresh { merge(n) }
        held.removeAll { fullRect($0, snapshot, visible) == nil }
        for i in held.indices where held[i].missingSince == nil { held[i].lastGlobal = fullRect(held[i], snapshot, visible) }
        contentOffset = contentOffset.filter { visible[$0.key] != nil }

        // 5. Draw.
        let items = drawItems(snapshot, visible, map, moved: moved, lead: lead) + leftOver
        lastBounds = [:]
        for w in snapshot.windows where w.bounds.intersects(d) { lastBounds[.window(number: w.number, ownerPID: w.ownerPID)] = w.bounds }
        lastPlan = CoverPlan(display: display, items: items)
        if let level = canvasLevel, snapshot.windows.contains(where: { w in
            w.layer >= level && w.shows && !ignoredPIDs.contains(w.ownerPID) && items.contains { $0.rect.intersects(w.bounds) }
        }) {
            // Drawn only: what is held and judged carries on as before.
            lastPlan = .covered(display, because: .windowAboveCovers)
        }
        return lastPlan
    }

    /// Every held region, in full, wherever it stands: a window in front of it never trims it (that window may be see-through,
    /// and drawing over it only covers more); for a window that just moved, its old place too, for this update (old and
    /// new frames are both covered); and the lead of covers that moved with scrolled content.
    ///
    /// A whole-window cover leaves the window's control band (`WayOut.controlBand`) uncovered, so the owner
    /// can see how to leave. Every other cover is drawn in full, inside the band too.
    func drawItems(_ snapshot: WindowSnapshot, _ visible: [JudgeTarget: [CGRect]], _ map: CaptureMap,
                   moved: [(JudgeTarget, CGRect, CGRect)], lead: [Held]) -> [CoverItem] {
        let d = display.bounds
        var items: [CoverItem] = []
        for h in held + lead {
            guard let full = fullRect(h, snapshot, visible) else { continue }
            var rects = [full]
            let w = h.whole ? snapshot.info(of: h.target) : nil
            if case .surface = h.target, h.whole { rects = visible[h.target] ?? [] }
            if let w, let band = WayOut.controlBand(of: w, display: d) { rects = rects.subtracting(band) }
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
                      frameInterval: TimeInterval, reported: [CGRect]) -> [Held] {
        // True when all of a pixel rectangle lies in what the frame reported as changed.
        func inChanged(_ r: PixelRect) -> Bool {
            reported.reduce([map.toGlobal(r)]) { $0.subtracting($1) }.allSatisfy { $0.width < 0.5 || $0.height < 0.5 }
        }
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
                // It moves only when all of it, and all of where it goes, lie in the changed area and the pixels there
                // match: a cover merged over content that moved only in part stays, with a copy where that part went.
                let dest = PixelRect(x: px.x + t.dx, y: px.y + t.dy, w: px.w, h: px.h)
                if px.intersection(area) == px, dest.intersection(area) == dest, inChanged(px), inChanged(dest),
                   MotionFinder.matches(old: prev, new: img, r: dest, t: t) {
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

    /// True when the target is in the window list and on this display (the display surface always is).
    func present(_ t: JudgeTarget, _ snapshot: WindowSnapshot) -> Bool {
        guard case .window = t else { return true }
        return snapshot.info(of: t).map { $0.shows && $0.bounds.intersects(display.bounds) } ?? false
    }

    /// The whole of what a held cover hides, in global points, cut to the display: a whole-window cover is the window's
    /// bounds; a region is its rectangle on its window. Nothing in front of the window trims it. A cover whose window is
    /// missing from the list stands where it last stood. A whole cover of the display surface is the surface's visible
    /// part (every window is in front of the desktop by definition).
    func fullRect(_ h: Held, _ snapshot: WindowSnapshot, _ visible: [JudgeTarget: [CGRect]]) -> CGRect? {
        let r: CGRect?
        if !present(h.target, snapshot) {
            r = h.lastGlobal
        } else if case .surface = h.target {
            r = h.whole ? visible[h.target]?.boundingBox : h.rel.offsetBy(dx: display.bounds.minX, dy: display.bounds.minY)
        } else if let b = snapshot.bounds(of: h.target) {
            r = h.whole ? b : h.rel.offsetBy(dx: b.minX, dy: b.minY)
        } else {
            r = nil
        }
        guard let c = r?.intersection(display.bounds), c.hasArea else { return nil }
        return c
    }

    /// True when every point a held cover hides is on show as its own target's, so the target's own judge calls see all
    /// of it (no window in front of it, and the window is in the list).
    func shownWhole(_ h: Held, _ snapshot: WindowSnapshot, _ visible: [JudgeTarget: [CGRect]]) -> Bool {
        guard present(h.target, snapshot), let g = fullRect(h, snapshot, visible), let vis = visible[h.target] else { return false }
        if case .surface = h.target, h.whole { return true }
        return vis.reduce([g]) { $0.subtracting($1) }.allSatisfy { $0.width < 0.5 || $0.height < 0.5 }
    }

    /// The contract's duties (SD-133): a region-pass `cover` covers that picture whole; a slice-pass
    /// `cover` covers every picture region the slice touches, or the whole window and the slice itself if it
    /// touches none (the whole-window cover leaves the control band, the slice cover does not); a
    /// whole-pass `cover` or the cover-window flag covers the whole window. `contain` is blurred. An
    /// entry left unjudged (`overload`) keeps the detector's class and is judged again.
    ///
    /// The whole pass is over the call's area. When the call spanned the window's visible area, a flagged
    /// whole pass covers the whole window. When the call covered only changed parts of the window, the judged
    /// area is covered, whatever region covers the same call made: a region cover does not explain the flag away.
    func covers(from v: FrameVerdict, target: JudgeTarget, origin o: CGPoint, img: RGBAImage, map: CaptureMap,
                callArea: CGRect, visibleBox: CGRect) -> [Held] {
        func rel(_ r: PixelRect) -> CGRect { map.toGlobal(r).offsetBy(dx: -o.x, dy: -o.y) }
        let spansWindow = callArea.insetBy(dx: -map.pointsPerPixel, dy: -map.pointsPerPixel).contains(visibleBox)
        func wholeOrArea() -> [Held] {
            if spansWindow { return [Held(target: target, rel: .null, whole: true, kind: .plain, clean: 0)] }
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
    func countCleanJudgements(_ t: JudgeTarget, judgedArea: CGRect, verdict v: FrameVerdict, map: CaptureMap, img: RGBAImage,
                              _ snapshot: WindowSnapshot, _ visible: [JudgeTarget: [CGRect]]) {
        let slack = judgedArea.insetBy(dx: -map.pointsPerPixel, dy: -map.pointsPerPixel)
        // Covers not all on show as this target's are counted by their own judge call (step 3b).
        for i in held.indices where held[i].target == t && shownWhole(held[i], snapshot, visible) {
            guard let g = fullRect(held[i], snapshot, visible), slack.contains(g) else { continue }
            if v.coverWindow { held[i].clean = 0; continue }
            let over = v.regions.filter { map.toGlobal($0.rect).intersects(g) }
            if over.contains(where: { $0.display != .clear && $0.reason != .overload }) {
                held[i].clean = 0
            } else if !over.isEmpty && !over.contains(where: { $0.reason == .overload }),
                      !(map.toPixels(g).map { OwnCoverColours.shown(in: img, $0) } ?? true) {
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
