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
        /// Where and when its own judge call (step 3b) last found it flagged; judged there again once something changed,
        /// or after `RECHECK_FLAGGED_EVERY` in any case.
        var flaggedAt: CGRect? = nil
        var flaggedWhen: TimeInterval? = nil
        /// Made for entries left unjudged (`overload`, or the whole window after `TIME_TO_COVER`), not for a flag. Such a
        /// cover merged into one that already holds all of it changes nothing that was judged, so its clean count stands.
        var fromOverload = false
        /// The entries over it judged clean (freshly, or from the exact-match cache) since its last clean judgement: when
        /// every entry over it is in here, that is one more clean judgement of every pixel it hides, even if the budget
        /// spread the judging over several calls. Emptied by a flag, a change in its area, a move and each vote.
        var round: Set<EntryKey> = []
    }
    /// One entry of a judge call, by pass and rectangle (frame pixels).
    struct EntryKey: Hashable { var pass: JudgePass; var rect: PixelRect }
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
    /// The frame of the last check, and every changed area reported since (frame pixels). Holds one frame's pixels.
    var checkBase: (image: RGBAImage, map: CaptureMap, generation: Int)?
    var reportedSince: [PixelRect] = []
    public private(set) var dirtyMismatches = 0
    var lastFrameTime: TimeInterval?
    /// Cover first when judging a window's new pictures would end later than this after the frame arrived
    /// (`COVER_GOAL`; tests that run unoptimised builds raise it).
    public var coverGoalMs = Register.COVER_GOAL * 1000
    /// How long one `process` call may judge (`JUDGE_CALL_WALL`); what is left is blurred and judged next time. Tests
    /// that run unoptimised builds pass a longer limit when they make the pipeline.
    public var callWallMs: Double
    /// About how long one model judgement takes here (fading average), to keep a call within `callWallMs`.
    var msPerJudgement = 5.0
    /// The covers' window level (`CoverLevel.canvas`). Another app's window at or above it that overlaps a cover would
    /// show over that cover: the display is then covered whole, under that window, until it goes. Nil turns this off.
    public var canvasLevel: Int? = CoverLevel.canvas
    /// How long a judging run takes (the recent longest, fading by a fifth a run): how far ahead a moving
    /// cover must reach.
    var runEstimateMs = 0.0
    /// Where the covers judged on their own (step 3b) take their turn from.
    var recheckTurn = 0
    /// The judgements a cover judged on its own gets even when the frame's time is used up.
    static let recheckFloor = 16
    /// Frames in a row whose judging took longer than the goal.
    var overrunFrames = 0
    /// Runs so far, and the run in which each target last had judging time: targets with nothing new to judge (covers
    /// waiting to lift, work left over) take turns by it, so none waits for ever behind another.
    var runSerial = 0
    var served: [JudgeTarget: Int] = [:]
    /// A judge call, by target and area (frame pixels).
    struct CallKey: Hashable { var target: JudgeTarget; var area: PixelRect }
    /// Calls that only judge again (nothing new in them) whose next entry costs more than they could be given (a long
    /// thin strip's whole pass, say): the budget is saved up for it, and it is then judged whatever the call's time
    /// limit. Without this, cheaper calls spend the budget every frame and that entry, and every cover over it, waits
    /// for ever.
    var saving: [CallKey: Int] = [:]
    /// Held covers (by index) already judged in this run by their window's own call.
    var talliedThisRun: Set<Int> = []
    /// Pictures seen clean once are waiting for their second clean check (`VerdictCache.CLEAN_CHECKS`), which the looks
    /// at a still screen give them in the background (step 3c), until `secondChecksUntil` at the latest.
    public private(set) var secondChecksDue = false
    var secondChecksUntil: TimeInterval?
    /// How long second checks keep the looks at a still screen going after a picture was last seen clean once: on a slow
    /// Mac the budget's spare half may not reach them all, and a still screen must still come to rest. One not given its
    /// check by then gets it when it comes back. A working value, tied to `FULL_REJUDGE_SHOW_FIRST`.
    static let secondChecksFor: TimeInterval = Register.FULL_REJUDGE_SHOW_FIRST
    /// Whether step 3c runs. Off, a picture seen clean once gets its second check only when it comes back (the lab
    /// bench measures both).
    public var backgroundSecondChecks = true
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
    /// The window that made the last plan whole (`windowAboveCovers`), for the lab event log: geometry and layer only.
    public private(set) var lastAbove: WindowInfo?

    public init(display: DisplayDescriptor, judger: Judging, budgetShare: Double, ignoredPIDs: Set<Int32>,
                callWallMs: Double = Register.JUDGE_CALL_WALL * 1000) {
        self.display = display; self.judger = judger; self.ignoredPIDs = ignoredPIDs; self.callWallMs = callWallMs
        self.bucket = TokenBucket(rate: budgetShare)
        // A display starts covered whole until its first judged frame.
        self.lastPlan = .covered(display, because: .notYetJudged)
    }

    public func setBudgetShare(_ rate: Double) { bucket.rate = rate }

    /// What the pipeline holds now, in counts only (for the lab event log and tests; nothing about screen content).
    public struct Diagnostics: Sendable, Equatable {
        public var heldPlain = 0, heldBlur = 0, heldWhole = 0, heldWaiting = 0, pending = 0
        public var tokens = 0.0, msPerJudgement = 0.0, runEstimateMs = 0.0, overrunFrames = 0
        public var judged = false
    }
    /// True while something is still to be judged with nothing new on screen: covers waiting to lift, or entries left for
    /// a later call. The capture sends no frame while the screen is still, so the watcher then asks for a look at the last
    /// frame itself (an idle frame); without one a still screen would never settle.
    /// Pictures seen clean once waiting for their second clean check count as something left (step 3c), until they have
    /// had it or until `secondChecksFor` has passed.
    public var needsAnotherLook: Bool { judged && (!(held.isEmpty && pending.isEmpty) || secondChecksWanted) }
    var secondChecksWanted: Bool { secondChecksDue && backgroundSecondChecks }

    /// A judge call left pictures seen clean once: the looks at a still screen give them their second check, for at most
    /// `secondChecksFor` from when they started waiting. Calls while they wait do not push that back (a full re-judge on a
    /// still screen reports the same pictures), so the looks for them always come to an end.
    func noteSecondChecks(_ v: FrameVerdict, now: TimeInterval) {
        guard v.secondChecksLeft > 0, !secondChecksDue else { return }
        secondChecksDue = true
        secondChecksUntil = now + Self.secondChecksFor
    }

    /// Every held cover as "target rect whole/kind clean", for the lab tools (geometry and counts only).
    public var heldLines: [String] {
        held.map { h in
            let t: String
            switch h.target { case let .window(n, pid): t = "w\(n)/\(pid)"; case .surface: t = "surface" }
            let r = h.rel
            return String(format: "%@ %@ %.0f,%.0f,%.0f,%.0f clean=%d round=%d", t, h.whole ? "whole" : (h.kind == .plain ? "plain" : "blur"),
                          r.minX, r.minY, r.width, r.height, h.clean, h.round.count)
        }
    }
    public var diagnostics: Diagnostics {
        var d = Diagnostics()
        for h in held {
            if h.whole { d.heldWhole += 1 } else if case .plain = h.kind { d.heldPlain += 1 } else { d.heldBlur += 1 }
        }
        d.pending = pending.count; d.tokens = bucket.tokens; d.msPerJudgement = msPerJudgement
        d.runEstimateMs = runEstimateMs; d.overrunFrames = overrunFrames; d.judged = judged
        return d
    }

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
        judgedGeneration = nil; lastDirtyCheck = nil; checkBase = nil; reportedSince = []; secondChecksDue = false; secondChecksUntil = nil
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
            // Pictures seen clean once get their second clean check meanwhile (step 3c).
            guard judged, judgedGeneration == f.generation, let img = lastImage, let map = lastMap,
                  !(held.isEmpty && pending.isEmpty && !secondChecksWanted) else { return lastPlan }
            return run(img, previous: nil, frameInterval: 0, map: map, dirty: [], snapshot: snapshot, now: now, date: date, pointer: pointer,
                       idle: true, provisional: provisional)
        case .complete:
            guard let img = f.image, let map = f.map, map.pixelWidth == img.width, map.pixelHeight == img.height, map.coversDisplay else {
                return cover(because: .badFrameMetadata)
            }
            // The first frame of another stream is judged whole, with no motion carried over from the old stream.
            let sameStream = judgedGeneration == f.generation
            let previous = sameStream && lastMap.map { $0 == map } == true ? lastImage : nil
            // The reported changed areas are checked against the pixels now and then: this frame is compared with the frame
            // of the last check, outside every area reported since. A change anywhere else, in any frame between, means they
            // cannot be trusted, and the whole frame is judged.
            var dirty = sameStream ? f.dirty : nil
            if let reported = dirty, let base = checkBase, base.map == map, base.generation == f.generation {
                reportedSince += reported
                if reportedSince.count > 256 { reportedSince = DirtyRegions.prepare(reportedSince, width: img.width, height: img.height) }
                if f.time - (lastDirtyCheck ?? -.infinity) >= Register.DIRTY_CHECK_EVERY {
                    if DirtyRegions.changedOutside(old: base.image, new: img, reported: reportedSince) { dirty = nil; dirtyMismatches += 1 }
                    checkBase = (img, map, f.generation); reportedSince = []; lastDirtyCheck = f.time
                }
            } else {
                // Judged whole (or the first frame of a stream or size): the next check starts from this frame.
                checkBase = (img, map, f.generation); reportedSince = []
                if lastDirtyCheck == nil { lastDirtyCheck = f.time }
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
             now: TimeInterval, date: Date, pointer: CGPoint? = nil, idle: Bool = false, provisional: ((CoverPlan) -> Void)?) -> CoverPlan {
        var timing = PipelineTimings()
        let tRun = PipelineTimings.now()
        defer {
            timing.totalMs = PipelineTimings.ms(since: tRun); lastTimings = timing
            runEstimateMs = max(timing.totalMs, 0.8 * runEstimateMs)
            overrunFrames = timing.totalMs > coverGoalMs ? overrunFrames + 1 : 0
        }
        var tStage = tRun
        let d = display.bounds
        let visible = visibleByTarget(snapshot)
        // A cover whose window is missing from this list stays where it last stood (see `fullRect`).
        for i in held.indices {
            if present(held[i].target, snapshot) {
                held[i].missingSince = nil
            } else if held[i].missingSince == nil {
                // Clean judgements made while the window was there say nothing about its place now: they start again.
                held[i].missingSince = now
                held[i].clean = 0
                held[i].round = []
            }
        }
        runSerial += 1
        talliedThisRun = []
        // Windows that moved or changed size since the last snapshot.
        var moved: [(JudgeTarget, CGRect, CGRect)] = []
        for (t, old) in lastBounds { if let nb = snapshot.bounds(of: t), nb != old { moved.append((t, old, nb)) } }
        // What the frame itself shows changed (global points): nothing for a frame that says nothing changed, the whole
        // display when it cannot say. A full re-judge on the `FULL_REJUDGE` rhythm, or covers judged again, is no change:
        // nothing new is blurred first for them.
        // A change under a cover starts its count again: only clean judgements of what it hides now count, so four more
        // are needed, the first possibly in this very frame. (The count is not kept for content that keeps changing, a
        // playing video included: a cover over it lifts once it has been still for four clean judgements.) Elsewhere, an
        // entry judged before a change that touched it no longer counts towards any cover's next clean judgement.
        let changedAreas: [CGRect] = dirty.map { DirtyRegions.prepare($0, width: img.width, height: img.height).map(map.toGlobal) } ?? [d]
        // Under a cover, a new frame's pixels are compared with the last judged frame's wherever it stands, whatever the frame
        // reports (the reported areas can miss a change): pixels that differ are a change, and pixels that are the same
        // are none, even where a change is reported. With no last frame of this stream to compare, a reported change, or
        // a frame that cannot say what changed, counts as one. An entry is dropped from a round where a reported change
        // touches it and its pixels differ.
        func coverChanged(_ g: CGRect) -> Bool {
            if let prev = previous, let px = map.toPixels(g) { return DirtyRegions.differ(prev, img, px) }
            return changedAreas.contains { $0.intersects(g) }
        }
        func entryChanged(_ g: CGRect) -> Bool {
            guard changedAreas.contains(where: { $0.intersects(g) }) else { return false }
            guard let prev = previous, let px = map.toPixels(g) else { return true }
            return DirtyRegions.differ(prev, img, px)
        }
        // Only a frame with new pixels can change anything (a "nothing changed" frame is judged on the last frame's).
        let newPixels = previous != nil || !changedAreas.isEmpty
        for i in held.indices {
            if moved.contains(where: { $0.0 == held[i].target }) { held[i].round = []; continue }
            guard newPixels else { continue }
            if let g = fullRect(held[i], snapshot, visible), coverChanged(g) {
                held[i].clean = 0; held[i].round = []
            } else if !held[i].round.isEmpty {
                held[i].round = held[i].round.filter { e in !entryChanged(map.toGlobal(e.rect)) }
            }
        }

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
            // Covers waiting to lift are judged on their own (step 3b), over exactly what each hides, so the entries over
            // each stay the same from one call to the next and its clean judgements can be gathered over several calls.
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
        /// The part of a target's changed area that the frame shows changed (empty when it is only judged again).
        func freshChange(_ p: TargetArea) -> [CGRect] {
            p.changed.flatMap { c in changedAreas.map { $0.intersection(c) } }.filter(\.hasArea)
        }
        let fresh = Set(parts.filter { !freshChange($0).isEmpty }.map(\.target))
        // Hot windows first; then what changed (the window under the pointer and the ones nearest it, else front to
        // back); then what is only judged again (covers waiting to lift, work left over), the one served longest ago first.
        parts.sort { a, b in
            let ha = hot.contains(a.target), hb = hot.contains(b.target)
            if ha != hb { return ha }
            let fa = fresh.contains(a.target), fb = fresh.contains(b.target)
            if fa != fb { return fa }
            if !fa {
                let sa = served[a.target] ?? -1, sb = served[b.target] ?? -1
                if sa != sb { return sa < sb }
            }
            let da = pointerDistance(a), db = pointerDistance(b)
            if da != db { return da < db }
            return order[a.target]! < order[b.target]!
        }
        timing.changeMs = PipelineTimings.ms(since: tStage)

        // 2a. A window moved: its covers are drawn at its new place (and its old one) now, before anything is judged.
        if judged, !moved.isEmpty, let provisional {
            provisional(guarded(CoverPlan(display: display, items: drawItems(snapshot, visible, map, moved: moved, lead: [])), snapshot))
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
                provisional(guarded(CoverPlan(display: display, items: drawItems(snapshot, visible, map, moved: moved, lead: lead)), snapshot))
                timing.provisionalMs.append(PipelineTimings.ms(since: tRun))
            }
        }

        // 3. Judge and turn classes into covers.
        var newCovers: [Held] = []
        // Covers and blurs handed out early in this frame (cover first, fast flags): drawn in provisional plans
        // only. The final plan comes from the full rule alone.
        var early: [CoverItem] = []
        func publishEarly() {
            guard let provisional, judged else { return }
            provisional(guarded(CoverPlan(display: display, items: drawItems(snapshot, visible, map, moved: moved, lead: lead + newCovers) + early), snapshot))
            timing.provisionalMs.append(PipelineTimings.ms(since: tRun))
        }
        // Cover first, for the whole frame, on pictures only. When recent frames took longer than the goal, a large changed
        // part (a quarter of the display or more, where the picture finder itself takes a while) is blurred whole at once,
        // and only until the finder has looked at it: then only the pictures it found stay blurred, until judged, and text
        // and other areas without pictures are sharp again. When judging has overrun the goal `OVERRUN_FRAMES` frames in a
        // row, the pictures in every changed part are found and blurred before any judging. (Each judge call's own cover
        // first still blurs its pictures when it runs.)
        if judged, provisional != nil {
            // Only what the frame shows changed: covers judged again and full re-judges blur nothing first.
            func px(_ p: TargetArea) -> PixelRect? {
                guard let changedBox = freshChange(p).boundingBox, let visBox = p.visible.boundingBox else { return nil }
                return map.toPixels(changedBox.intersection(visBox))
            }
            func blurItems(_ r: PixelRect, _ vis: [CGRect]) -> [CoverItem] {
                let kind: CoverKind = ContainBlur.make(img, r).map { .blur($0) } ?? .plain
                return vis.clipped(to: map.toGlobal(r)).map { CoverItem(rect: CoordinateSpace.snapOutward($0, pointsPerPixel: map.pointsPerPixel), kind: kind) }
            }
            let quarter = img.width * img.height / 4
            let large = runEstimateMs > coverGoalMs ? parts.filter { (px($0)?.area ?? 0) >= quarter } : []
            if !large.isEmpty { timing.blurAtOnceFirings += 1 }
            let look = overrunFrames >= Register.OVERRUN_FRAMES ? parts : large
            if !large.isEmpty {
                early = large.flatMap { p in px(p).map { blurItems($0, p.visible) } ?? [] }
                timing.blurredAtOnce += large.count
                publishEarly()
            }
            if !look.isEmpty {
                var found: [CoverItem] = [], unknown: [CoverItem] = []
                for p in look {
                    guard let a = px(p) else { continue }
                    if let pics = judger.pictureRegions(img, within: a) {
                        for r in pics { found += blurItems(r, p.visible) }
                    } else if large.contains(where: { $0.target == p.target }) {
                        unknown += blurItems(a, p.visible)   // this judge cannot say where its pictures are: stays blurred
                    }
                }
                timing.blurredAtOnce += found.count
                early = found + unknown
                publishEarly()
            }
        }
        // Parts this call had no time for: blurred in this plan, and judged in the next call.
        var leftOver: [CoverItem] = []
        // Set once a call that only judges again is saving its budget up: the calls after it that only judge again get none.
        var holding = false
        var savingUsed: Set<CallKey> = []
        /// The budget for a call that only judges again: what it is saving up for once there is enough (else none, and the
        /// budget is kept), or none while another call saves up, or `normal`.
        func againBudget(_ key: CallKey, normal: Int) -> Int {
            savingUsed.insert(key)
            if let n = saving[key] {
                // Never more than half of `JUDGING_STALL` on one entry: on a Mac that slow it is left (and its covers stay).
                guard Double(n) * msPerJudgement <= Register.JUDGING_STALL * 500 else { saving[key] = nil; return holding ? 0 : normal }
                if bucket.available >= n { return max(normal, n) }
                holding = true
                return 0
            }
            return holding ? 0 : normal
        }
        func afterAgain(_ key: CallKey, given: Int, _ v: FrameVerdict) {
            if v.nextCost > given { saving[key] = min(v.nextCost, Register.DETECTOR_CALL_CAP) } else { saving[key] = nil }
        }
        // The first frame after the display was covered whole is judged within one call's worth in all.
        let firstFrame = !judged
        var firstLeft = Register.DETECTOR_CALL_CAP
        // A fifth of the time is kept for covers judged on their own (step 3b), when there are any.
        let partsWallMs = held.isEmpty ? callWallMs : 0.8 * callWallMs
        for p in parts {
            guard let changedBox = p.changed.boundingBox, let visBox = p.visible.boundingBox,
                  let area = map.toPixels(changedBox.intersection(visBox)) else { continue }
            let spentMs = PipelineTimings.ms(since: tRun)
            if spentMs >= partsWallMs {
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
            budget = min(budget, Int(min(Double(Register.DETECTOR_CALL_CAP), max(0, (partsWallMs - spentMs) / msPerJudgement))))
            let callKey = CallKey(target: p.target, area: area)
            let again = judged && !fresh.contains(p.target)
            if again { budget = againBudget(callKey, normal: budget) }
            let focus = pointer.flatMap { q in map.toPixels(CGRect(x: q.x - 1, y: q.y - 1, width: 2, height: 2)) }
            let ctx = JudgeContext(windowID: p.target.contextID, startsCovered: false, display: .trusted, isVideo: false, now: date,
                                   sliceAnchor: sliceAnchor(p.target, snapshot, map), focus: focus)
            let vis = p.visible
            let partIsFresh = fresh.contains(p.target)
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
                    let shown = (self.held + lead + newCovers).filter { $0.target == p.target }.compactMap { self.fullRect($0, snapshot, visible) }
                    var added = coveredByCache.filter { r in
                        let gr = map.toGlobal(r).insetBy(dx: map.pointsPerPixel, dy: map.pointsPerPixel)
                        return !shown.contains { $0.contains(gr) }
                    }.flatMap { item($0, .plain) }
                    let spent = PipelineTimings.ms(since: tRun)
                    // Cover first is for new pictures: a part only judged again has nothing new to blur first.
                    if !pending.isEmpty && partIsFresh && spent + estimatedMs > self.coverGoalMs {
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
            if again { afterAgain(callKey, given: budget, v) }
            if budget > 0 && (v.judgements > 0 || v.overloaded == 0) { served[p.target] = runSerial }
            if v.judgements > 0 { msPerJudgement = 0.7 * msPerJudgement + 0.3 * callMs / Double(v.judgements) }
            if firstFrame { firstLeft = max(0, firstLeft - v.judgements) }
            timing.calls += 1
            timing.judgements += v.judgements
            timing.overloaded += v.overloaded
            timing.modelFaults += v.modelFaults
            noteSecondChecks(v, now: now)
            tStage = PipelineTimings.now()
            defer { timing.planMs += PipelineTimings.ms(since: tStage) }
            if judged { bucket.spend(v.judgements) }
            let wasHot = hot.contains(p.target)
            if v.hot { hot.insert(p.target) } else { hot.remove(p.target) }
            // A window that has just turned hot is judged again wherever it shows, so pictures judged before it turned
            // hot are held to the hot rule too.
            if v.hot && !wasHot { pending += p.visible }

            let o = origin(of: p.target, snapshot)
            share(v, target: p.target, map: map)
            countCleanJudgements(p.target, judgedArea: map.toGlobal(area).intersection(visBox), verdict: v, map: map, img: img, snapshot, visible)
            newCovers += covers(from: v, target: p.target, origin: o, img: img, map: map,
                                callArea: map.toGlobal(area), visibleBox: visBox)

            // Slowness covers more: a window left with unjudged entries for longer than `TIME_TO_COVER`
            // is covered whole until it is judged (step 2).
            if v.overloaded > 0 {
                let since = overloadSince[p.target] ?? now
                overloadSince[p.target] = since
                if now - since >= Register.TIME_TO_COVER {
                    newCovers.append(Held(target: p.target, rel: .null, whole: true, kind: .plain, clean: 0, fromOverload: true))
                }
                // Judged again over the same area: the picture finder then proposes the same pictures, so the entries
                // judged in this call are not proposed afresh (and left unjudged) in the next.
                pending.append(map.toGlobal(area).intersection(visBox))
            } else {
                overloadSince[p.target] = nil
            }
        }
        // 3b. Every cover is judged on its own, over its whole rectangle where it stands on screen (whether or not it is all
        //     on show as its own window, and whether or not its window is still in the list): only clean judgements of
        //     every pixel it hides count towards lifting it.
        //     They take turns (from where the last frame stopped), within the time left; one already judged flagged on the
        //     same place is judged again only once something there has changed.
        let waiting = held.indices.filter { !talliedThisRun.contains($0) }
        var checked = 0
        for k in waiting.indices {
            let i = waiting[(k + recheckTurn) % waiting.count]
            // At least one takes its turn every frame, however long the rest took, so none waits for ever.
            let spent = PipelineTimings.ms(since: tRun)
            guard spent < callWallMs || checked == 0 else { break }
            guard let g = fullRect(held[i], snapshot, visible), let area = map.toPixels(g) else { continue }
            if held[i].flaggedAt == g, !reported.contains(where: { $0.intersects(g) }), !moved.contains(where: { $0.0 == held[i].target }),
               now - (held[i].flaggedWhen ?? now) < Register.RECHECK_FLAGGED_EVERY { continue }
            bucket.refill(now: now)
            var budget = judged ? min(bucket.available, Register.DETECTOR_CALL_CAP) : Register.DETECTOR_CALL_CAP
            budget = min(budget, Int(min(Double(Register.DETECTOR_CALL_CAP), max(Double(Self.recheckFloor), (callWallMs - spent) / msPerJudgement))))
            let callKey = CallKey(target: held[i].target, area: area)
            if judged { budget = againBudget(callKey, normal: budget) }
            let ctx = JudgeContext(windowID: held[i].target.contextID, startsCovered: false, display: .trusted, isVideo: false, now: date)
            tStage = PipelineTimings.now()
            let v = judger.judgeArea(img, context: ctx, within: area, budget: budget, progress: nil)
            let callMs = PipelineTimings.ms(since: tStage)
            timing.judgeMs += callMs
            if v.judgements > 0 { msPerJudgement = 0.7 * msPerJudgement + 0.3 * callMs / Double(v.judgements) }
            timing.calls += 1; timing.judgements += v.judgements; timing.overloaded += v.overloaded
            timing.rechecks += 1
            checked += 1
            if judged { afterAgain(callKey, given: budget, v) }
            noteSecondChecks(v, now: now)
            if judged { bucket.spend(v.judgements) }
            share(v, target: held[i].target, map: map, except: i)
            if tally(i, v, over: g, map: map, img: img) == .flagged {
                if held[i].flaggedAt != g || now - (held[i].flaggedWhen ?? now) >= Register.RECHECK_FLAGGED_EVERY { held[i].flaggedWhen = now }
                held[i].flaggedAt = g
            } else {
                held[i].flaggedAt = nil
            }
        }
        if !waiting.isEmpty { recheckTurn = (recheckTurn + max(1, checked)) % max(1, waiting.count) }

        // 3c. Second clean checks, as part of the looks at a still screen (`needsAnotherLook`; `VerdictCache.CLEAN_CHECKS`).
        //     On a look where nothing changed, after everything above, the pictures on show that were seen clean once are
        //     judged once more, with fresh jitter, so that when they come back they are served from the cache. Low
        //     priority: only from judgements beyond half the bucket, and within the time left. Nothing is lifted or cleared
        //     here, and no clean judgement is counted towards lifting a cover (nothing is shared into a cover's round): a
        //     flag covers (or a blur blurs) at once, a model failure is left unjudged and judged again over the same area,
        //     and a clean result only adds to the picture's count. Past `secondChecksFor` the looks stop for them.
        if idle, judged, secondChecksDue, backgroundSecondChecks, now > (secondChecksUntil ?? now) {
            secondChecksDue = false; secondChecksUntil = nil
            timing.secondChecksGivenUp += 1
        } else if idle, judged, secondChecksDue, backgroundSecondChecks {
            var left = false
            bucket.refill(now: now)
            for p in snapshot.split(changed: [d], display: display, ignoring: ignoredPIDs) {
                guard let changedBox = p.changed.boundingBox, let visBox = p.visible.boundingBox,
                      let area = map.toPixels(changedBox.intersection(visBox)) else { continue }
                let spent = PipelineTimings.ms(since: tRun)
                let spare = bucket.available - Int(Register.JUDGEMENT_BURST / 2)
                let budget = min(spare, Register.DETECTOR_CALL_CAP, Int(min(Double(Register.DETECTOR_CALL_CAP), max(0, (callWallMs - spent) / msPerJudgement))))
                guard budget > 0 else { left = true; break }
                let ctx = JudgeContext(windowID: p.target.contextID, startsCovered: false, display: .trusted, isVideo: false, now: date,
                                       sliceAnchor: sliceAnchor(p.target, snapshot, map))
                tStage = PipelineTimings.now()
                guard let v = judger.checkAgainInBackground(img, context: ctx, within: area, budget: budget) else { continue }
                let callMs = PipelineTimings.ms(since: tStage)
                timing.judgeMs += callMs
                if v.judgements > 0 { msPerJudgement = 0.7 * msPerJudgement + 0.3 * callMs / Double(v.judgements) }
                timing.secondCheckJudgements += v.judgements
                timing.modelFaults += v.modelFaults
                bucket.spend(v.judgements)
                if v.secondChecksLeft > 0 { left = true }
                // A model failure in a second check is a fault like any other: the entry is blurred or covered and judged
                // again in the next call.
                if v.overloaded > 0 { pending.append(map.toGlobal(area).intersection(visBox)) }
                let wasHot = hot.contains(p.target)
                if v.hot { hot.insert(p.target) }
                if v.hot && !wasHot { pending += p.visible }
                newCovers += covers(from: v, target: p.target, origin: origin(of: p.target, snapshot), img: img, map: map,
                                callArea: map.toGlobal(area), visibleBox: visBox)
            }
            secondChecksDue = left
            if !left { secondChecksUntil = nil }
        }
        saving = saving.filter { savingUsed.contains($0.key) }
        judged = true
        tStage = PipelineTimings.now()
        defer { timing.planMs += PipelineTimings.ms(since: tStage) }

        // 4. Lifted regions are gone; add the new covers, merging with any they overlap. A cover whose window has gone
        //    from the list stays where it stood until that place has been judged clean `VIDEO_VOTE` times, or the window
        //    has been gone `WINDOW_GONE` and the place has been judged clean `WINDOW_GONE_VOTE` times since it went.
        held.removeAll { h in
            h.clean >= Register.VIDEO_VOTE || (h.missingSince.map { now - $0 >= Register.WINDOW_GONE } ?? false && h.clean >= Register.WINDOW_GONE_VOTE)
        }
        for n in newCovers { merge(n) }
        clipToTargets(snapshot)
        held.removeAll { fullRect($0, snapshot, visible) == nil }
        for i in held.indices where held[i].missingSince == nil { held[i].lastGlobal = fullRect(held[i], snapshot, visible) }
        contentOffset = contentOffset.filter { visible[$0.key] != nil }
        served = served.filter { visible[$0.key] != nil }

        // 5. Draw.
        let items = drawItems(snapshot, visible, map, moved: moved, lead: lead) + leftOver
        lastBounds = [:]
        for w in snapshot.windows where w.bounds.intersects(d) { lastBounds[.window(number: w.number, ownerPID: w.ownerPID)] = w.bounds }
        // Drawn only: what is held and judged carries on as before.
        lastPlan = guarded(CoverPlan(display: display, items: items), snapshot)
        lastAbove = lastPlan.wholeDisplay == .windowAboveCovers ? windowAbove(items, snapshot) : nil
        return lastPlan
    }

    /// Another app's window at or above the covers' level that overlaps a cover in `items` (it would show over that
    /// cover), or nil. The window server's own small overlays at the cursor's level (the pointer, the screen-recording
    /// indicator: `WindowInfo.systemOverlay`) are not another app's windows and draw nothing of anyone's; every other
    /// window there, whatever its size, counts.
    func windowAbove(_ items: [CoverItem], _ snapshot: WindowSnapshot) -> WindowInfo? {
        guard let level = canvasLevel else { return nil }
        return snapshot.windows.first { w in
            w.layer >= level && w.shows && !w.systemOverlay && !ignoredPIDs.contains(w.ownerPID) && items.contains { $0.rect.intersects(w.bounds) }
        }
    }

    /// A plan as it may be drawn: covered whole, under that window, when another app's window shows over one of its
    /// covers. Provisional plans and the final plan go through the same check, so the display never alternates between
    /// the two.
    func guarded(_ plan: CoverPlan, _ snapshot: WindowSnapshot) -> CoverPlan {
        guard plan.wholeDisplay == nil, windowAbove(plan.items, snapshot) != nil else { return plan }
        return .covered(display, because: .windowAboveCovers)
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
        var lead: [Held] = [], copies: [Held] = [], split: [Held] = []
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
                let g = held[i].rel.offsetBy(dx: o.x, dy: o.y)
                guard let px = map.toPixels(g), px.intersects(area) else { continue }
                // Only the part of a cover inside what the frame reports as changed can have moved; the rest stays put.
                guard let inside = reported.map({ $0.intersection(g) }).filter(\.hasArea).boundingBox,
                      let insidePx = map.toPixels(inside) else { continue }
                let dest = PixelRect(x: insidePx.x + t.dx, y: insidePx.y + t.dy, w: insidePx.w, h: insidePx.h)
                let movedInside = inside.offsetBy(dx: step.dx - o.x, dy: step.dy - o.y)
                if insidePx.intersection(area) == insidePx, dest.intersection(area) == dest, inChanged(insidePx), inChanged(dest),
                   MotionFinder.matches(old: prev, new: img, r: dest, t: t) {
                    // The part that moved goes with its content; each part that did not stays, as a cover of its own.
                    for rest in [g].subtracting(inside) where rest.width >= 0.5 && rest.height >= 0.5 {
                        var c = held[i]; c.rel = rest.offsetBy(dx: -o.x, dy: -o.y); c.clean = 0; c.round = []; split.append(c)
                    }
                    held[i].rel = movedInside
                } else {
                    // The content did not simply move: its new place is covered too (at most one copy per cover per frame,
                    // merged with what it overlaps, starting with no clean judgements).
                    var c = held[i]; c.rel = movedInside; c.clean = 0; c.round = []; c.fromOverload = false; copies.append(c)
                }
                var l = held[i]
                l.rel = movedInside.union(movedInside.offsetBy(dx: reach.dx, dy: reach.dy))
                lead.append(l)
            }
        }
        held += split
        for c in copies { merge(c) }
        clipToTargets(snapshot)
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
                    out.append(Held(target: target, rel: rel(e.rect), whole: false, kind: .plain, clean: 0, fromOverload: e.reason == .overload))
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
                out.append(Held(target: target, rel: rel(e.rect), whole: false, kind: kind, clean: 0, fromOverload: e.reason == .overload))
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
        // Covers not all on show as this target's are counted by their own judge call (step 3b). One counted here is not
        // judged on its own in the same run: at most one clean judgement per cover per frame.
        for i in held.indices where held[i].target == t && shownWhole(held[i], snapshot, visible) && !talliedThisRun.contains(i) {
            guard let g = fullRect(held[i], snapshot, visible), slack.contains(g) else { continue }
            _ = tally(i, v, over: g, map: map, img: img)
            talliedThisRun.insert(i)
        }
    }

    enum Tally { case flagged, vote, partial, none }

    /// Every entry a call judged clean (freshly, or from the exact-match cache) joins the round of every cover of the same
    /// window it lies over, not only the cover the call was for: the same entry, by pass and rectangle, on the same pixels
    /// (a change empties the rounds) is the same judgement. Covers that overlap then gather their clean judgements together
    /// instead of each judging the same borderline pictures again. A flag over a cover starts its count again here too.
    /// Counting still happens only in a call that spans the cover (`tally`).
    func share(_ v: FrameVerdict, target: JudgeTarget, map: CaptureMap, except: Int? = nil) {
        let entries = v.regions.map { ($0, map.toGlobal($0.rect)) }
        for i in held.indices where i != except && held[i].target == target {
            if v.coverWindow { held[i].clean = 0; held[i].round = []; continue }
            guard let g = held[i].missingSince == nil ? held[i].lastGlobal : nil else { continue }
            for (e, r) in entries where r.intersects(g) {
                if e.display != .clear && e.reason != .overload {
                    held[i].clean = 0; held[i].round = []
                    break
                }
                if ![.overload, .judgedEarlier, .rejudgeDue].contains(e.reason) { held[i].round.insert(EntryKey(pass: e.pass, rect: e.rect)) }
            }
        }
    }

    /// One judge call that included all of held cover `i` (standing at `g`). Any flag over it starts its count again.
    /// Otherwise every entry over it judged clean in this call (freshly, or from the exact-match cache) joins its round;
    /// entries left unjudged, or shown as judged earlier, do not. When every entry over it now is in its round, that is one
    /// clean judgement of every pixel it hides (SD-230): its count goes up and a new round starts. With budget enough for
    /// all of them in one call, this is exactly one clean judgement per call, as before.
    func tally(_ i: Int, _ v: FrameVerdict, over g: CGRect, map: CaptureMap, img: RGBAImage) -> Tally {
        let over = v.regions.filter { map.toGlobal($0.rect).intersects(g) }
        if v.coverWindow || over.contains(where: { $0.display != .clear && $0.reason != .overload }) {
            held[i].clean = 0; held[i].round = []
            return .flagged
        }
        guard !over.isEmpty else { return .none }
        for e in over where ![.overload, .judgedEarlier, .rejudgeDue].contains(e.reason) { held[i].round.insert(EntryKey(pass: e.pass, rect: e.rect)) }
        guard over.allSatisfy({ held[i].round.contains(EntryKey(pass: $0.pass, rect: $0.rect)) }),
              !(map.toPixels(g).map { OwnCoverColours.shown(in: img, $0) } ?? true) else { return .partial }
        held[i].clean += 1
        held[i].round = []
        return .vote
    }

    /// Cuts every region cover to its window's bounds (or the display, for the display surface), so merging and moving
    /// with content never grow one past where its window can show anything. One left with nothing is dropped: no part of
    /// its window is there.
    func clipToTargets(_ snapshot: WindowSnapshot) {
        for i in held.indices.reversed() where !held[i].whole && present(held[i].target, snapshot) {
            let frame: CGRect
            if let b = snapshot.bounds(of: held[i].target) {
                frame = CGRect(origin: .zero, size: b.size).intersection(display.bounds.offsetBy(dx: -b.minX, dy: -b.minY))
            } else {
                frame = CGRect(origin: .zero, size: display.bounds.size)
            }
            let r = held[i].rel.intersection(frame)
            if r.hasArea { held[i].rel = r } else { held.remove(at: i) }
        }
    }

    func merge(_ n: Held) {
        // A cover for entries left unjudged goes into a cover that already holds all of it, or stands on its own: never
        // into the union of the two, which grew from 512-point slices to a cover of the whole window that could only lift
        // once every entry in the window had been judged again.
        if n.fromOverload && !n.whole {
            if let i = held.firstIndex(where: { $0.target == n.target && !$0.whole && $0.rel.insetBy(dx: -0.5, dy: -0.5).contains(n.rel) }) {
                held[i].kind = held[i].kind.stronger(n.kind)
            } else {
                held.append(n)
            }
            return
        }
        if let i = held.firstIndex(where: { $0.target == n.target && $0.whole == n.whole && (n.whole || $0.rel.intersects(n.rel)) }) {
            let rel = n.whole ? CGRect.null : held[i].rel.union(n.rel)
            // A cover for a flag starts the count again, as does one that makes the cover bigger. A cover for entries left
            // unjudged that it already holds all of changes nothing judged: its count and round stand (or a budget too
            // small for a busy window would start them again at every call, and nothing would ever lift).
            if !n.fromOverload || rel != held[i].rel { held[i].clean = 0; held[i].round = [] }
            held[i].rel = rel
            held[i].kind = held[i].kind.stronger(n.kind)
        } else {
            held.append(n)
        }
    }
}
