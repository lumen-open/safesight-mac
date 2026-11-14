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
    /// True once a frame of this display has been judged and drawn since it was last covered whole.
    public private(set) var judged = false
    public private(set) var lastPlan: CoverPlan

    public init(display: DisplayDescriptor, judger: Judging, budgetShare: Double, ignoredPIDs: Set<Int32>) {
        self.display = display; self.judger = judger; self.ignoredPIDs = ignoredPIDs
        self.bucket = TokenBucket(rate: budgetShare)
        // A display starts covered whole until its first judged frame.
        self.lastPlan = .covered(display, because: .notYetJudged)
    }

    public func setBudgetShare(_ rate: Double) { bucket.rate = rate }

    /// Covers the whole display: it cannot be judged. It stays covered until a frame is judged again.
    @discardableResult
    public func cover(because cause: FaultCause) -> CoverPlan {
        judged = false
        lastPlan = .covered(display, because: cause)
        return lastPlan
    }

    /// Drops every cover and all memory of the screen (used when the owner pauses, in practice state only).
    public func reset() {
        held = []; pending = []; lastImage = nil; lastMap = nil; lastFullPass = nil
        lastBounds = [:]; overloadSince = [:]; hot = []
        cover(because: .notYetJudged)
    }

    /// Handles one frame and returns everything to draw on this display.
    public func process(_ f: CapturedFrame, snapshot: WindowSnapshot, now: TimeInterval, date: Date = Date()) -> CoverPlan {
        display = f.display
        switch f.status {
        case .blank, .suspended, .stopped:
            return cover(because: .frameNotJudgeable)
        case .started:
            return judged ? lastPlan : cover(because: .notYetJudged)
        case .idle:
            // Nothing changed. Keep judging regions waiting to lift, on the last frame's pixels.
            guard judged, let img = lastImage, let map = lastMap, !(held.isEmpty && pending.isEmpty) else { return lastPlan }
            return run(img, map: map, dirty: [], snapshot: snapshot, now: now, date: date)
        case .complete:
            guard let img = f.image, let map = f.map, map.pixelWidth == img.width, map.pixelHeight == img.height, map.coversDisplay else {
                return cover(because: .badFrameMetadata)
            }
            lastImage = img; lastMap = map
            return run(img, map: map, dirty: f.dirty, snapshot: snapshot, now: now, date: date)
        }
    }

    func origin(of t: JudgeTarget, _ snapshot: WindowSnapshot) -> CGPoint {
        snapshot.bounds(of: t)?.origin ?? display.bounds.origin
    }

    func run(_ img: RGBAImage, map: CaptureMap, dirty: [PixelRect]?, snapshot: WindowSnapshot, now: TimeInterval, date: Date) -> CoverPlan {
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

        // 2. Split by window: one judge call per window (C05-6). Hot windows first.
        var parts = snapshot.split(changed: areas, display: display, ignoring: ignoredPIDs)
        parts.sort { hot.contains($0.target) && !hot.contains($1.target) }

        // 3. Judge and turn classes into covers.
        var fresh: [Held] = []
        for p in parts {
            guard let changedBox = p.changed.boundingBox, let visBox = p.visible.boundingBox,
                  let area = map.toPixels(changedBox.intersection(visBox)) else { continue }
            bucket.refill(now: now)
            // The first judgement after the display was covered whole is not limited by the budget (SD-120).
            let budget = judged ? min(bucket.available, Register.DETECTOR_CALL_CAP) : Register.DETECTOR_CALL_CAP
            let ctx = JudgeContext(windowID: p.target.contextID, startsCovered: false, display: .trusted, isVideo: false, now: date)
            let v = judger.judgeArea(img, context: ctx, within: area, budget: budget)
            if judged { bucket.spend(v.judgements) }
            if v.hot { hot.insert(p.target) } else { hot.remove(p.target) }

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

        // 4. Lifted regions are gone; add the new covers, merging with any they overlap.
        held.removeAll { $0.clean >= Register.VIDEO_VOTE }
        for n in fresh { merge(n) }
        // A window that closed takes its covers with it; nothing of it is on screen any more.
        held.removeAll { visible[$0.target] == nil }

        // 5. Draw: every held region, clipped to where its target is visible; and for a window that just
        //    moved, its old place too, for this update (old and new frames are both covered).
        var items: [CoverItem] = []
        for h in held {
            guard let vis = visible[h.target] else { continue }
            let rects = h.whole ? vis : vis.clipped(to: h.rel.offsetBy(dx: origin(of: h.target, snapshot).x, dy: origin(of: h.target, snapshot).y))
            items += rects.map { CoverItem(rect: CoordinateSpace.snapOutward($0, pointsPerPixel: map.pointsPerPixel), kind: h.kind) }
        }
        for (t, old, _) in moved {
            for h in held where h.target == t {
                let r = (h.whole ? old : h.rel.offsetBy(dx: old.minX, dy: old.minY)).intersection(d)
                if r.hasArea { items.append(CoverItem(rect: CoordinateSpace.snapOutward(r, pointsPerPixel: map.pointsPerPixel), kind: h.kind)) }
            }
        }
        lastBounds = [:]
        for w in snapshot.windows where w.bounds.intersects(d) { lastBounds[.window(number: w.number, ownerPID: w.ownerPID)] = w.bounds }
        lastPlan = CoverPlan(display: display, items: items)
        return lastPlan
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
    /// `cover` covers every picture region the slice touches, or the whole window if it touches none; a
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
                    if touched.isEmpty { out.append(Held(target: target, rel: .null, whole: true, kind: .plain, clean: 0)) }
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
