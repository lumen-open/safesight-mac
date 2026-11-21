// SPDX-License-Identifier: Apache-2.0
// A harmless screen on a slow Mac, as the virtual Mac's fourth live run saw it: the Dock owns a window the size of the
// whole display, in front of every app's window, so everything on screen is judged as the Dock's; the menu bar's clock
// changes every minute; pages are busy. These tests drive the real cover layer with a fake judge that keeps the
// detector's order of work, its costs, its slices and its clean-cache rule (three clearly clean checks in a row before a
// picture is remembered as clean; once borderline, never remembered). Time is simulated; synthetic rectangles only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

/// A fake judge with the detector's order of work and costs, its slices, and its clean-cache rule.
///
/// A call's entries are the pictures inside its area (region pass), the whole pass over the area, and the slices over it
/// (`Detector.slices`). Entries never judged come first (the whole pass right after the first picture), then the ones
/// judged longest ago; an entry is judged only when its whole cost fits what is left of the budget. An entry judged
/// clearly clean `VerdictCache.CLEAN_CHECKS` times in a row is remembered (served free, as a judgement); one judged
/// borderline even once never is (`CLEAN_STICKY`); one judged clean but not remembered is shown as judged earlier when the
/// budget does not reach it; one never judged is left unjudged (`overload`). An entry's identity is its pass, its
/// rectangle and what it shows (`tag`): a change under it makes it a new entry.
final class RuleJudge: Judging {
    /// A picture on screen. `id` is what it shows: the detector's keys are a picture's pixels and size, not its place, so
    /// a picture scrolled elsewhere is the same entry (remembered, or marked, as before). `tag` counts changes to it.
    struct Picture { var rect: PixelRect; var cost: Int; var borderline: Bool; var id = 0; var tag = 0 }
    struct Key: Hashable { var pass: JudgePass; var rect: PixelRect; var tag: Int }
    var pictures: [Picture]
    /// Changed areas so far: a whole pass or slice over any of them shows something else (a new tag).
    var changes: [PixelRect] = []
    /// Whole passes and slices holding a borderline picture are borderline too.
    var bigPassesBorderline = true
    var flagged: Set<Int> = []
    var blindCalls: Int
    var cleanRuns: [Key: Int] = [:]
    var marked: Set<Key> = []
    var seenAt: [Key: Int] = [:]
    var serial = 0
    var msPerJudgement: Double
    var msPerCall: Double
    var clockNs: UInt64 = 1_000_000_000
    var judgements = 0, calls = 0

    init(pictures: [Picture], blindCalls: Int = 2, msPerJudgement: Double = 10, msPerCall: Double = 15) {
        self.pictures = pictures.enumerated().map { i, p in var q = p; if q.id == 0 { q.id = i + 1 }; return q }
        self.blindCalls = blindCalls; self.msPerJudgement = msPerJudgement; self.msPerCall = msPerCall
    }

    /// The content under `r` changed: its pictures and the passes over it become new entries.
    func change(_ r: PixelRect) {
        changes.append(r)
        if changes.count > 64 { changes.removeFirst(changes.count - 64); changeBase += 1 }
        for i in pictures.indices where pictures[i].rect.intersects(r) { pictures[i].tag += 1 }
    }
    var changeBase = 0
    func tag(_ r: PixelRect) -> Int { changeBase * 1000 + changes.filter { $0.intersects(r) }.count }
    func reusable(_ k: Key) -> Bool { !marked.contains(k) && (cleanRuns[k] ?? 0) >= VerdictCache.CLEAN_CHECKS }
    func waiting(_ k: Key) -> Bool { !marked.contains(k) && (cleanRuns[k] ?? 0) > 0 && (cleanRuns[k] ?? 0) < VerdictCache.CLEAN_CHECKS }

    struct Task { var key: Key; var rect: PixelRect; var cost: Int; var borderline: Bool; var flag: Bool }
    func tasks(_ area: PixelRect, _ ctx: JudgeContext) -> [Task] {
        let inside = pictures.filter { $0.rect.intersection(area) == $0.rect }.sorted { $0.rect.shortSide < $1.rect.shortSide }
        var out = inside.map {
            Task(key: Key(pass: .region, rect: PixelRect(x: 0, y: 0, w: $0.rect.w, h: $0.rect.h), tag: $0.id << 16 | $0.tag), rect: $0.rect,
                 cost: $0.cost, borderline: $0.borderline, flag: flagged.contains($0.id))
        }
        func big(_ r: PixelRect) -> Bool { bigPassesBorderline && inside.contains { $0.borderline && $0.rect.intersects(r) } }
        out.append(Task(key: Key(pass: .whole, rect: area, tag: tag(area)), rect: area, cost: 2 * Detector.pieces(area).count, borderline: big(area), flag: false))
        // The virtual Mac's frames are at 2x: the detector's 512-pixel slices are 256 points there.
        for s in Detector.slices(area, size: 256, stride: 192, anchor: ctx.sliceAnchor) {
            out.append(Task(key: Key(pass: .slice, rect: s, tag: tag(s)), rect: s, cost: 2, borderline: big(s), flag: false))
        }
        return out
    }

    /// A call's own cost besides its judgements: `msPerCall`, plus finding pictures and hashing them over its area (a
    /// millisecond per 10,000 points, about what the virtual Mac paid at 2x).
    func callCost(_ area: PixelRect) { clockNs += UInt64((msPerCall + Double(area.w * area.h) / 10_000) * 1_000_000) }

    func run(_ all: [Task], budget: Int, only: ((Task) -> Bool)? = nil) -> FrameVerdict {
        serial += 1; calls += 1
        var verdicts: [RegionVerdict] = []
        var left = budget, spent = 0, nextCost = 0, overloaded = 0
        var cached: [Task] = [], fresh: [Task] = [], again: [Task] = []
        var firstOf: Set<Key> = [], dup: [Task] = []
        for t in all where only?(t) ?? true {
            if only == nil && (reusable(t.key) || (t.flag && marked.contains(t.key))) { cached.append(t); continue }
            if firstOf.contains(t.key) { dup.append(t); continue }
            firstOf.insert(t.key)
            if seenAt[t.key] == nil { fresh.append(t) } else { again.append(t) }
        }
        if let w = fresh.firstIndex(where: { $0.key.pass == .whole }), w > 1 { fresh.insert(fresh.remove(at: w), at: 1) }
        again.sort { seenAt[$0.key]! < seenAt[$1.key]! }
        for t in cached { verdicts.append(RegionVerdict(rect: t.rect, display: t.flag ? .cover : .clear, reason: t.flag ? .bothFamilies : .judgedClean, pass: t.key.pass)) }
        var judged: [Key: Bool] = [:]
        for t in fresh + again {
            if t.cost > left {
                if nextCost == 0 { nextCost = t.cost }
                continue
            }
            left -= t.cost; spent += t.cost
            if t.flag || t.borderline { marked.insert(t.key); cleanRuns[t.key] = 0 } else { cleanRuns[t.key, default: 0] += 1 }
            if !t.flag && !reusable(t.key) { seenAt[t.key] = serial } else { seenAt[t.key] = nil }
            judged[t.key] = t.flag
        }
        for t in fresh + again + dup {
            if let flag = judged[t.key] {
                verdicts.append(RegionVerdict(rect: t.rect, display: flag ? .cover : .clear, reason: flag ? .bothFamilies : .judgedClean, pass: t.key.pass))
            } else if only != nil {
                continue
            } else if seenAt[t.key] != nil {
                verdicts.append(RegionVerdict(rect: t.rect, display: .clear, reason: .judgedEarlier, pass: t.key.pass))
            } else {
                overloaded += 1
                verdicts.append(RegionVerdict(rect: t.rect, display: t.key.pass == .region ? .contain : .cover, reason: .overload, pass: t.key.pass))
            }
        }
        clockNs += UInt64(Double(spent) * msPerJudgement * 1_000_000)
        judgements += spent
        verdicts.sort { ($0.pass == .whole ? 0 : 1) < ($1.pass == .whole ? 0 : 1) }
        let w = Set(all.map(\.key).filter(waiting)).count
        return FrameVerdict(regions: verdicts, coverWindow: false, strike: false, hot: false, judgements: spent, overloaded: overloaded,
                            nextCost: nextCost, secondChecksLeft: w)
    }

    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        let all = tasks(area, context)
        callCost(area)
        if blindCalls > 0 {
            blindCalls -= 1; serial += 1; calls += 1
            let out = all.map { RegionVerdict(rect: $0.rect, display: $0.key.pass == .region ? .contain : .cover, reason: .overload, pass: $0.key.pass) }
            return FrameVerdict(regions: out, coverWindow: false, strike: false, hot: false, judgements: 0, overloaded: out.count)
        }
        return run(all, budget: budget)
    }

    func checkAgainInBackground(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict? {
        callCost(area)
        return run(tasks(area, context), budget: budget, only: { self.waiting($0.key) })
    }

    func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]? {
        pictures.filter { $0.rect.intersects(area) }.map(\.rect)
    }
    func setRule(_ rule: DetectorRule) {}
}

/// Drives a pipeline as the app does on the virtual Mac: the capture sends a frame about 30 times a second even when
/// nothing changed (a "nothing changed" frame), each is judged in turn, one at a time, and a look that takes longer than
/// a frame's interval holds the next frame back. Time and CPU are the fake judge's clock.
struct ScreenSim {
    let d: DisplayDescriptor
    let p: DisplayPipeline
    let judge: RuleJudge
    var img: RGBAImage
    var snap: WindowSnapshot
    var t = 0.0
    var plans: [(t: Double, plan: CoverPlan)] = []
    var looks = 0
    /// Covers the last plan drew that an early plan of the next look left out: (time, the cover's rectangle).
    var earlyDropped: [(t: Double, rect: CGRect)] = []
    /// Frames a second the capture sends while nothing changes.
    var fps = 30.0

    init(display: DisplayDescriptor, judge: RuleJudge, windows: [WindowInfo], callWallMs: Double = 250) {
        d = display; self.judge = judge
        img = Fixtures.blank(Int(display.bounds.width), Int(display.bounds.height))
        snap = WindowSnapshot(windows: windows, time: 0)
        p = DisplayPipeline(display: display, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: callWallMs)
        p.clock = { [unowned judge] in judge.clockNs }
        // The app's pace for looks at a still screen, at full power.
        p.stillLookPace = (Register.TICK, EnergyMode.full.lookEvery)
    }

    var cpuMs: Double { Double(judge.clockNs - 1_000_000_000) / 1_000_000 }

    mutating func frame(changed: [PixelRect]?) {
        let before = judge.clockNs
        let f: CapturedFrame
        if let changed {
            f = Fixtures.frame(img, display: d, scale: 1, dirty: changed, t: t)
        } else {
            f = CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t)
        }
        var early: [CoverPlan] = []
        let plan = p.process(f, snapshot: snap, now: t, provisional: { early.append($0) })
        if judge.clockNs != before { looks += 1 }
        // Every plan drawn before the final one holds everything the last plan drawn covered (an early plan may only add).
        if let last = plans.last?.plan {
            for e in early where e.wholeDisplay == nil {
                if last.wholeDisplay != nil { earlyDropped.append((t, d.bounds)); continue }
                for item in last.items where !Self.coarselyCovered(item.rect, by: e.items) {
                    earlyDropped.append((t, item.rect))
                }
            }
        }
        plans.append((t, plan))
        t += max(1 / fps, Double(judge.clockNs - before) / 1e9)
    }

    /// The first frame: complete, the whole frame new.
    mutating func full() {
        let before = judge.clockNs
        plans.append((t, p.process(Fixtures.frame(img, display: d, scale: 1, dirty: nil, t: t), snapshot: snap, now: t)))
        t += max(1 / fps, Double(judge.clockNs - before) / 1e9)
    }

    /// Paints a change at `r` (frame pixels) and sends the frame that shows it.
    mutating func change(_ r: PixelRect, value: UInt8? = nil) {
        let v = value ?? UInt8(judge.changes.count % 200 + 20)
        for y in r.y..<r.maxY { for x in r.x..<r.maxX { img.pixels[(y * img.width + x) * 4] = v } }
        judge.change(r)
        frame(changed: [r])
    }

    /// A page in a window (frame pixels of the window's content area, `viewport`), scrolled by `offset` rows: its
    /// pictures (page coordinates) are on screen where they are wholly inside the viewport.
    var page: RGBAImage?
    var viewport = PixelRect(x: 0, y: 0, w: 0, h: 0)
    var pagePictures: [RuleJudge.Picture] = []
    var basePictures: [RuleJudge.Picture] = []
    var offset = 0

    /// Draws the page at `offset` into the frame and tells the judge which of its pictures show.
    mutating func drawPage() {
        guard let pg = page else { return }
        for y in 0..<viewport.h {
            let src = ((offset + y) * pg.width) * 4, dst = ((viewport.y + y) * img.width + viewport.x) * 4
            img.pixels.replaceSubrange(dst..<(dst + viewport.w * 4), with: pg.pixels[src..<(src + viewport.w * 4)])
        }
        let shown = pagePictures.compactMap { q -> RuleJudge.Picture? in
            var r = q; r.rect = PixelRect(x: q.rect.x + viewport.x, y: q.rect.y - offset + viewport.y, w: q.rect.w, h: q.rect.h)
            return r.rect.intersection(viewport) == r.rect ? r : nil
        }
        judge.change(viewport)
        judge.pictures = basePictures + shown
    }

    /// Opens the page (or scrolls it by `dy` rows) and sends the frame that shows it.
    mutating func scroll(by dy: Int) {
        offset += dy
        drawPage()
        frame(changed: [viewport])
    }

    /// The menu bar's clock, changing every `clockEvery` seconds (nil: never).
    var clock: PixelRect?
    var clockEvery: Double? = 60
    var nextClock = 60.0
    var clockTicks = 0

    /// One frame: the clock's change when it is due, else a "nothing changed" frame.
    mutating func step() {
        if let c = clock, let every = clockEvery, t >= nextClock {
            nextClock += every; clockTicks += 1
            change(c)
        } else {
            frame(changed: nil)
        }
    }

    /// Frames until `until`.
    mutating func still(until: Double) { while t < until { step() } }

    /// Frames until nothing is drawn and no look is wanted (or `limit`); returns when that was, if it was.
    mutating func settle(limit: Double) -> Double? {
        while t < limit {
            step()
            if drawsNothing(plans.last!.plan) && !p.needsAnotherLook { return t }
        }
        return nil
    }

    /// Whether `r` is under the union of `items`, checked at points 4 apart (and at its corners, just inside).
    static func coarselyCovered(_ r: CGRect, by items: [CoverItem]) -> Bool {
        if items.contains(where: { $0.rect.insetBy(dx: -0.5, dy: -0.5).contains(r) }) { return true }
        let near = items.filter { $0.rect.intersects(r) }
        var y = r.minY + 0.5
        while y < r.maxY {
            var x = r.minX + 0.5
            while x < r.maxX {
                if !near.contains(where: { $0.rect.contains(CGPoint(x: x, y: y)) }) { return false }
                x = x + 4 < r.maxX ? x + 4 : (x < r.maxX - 0.5 ? r.maxX - 0.5 : r.maxX)
            }
            y = y + 4 < r.maxY ? y + 4 : (y < r.maxY - 0.5 ? r.maxY - 0.5 : r.maxY)
        }
        return true
    }

    func drawsNothing(_ plan: CoverPlan) -> Bool { plan.wholeDisplay == nil && plan.items.isEmpty }

    /// The largest area (points squared) covered by one item, or the display's, in plans from `from`.
    func largestCover(from: Double) -> CGFloat {
        plans.filter { $0.t >= from }.map { e in
            e.plan.wholeDisplay != nil ? d.bounds.width * d.bounds.height : (e.plan.items.map { $0.rect.width * $0.rect.height }.max() ?? 0)
        }.max() ?? 0
    }
}

@Suite struct UsableCoversTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))

    /// The virtual Mac's window list (run 4): the menu bar's items and the menu bar, then the Dock's window the size of the
    /// display (level 20, in front of every app), a Finder window, the desktop picture.
    var vmWindows: [WindowInfo] {
        [WindowInfo(number: 30, ownerPID: 406, layer: 25, bounds: CGRect(x: 878, y: 0, width: 146, height: 30)),
         WindowInfo(number: 31, ownerPID: 170, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1024, height: 30)),
         WindowInfo(number: 40, ownerPID: 860, layer: 20, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768)),
         WindowInfo(number: 50, ownerPID: 408, layer: 0, bounds: CGRect(x: 52, y: 91, width: 920, height: 436)),
         WindowInfo(number: 60, ownerPID: 415, layer: -2147483625, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))]
    }

    /// The menu bar's clock (inside the menu bar items' window).
    let clock = PixelRect(x: 960, y: 6, w: 56, h: 18)
    /// A spot on the Dock's edge that changes once (an icon's highlight).
    let dockSpot = PixelRect(x: 196, y: 700, w: 24, h: 24)

    /// A still desktop: Dock icons, desktop icons, a Finder window's icons and lines of text, menu bar items, the clock.
    /// Every third picture is borderline (never remembered as clean).
    func desktopPictures() -> [RuleJudge.Picture] {
        var rects: [PixelRect] = []
        for k in 0..<12 { rects.append(PixelRect(x: 200 + 56 * k, y: 706, w: 48, h: 48)) }
        for k in 0..<4 { rects.append(PixelRect(x: 950, y: 40 + 90 * k, w: 64, h: 64)) }
        for r in 0..<4 { for c in 0..<8 { rects.append(PixelRect(x: 80 + 110 * c, y: 110 + 90 * r, w: 48, h: 48)) } }
        for r in 0..<4 { for c in 0..<8 { rects.append(PixelRect(x: 70 + 110 * c, y: 162 + 90 * r, w: 70, h: 12)) } }
        for k in 0..<8 { rects.append(PixelRect(x: 12 + 60 * k, y: 6, w: 40, h: 18)) }
        rects.append(clock)
        return rects.enumerated().map { i, r in
            .init(rect: r, cost: 2 * Detector.pieces(r).count, borderline: i % 3 == 1)
        }
    }

    /// Finding A: the still desktop under the Dock's display-sized window settles within a minute, and after its first five
    /// seconds (whose looks leave much of it for later, blurred) nothing is covered larger than a quarter of the display (on main the window was covered whole after half a second of
    /// slowness, and that cover held the display until everything on it had four clean rounds: 95 s here, 8.8 minutes on
    /// the virtual Mac).
    @Test func aStillDesktopUnderTheDocksDisplaySizedWindowSettles() {
        var sim = ScreenSim(display: d, judge: RuleJudge(pictures: desktopPictures(), blindCalls: 0, msPerJudgement: 15, msPerCall: 4), windows: vmWindows)
        sim.clock = clock
        sim.full()
        let settled = sim.settle(limit: 900)
        print("A settle: \(settled.map { String(format: "%.1f s", $0) } ?? "never") cpu \(Int(sim.cpuMs)) ms looks \(sim.looks) largest after 5 s \(sim.largestCover(from: 5))")
        #expect(settled != nil && settled! <= 60, "the still desktop settles within a minute: \(settled.map { "\($0) s" } ?? "never"); held \(sim.p.heldLines.prefix(8))")
        #expect(sim.largestCover(from: 5) < d.bounds.width * d.bounds.height / 4, "after the first looks, nothing covered larger than a quarter of the display: \(sim.largestCover(from: 5))")
        #expect(sim.earlyDropped.isEmpty, "no early plan dropped a cover: \(sim.earlyDropped.prefix(3))")
    }

    /// Finding A, the small change: one spot at the Dock's edge changes while the Mac is busy (the bucket empty, so it is
    /// left unjudged past `TIME_TO_COVER`). It is covered plainly, at its own size; the rest of the display, judged and
    /// unchanged, stays in sight; once judging catches up it lifts. On main the Dock's window, the whole display, was
    /// covered whole.
    @Test func aSmallChangeLeftUnjudgedIsCoveredAtItsOwnSize() {
        var sim = ScreenSim(display: d, judge: RuleJudge(pictures: desktopPictures(), blindCalls: 0, msPerJudgement: 15, msPerCall: 4), windows: vmWindows)
        sim.clock = clock
        sim.full()
        #expect(sim.settle(limit: 300) != nil)
        sim.p.setBudgetShare(0); sim.p.bucket.spend(Int(Register.JUDGEMENT_BURST))
        let at = sim.t
        sim.change(dockSpot)
        sim.still(until: at + 2)
        let plan = sim.plans.last!.plan
        let spot = CGRect(x: dockSpot.x, y: dockSpot.y, width: dockSpot.w, height: dockSpot.h)
        #expect(plan.covers(spot, kind: .plain), "the change, unjudged past TIME_TO_COVER, is covered plainly")
        #expect(!plan.touches(CGRect(x: 300, y: 300, width: 300, height: 200)), "the rest of the display, judged and unchanged, is in sight")
        #expect(sim.largestCover(from: at) <= 64 * 64 * 2, "covered about its own size: \(sim.largestCover(from: at)) points squared")
        sim.p.setBudgetShare(Register.JUDGEMENT_BUDGET)
        let again = sim.settle(limit: at + 120)
        print("A dock spot: settled \(again.map { String(format: "%.1f s", $0 - at) } ?? "never") after the change")
        #expect(again != nil && again! - at <= 30, "and lifts once judging catches up: \(again.map { "\($0 - at) s" } ?? "never")")
    }

    /// The capture sends "nothing changed" frames about 30 times a second in the virtual Mac. With covers waiting to lift,
    /// each was a look (on main about 24 a second here, and about 10 a second, each up to the time limit, in the virtual Mac): now
    /// the looks keep the app's pace, one a second while only covers wait, one a tick while work is left over.
    @Test func nothingChangedFramesAreLookedAtOnlyAtTheAppsPace() {
        let pics = desktopPictures()
        let judge = RuleJudge(pictures: pics, blindCalls: 0, msPerJudgement: 15, msPerCall: 4)
        judge.flagged = [judge.pictures[20].id]   // a picture that stays covered: the looks go on
        var sim = ScreenSim(display: d, judge: judge, windows: vmWindows)
        sim.clockEvery = nil
        sim.full()
        sim.still(until: 120)
        #expect(sim.p.needsAnotherLook && !sim.p.hasLeftOverWork, "only the flagged cover waits")
        let looks0 = sim.p.runSerial, cpu0 = sim.cpuMs
        sim.still(until: 180)
        let perSecond = Double(sim.p.runSerial - looks0) / 60
        print("pace: \(String(format: "%.2f", perSecond)) looks a second, cpu \(Int(sim.cpuMs - cpu0)) ms a minute")
        #expect(perSecond <= 1.5, "about one look a second while only covers wait (one a tick for the full re-judge's left-over checks): \(perSecond)")
        let r = pics[20].rect
        #expect(sim.plans.last!.plan.covers(CGRect(x: r.x, y: r.y, width: r.w, height: r.h), kind: .plain), "the flagged picture stays covered")
    }

    /// The menu bar's clock changes once a minute on a settled desktop. Judging that small change, and giving it its
    /// clean checks, takes a handful of looks and a fraction of a second of CPU: not a look at every frame the capture
    /// sends, and not a background check of the whole display at each look.
    @Test func theClocksChangeEachMinuteCostsLittle() {
        var sim = ScreenSim(display: d, judge: RuleJudge(pictures: desktopPictures(), blindCalls: 0, msPerJudgement: 15, msPerCall: 4), windows: vmWindows)
        sim.clock = clock
        sim.full()
        #expect(sim.settle(limit: 600) != nil)
        sim.clockEvery = nil
        sim.still(until: sim.t + 5)
        let at = sim.t, cpu0 = sim.cpuMs, looks0 = sim.looks, frames0 = sim.plans.count
        sim.change(clock)
        let settled = sim.settle(limit: at + 120)
        let cpu = sim.cpuMs - cpu0, looks = sim.looks - looks0
        print("clock: settled after \(settled.map { String(format: "%.1f s", $0 - at) } ?? "never"), \(looks) looks of \(sim.plans.count - frames0) frames, cpu \(Int(cpu)) ms")
        #expect(settled != nil && settled! - at <= Register.FULL_REJUDGE_SHOW_FIRST + 2, "settles again: \(settled.map { "\($0 - at) s" } ?? "never")")
        #expect(looks <= 40, "a handful of looks, not one a frame: \(looks)")
        #expect(cpu <= 1500, "well under two seconds of CPU: \(Int(cpu)) ms")
    }

    // MARK: Finding B: a busy harmless page

    var safariWindows: [WindowInfo] {
        [WindowInfo(number: 30, ownerPID: 406, layer: 25, bounds: CGRect(x: 878, y: 0, width: 146, height: 30)),
         WindowInfo(number: 31, ownerPID: 170, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1024, height: 30)),
         WindowInfo(number: 40, ownerPID: 860, layer: 20, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768)),
         WindowInfo(number: 70, ownerPID: 23611, layer: 0, bounds: CGRect(x: 0, y: 30, width: 1024, height: 678)),
         WindowInfo(number: 60, ownerPID: 415, layer: -2147483625, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))]
    }
    let pageView = PixelRect(x: 0, y: 108, w: 1024, h: 600)
    let dockStrip = CGRect(x: 0, y: 712, width: 1024, height: 56)

    /// The Dock's icons, the menu bar's items and the clock.
    func barPictures() -> [RuleJudge.Picture] {
        var rects: [PixelRect] = []
        for k in 0..<12 { rects.append(PixelRect(x: 200 + 56 * k, y: 714, w: 48, h: 48)) }
        for k in 0..<8 { rects.append(PixelRect(x: 12 + 60 * k, y: 6, w: 40, h: 18)) }
        rects.append(clock)
        return rects.enumerated().map { i, r in .init(rect: r, cost: 2 * Detector.pieces(r).count, borderline: i % 3 == 1, id: 1000 + i) }
    }

    /// A long page of thumbnails with two lines of text under each row; `borderlineEvery`: every so many thumbnails is
    /// borderline (never remembered as clean).
    func pagePictures(borderlineEvery: Int = 3) -> [RuleJudge.Picture] {
        var out: [RuleJudge.Picture] = []
        for r in 0..<16 { for c in 0..<5 {
            let rect = PixelRect(x: 40 + 200 * c, y: 40 + 180 * r, w: 160, h: 120)
            out.append(.init(rect: rect, cost: 2 * Detector.pieces(rect).count, borderline: (r * 5 + c) % borderlineEvery == 1, id: 2000 + r * 5 + c))
        } }
        for r in 0..<16 { for k in 0..<2 {
            let rect = PixelRect(x: 40 + 500 * k, y: 166 + 180 * r, w: 300, h: 14)
            out.append(.init(rect: rect, cost: 2 * Detector.pieces(rect).count, borderline: false, id: 3000 + r * 2 + k))
        } }
        return out
    }

    func pageSim() -> ScreenSim {
        var sim = ScreenSim(display: d, judge: RuleJudge(pictures: barPictures(), msPerJudgement: 15, msPerCall: 4), windows: safariWindows)
        sim.clock = clock
        var page = Fixtures.blank(1024, 3000)
        Fixtures.paint(&page, PixelRect(x: 0, y: 0, w: 1024, h: 3000), channel: nil, seed: 7)
        sim.page = page; sim.viewport = pageView; sim.pagePictures = pagePictures(); sim.basePictures = barPictures()
        return sim
    }

    /// Finding B: a busy harmless page, opened and scrolled for a minute, then still. Every plan drawn early in a look holds
    /// everything the last plan drew, and once the scrolling stops the screen settles to nothing in bounded time.
    @Test func aBusyPageScrolledThenStillSettles() {
        var sim = pageSim()
        sim.full()
        let first = sim.settle(limit: 400)
        #expect(first != nil, "the empty window settles first; held \(sim.p.heldLines.prefix(6))")
        let open = sim.t
        sim.scroll(by: 0)
        var dir = 8
        while sim.t < open + 60 {
            if sim.offset + dir > 3000 - pageView.h || sim.offset + dir < 0 { dir = -dir }
            sim.scroll(by: dir)
        }
        let stop = sim.t, cpuAtStop = sim.cpuMs
        let settled = sim.settle(limit: stop + 900)
        let after = sim.plans.filter { $0.t >= open }
        let barsCovered = after.filter { e in e.plan.wholeDisplay != nil || e.plan.items.contains { $0.rect.intersects(dockStrip) } }.count
        let largest = sim.largestCover(from: open)
        print("B early plans dropping covers: \(sim.earlyDropped.count), e.g. \(sim.earlyDropped.prefix(25).map { "\(Int($0.t * 100))@\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width)),\(Int($0.rect.height))" })")
        print("B page: settled \(settled.map { String(format: "%.1f s after the scrolling stopped", $0 - stop) } ?? "never"), cpu while settling \(Int(sim.cpuMs - cpuAtStop)) ms over \(Int(sim.t - stop)) s, largest cover \(largest), plans hiding the Dock \(barsCovered) of \(after.count); held \(sim.p.heldLines.prefix(4))")
        #expect(settled != nil && settled! - stop <= 100, "settles within 100 s of the scrolling stopping: \(settled.map { "\($0 - stop) s" } ?? "never"); held \(sim.p.heldLines.prefix(6))")
        #expect(sim.earlyDropped.isEmpty, "no early plan dropped a cover the last plan drew: \(sim.earlyDropped.count), e.g. \(sim.earlyDropped.prefix(3))")
    }

    // MARK: Covers that follow scrolled content

    /// A cover near the bottom of a scrolling area whose content did not simply move: its new place is covered too, but
    /// only within what changed. On main the copy reached past the scrolled area into a strip that never changed, and was
    /// merged with the cover it came from into one larger cover; frame by frame of scrolling such covers grew to the whole
    /// window (the virtual Mac's busy page: a plain cover of 1024 by 732 points that never lifted).
    @Test func aCoverFollowingScrolledContentStaysInWhatChanged() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let scrolled = PixelRect(x: 0, y: 0, w: 600, h: 300)
        let judge = ScriptedJudge { area in VerdictScript.clean(area) }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        var page = Fixtures.blank(600, 1000)
        Fixtures.paint(&page, PixelRect(x: 0, y: 0, w: 600, h: 1000), channel: nil, seed: 11)
        func frame(offset: Int) -> RGBAImage {
            var img = Fixtures.blank(600, 400)
            for y in 0..<scrolled.h {
                let src = ((offset + y) * 600) * 4, dst = (y * 600) * 4
                img.pixels.replaceSubrange(dst..<(dst + 600 * 4), with: page.pixels[src..<(src + 600 * 4)])
            }
            return img
        }
        _ = p.process(Fixtures.frame(frame(offset: 200), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let t = JudgeTarget.window(number: 10, ownerPID: 500)
        // A cover over a picture near the bottom of the scrolled area (as a flag would leave it).
        p.held = [DisplayPipeline.Held(target: t, rel: CGRect(x: 100, y: 250, width: 100, height: 40), whole: false, kind: .plain, clean: 0)]
        // The content moves down by 20 rows: the cover's content would go past the scrolled area's bottom edge.
        let plan = p.process(Fixtures.frame(frame(offset: 180), display: d, scale: 1, dirty: [scrolled], t: 0.1), snapshot: snap, now: 0.1)
        #expect(plan.covers(CGRect(x: 100, y: 250, width: 100, height: 40)), "the cover stays (its place changed and is judged again)")
        #expect(plan.covers(CGRect(x: 100, y: 270, width: 100, height: 30)), "where its content went, inside what changed, is covered too")
        // (What changed is read in blocks: 304 rows. A cover moving with content also reaches ahead of it for one update.)
        #expect(p.held.allSatisfy { $0.rel.maxY <= 304.5 }, "no cover held past what changed: \(p.heldLines)")
        let next = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0.2), snapshot: snap, now: 0.2)
        #expect(!next.touches(CGRect(x: 0, y: 305, width: 600, height: 95)), "nothing below the scrolled area, which never changed, stays covered")
    }

    /// A page of texture, `offset` rows scrolled, in the top 300 rows of a 600 by 400 frame.
    static func scrolledFrame(_ page: RGBAImage, offset: Int) -> RGBAImage {
        var img = Fixtures.blank(600, 400)
        for y in 0..<300 {
            let src = ((offset + y) * 600) * 4, dst = (y * 600) * 4
            img.pixels.replaceSubrange(dst..<(dst + 600 * 4), with: page.pixels[src..<(src + 600 * 4)])
        }
        return img
    }

    static func texturedPage() -> RGBAImage {
        var page = Fixtures.blank(600, 1000)
        Fixtures.paint(&page, PixelRect(x: 0, y: 0, w: 600, h: 1000), channel: nil, seed: 11)
        return page
    }

    /// A judge that judges nothing again (every entry shown as judged earlier), so no cover lifts and none is added.
    static func stillJudge() -> VerdictScript {
        VerdictScript { area in
            FrameVerdict(regions: [RegionVerdict(rect: area, display: .clear, reason: .judgedEarlier, pass: .whole)],
                         coverWindow: false, strike: false, hot: false, judgements: 0, overloaded: 0)
        }
    }

    /// Where a scrolled cover's content went (when it did not simply move with the page) is covered in the final plan too,
    /// and stays held, not only in the early plans of that look.
    @Test func whereAScrolledCoversContentWentIsCoveredInTheFinalPlan() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let p = DisplayPipeline(display: d, judger: Self.stillJudge(), budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        let page = Self.texturedPage()
        _ = p.process(Fixtures.frame(Self.scrolledFrame(page, offset: 200), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        p.held = [DisplayPipeline.Held(target: .window(number: 10, ownerPID: 500), rel: CGRect(x: 100, y: 100, width: 100, height: 40), whole: false, kind: .plain, clean: 0)]
        var img = Self.scrolledFrame(page, offset: 180)
        Fixtures.paint(&img, PixelRect(x: 100, y: 120, w: 100, h: 40), channel: nil, seed: 99)   // not simply moved
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 0, y: 0, w: 600, h: 300)], t: 0.1), snapshot: snap, now: 0.1)
        let later = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0.2), snapshot: snap, now: 0.2)
        #expect(later.covers(CGRect(x: 100, y: 120, width: 100, height: 40)), "where the content went is covered in a later final plan: \(p.heldLines)")
        #expect(later.covers(CGRect(x: 100, y: 100, width: 100, height: 40)), "and the old place")
    }

    /// A copy is cut to what changed, but where pixels changed outside the area the frame reported, it is kept there too.
    @Test func aScrolledCoversCopyIsKeptWherePixelsChangedOutsideWhatWasReported() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let p = DisplayPipeline(display: d, judger: Self.stillJudge(), budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        let page = Self.texturedPage()
        _ = p.process(Fixtures.frame(Self.scrolledFrame(page, offset: 200), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        p.held = [DisplayPipeline.Held(target: .window(number: 10, ownerPID: 500), rel: CGRect(x: 100, y: 250, width: 100, height: 40), whole: false, kind: .plain, clean: 0)]
        var img = Self.scrolledFrame(page, offset: 180)
        Fixtures.paint(&img, PixelRect(x: 0, y: 300, w: 600, h: 30), channel: nil, seed: 5)   // changed, but not reported
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 0, y: 0, w: 600, h: 300)], t: 0.1), snapshot: snap, now: 0.1)
        let later = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0.2), snapshot: snap, now: 0.2)
        #expect(later.covers(CGRect(x: 100, y: 270, width: 100, height: 40)), "the copy reaches into changed pixels the frame did not report: \(p.heldLines)")
    }

    // MARK: Covers counted by a larger cover's call

    /// Clean, with a region entry (a picture judged at its own size) for each of `pictures` inside the call.
    static func cleanWith(_ pictures: [PixelRect]) -> VerdictScript {
        VerdictScript { area in
            var v = VerdictScript.clean(area)
            v.regions += pictures.filter { area.intersection($0) == $0 }.map { RegionVerdict(rect: $0, display: .clear, reason: .judgedClean, pass: .region) }
            return v
        }
    }

    /// A judge that flags only when it looks closely (a call no bigger than 120 points a side): a picture seen as explicit at
    /// its own size and clean in a call over a much larger area.
    static func zoomJudge() -> VerdictScript {
        VerdictScript { area in
            if area.w <= 120 && area.h <= 120 {
                return FrameVerdict(regions: [RegionVerdict(rect: area, display: .cover, reason: .bothFamilies, pass: .whole)],
                                    coverWindow: false, strike: false, hot: false, judgements: 2, overloaded: 0)
            }
            return VerdictScript.clean(area)
        }
    }

    func zoomRun(innerFromOverload: Bool, regionSeenInLargerCall: Bool = false) -> (CoverPlan, DisplayPipeline) {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let inner = PixelRect(x: 150, y: 150, w: 100, h: 100)
        let zoom = Self.zoomJudge()
        let judge = regionSeenInLargerCall ? VerdictScript { area in
            var v = zoom.answer(area)
            if area.w > 120, area.intersection(inner) == inner { v.regions.append(RegionVerdict(rect: inner, display: .clear, reason: .judgedClean, pass: .region)) }
            return v
        } : zoom
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let t = JudgeTarget.window(number: 10, ownerPID: 500)
        p.held = [DisplayPipeline.Held(target: t, rel: CGRect(x: 50, y: 50, width: 400, height: 300), whole: false, kind: .plain, clean: 0, fromOverload: true),
                  DisplayPipeline.Held(target: t, rel: CGRect(x: 150, y: 150, width: 100, height: 100), whole: false, kind: .plain, clean: 0, fromOverload: innerFromOverload)]
        var plan = p.lastPlan
        for k in 0..<12 {
            let tt = 0.1 + Double(k)
            plan = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: tt), snapshot: snap, now: tt)
        }
        return (plan, p)
    }

    /// A flagged picture's cover inside a larger cover of the same window is still judged at its own size at every round:
    /// it stays covered, and so does the larger one, whose count its flag starts again.
    @Test func aFlaggedCoverInsideALargerOneIsJudgedAtItsOwnSize() {
        let (plan, p) = zoomRun(innerFromOverload: false)
        #expect(plan.covers(CGRect(x: 150, y: 150, width: 100, height: 100), kind: .plain), "the picture flagged up close stays covered: \(p.heldLines)")
    }

    /// Even when the larger call judged a picture exactly there, a cover once flagged is judged at its own size every round.
    @Test func aFlaggedCoverIsJudgedAtItsOwnSizeEvenWhenALargerCallSawItsPicture() {
        let (plan, p) = zoomRun(innerFromOverload: false, regionSeenInLargerCall: true)
        #expect(plan.covers(CGRect(x: 150, y: 150, width: 100, height: 100), kind: .plain), "\(p.heldLines)")
    }

    /// The same for a cover made for entries left unjudged that its own call then finds flagged: from then on it is judged
    /// at its own size too.
    @Test func aCoverForUnjudgedEntriesOnceFlaggedIsJudgedAtItsOwnSize() {
        let (plan, p) = zoomRun(innerFromOverload: true)
        #expect(plan.covers(CGRect(x: 150, y: 150, width: 100, height: 100), kind: .plain), "flagged once, judged up close from then on: \(p.heldLines)")
    }

    /// Two larger covers that both hold a cover for unjudged entries: the second's call does not count it again in the same
    /// look (one clean judgement a look, at most).
    @Test func aCoverInsideTwoLargerOnesIsCountedOnceALook() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let p = DisplayPipeline(display: d, judger: Self.cleanWith([PixelRect(x: 150, y: 150, w: 100, h: 100)]), budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let t = JudgeTarget.window(number: 10, ownerPID: 500)
        p.held = [DisplayPipeline.Held(target: t, rel: CGRect(x: 0, y: 0, width: 300, height: 300), whole: false, kind: .plain, clean: 0, fromOverload: true),
                  DisplayPipeline.Held(target: t, rel: CGRect(x: 100, y: 100, width: 300, height: 290), whole: false, kind: .plain, clean: 0, fromOverload: true),
                  DisplayPipeline.Held(target: t, rel: CGRect(x: 150, y: 150, width: 100, height: 100), whole: false, kind: .plain, clean: 0, fromOverload: true)]
        _ = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0.1), snapshot: snap, now: 0.1)
        let inner = p.held.first { $0.rel == CGRect(x: 150, y: 150, width: 100, height: 100) }
        #expect(inner?.clean == 1, "one clean judgement in one look: \(p.heldLines)")
    }

    /// A cover only partly inside a larger one is never counted by the larger one's call: the part outside is not in it.
    @Test func aCoverPartlyInsideALargerOneIsNotCountedByItsCall() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let outside = PixelRect(x: 301, y: 0, w: 299, h: 400)
        // Anything reaching past x = 300 is left unjudged; the rest is clean, with the picture that the partly inside
        // cover stands over seen in part, at its own size, where it is inside.
        let seen = PixelRect(x: 250, y: 100, w: 50, h: 100)
        var ready = false
        let judge = VerdictScript { area in
            if ready && area.intersects(outside) {
                return FrameVerdict(regions: [RegionVerdict(rect: area, display: .cover, reason: .overload, pass: .whole)],
                                    coverWindow: false, strike: false, hot: false, judgements: 0, overloaded: 1)
            }
            var v = VerdictScript.clean(area)
            if area.intersection(seen) == seen { v.regions.append(RegionVerdict(rect: PixelRect(x: 250, y: 100, w: 100, h: 100), display: .clear, reason: .judgedClean, pass: .region)) }
            return v
        }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        let t = JudgeTarget.window(number: 10, ownerPID: 500)
        p.held = [DisplayPipeline.Held(target: t, rel: CGRect(x: 0, y: 0, width: 300, height: 300), whole: false, kind: .plain, clean: 0, fromOverload: true),
                  DisplayPipeline.Held(target: t, rel: CGRect(x: 250, y: 100, width: 100, height: 100), whole: false, kind: .plain, clean: 0, fromOverload: true)]
        ready = true
        var plan = p.lastPlan
        for k in 0..<12 {
            let tt = 0.1 + Double(k)
            plan = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: tt), snapshot: snap, now: tt)
        }
        #expect(plan.covers(CGRect(x: 250, y: 100, width: 100, height: 100)), "never lifted on a call that did not hold all of it: \(p.heldLines)")
        #expect(p.held.first { $0.rel == CGRect(x: 250, y: 100, width: 100, height: 100) }?.clean == 0, "and never counted by one: \(p.heldLines)")
    }

    // MARK: Counts that must start again

    /// A cover's copy joining a cover that already holds it starts that cover's count again: it hides something new.
    @Test func aCopyJoiningACoverStartsItsCountAgain() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let p = DisplayPipeline(display: d, judger: VerdictScript { VerdictScript.clean($0) }, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let t = JudgeTarget.window(number: 10, ownerPID: 500)
        p.held = [DisplayPipeline.Held(target: t, rel: CGRect(x: 0, y: 0, width: 300, height: 300), whole: false, kind: .plain, clean: 3)]
        var copy = DisplayPipeline.Held(target: t, rel: CGRect(x: 50, y: 50, width: 100, height: 40), whole: false, kind: .plain, clean: 0)
        copy.fromMotion = true
        p.merge(copy)
        #expect(p.held.count == 1 && p.held[0].clean == 0, "\(p.heldLines)")
    }

    /// A window moves and, at the same time, what one of its covers hides changes: the cover's count starts again. When the
    /// content only moved with the window, the count stands.
    func moveWindow(changeUnderCover: Bool) -> Int {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let p = DisplayPipeline(display: d, judger: Self.stillJudge(), budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let content = Self.texturedPage()
        func frame(windowX: Int) -> RGBAImage {
            var img = Fixtures.blank(600, 400)
            for y in 0..<300 {
                let src = (y * 600) * 4, dst = (y * 600 + windowX) * 4
                img.pixels.replaceSubrange(dst..<(dst + 300 * 4), with: content.pixels[src..<(src + 300 * 4)])
            }
            return img
        }
        func snap(_ x: CGFloat) -> WindowSnapshot { WindowSnapshot(windows: [WindowInfo(number: 10, ownerPID: 500, layer: 0, bounds: CGRect(x: x, y: 0, width: 300, height: 300))], time: 0) }
        _ = p.process(Fixtures.frame(frame(windowX: 0), display: d, scale: 1, t: 0), snapshot: snap(0), now: 0)
        p.held = [DisplayPipeline.Held(target: .window(number: 10, ownerPID: 500), rel: CGRect(x: 100, y: 100, width: 80, height: 80), whole: false, kind: .plain, clean: 3)]
        var moved = frame(windowX: 50)
        if changeUnderCover { Fixtures.paint(&moved, PixelRect(x: 160, y: 120, w: 40, h: 40), channel: nil, seed: 3) }
        _ = p.process(Fixtures.frame(moved, display: d, scale: 1, dirty: [PixelRect(x: 0, y: 0, w: 352, h: 304)], t: 0.1), snapshot: snap(50), now: 0.1)
        return p.held.first?.clean ?? -1
    }

    @Test func aChangeUnderACoverWhileItsWindowMovesStartsItsCountAgain() {
        #expect(moveWindow(changeUnderCover: true) == 0, "changed while moving: the count starts again")
        #expect(moveWindow(changeUnderCover: false) == 3, "only moved: the count stands")
    }

    // MARK: Early plans and the password prompt's hole

    /// An early plan holds everything the last plan drew, but never a hole the prompt no longer has: when the prompt moves,
    /// every early plan of that look, and the final plan, cover where it is now and leave no hole open.
    @Test func earlyPlansNeverKeepAPromptsHoleOpen() {
        let t = PasswordPromptTests()
        let p = t.pipeline()
        let first = t.coveredBehind(p, [t.prompt(), t.app])
        #expect(first.promptHoles == [t.promptRect], "the hole is open before the move")
        let moved = CGRect(x: 260, y: 160, width: 200, height: 160)
        let snap = WindowSnapshot(windows: [t.prompt(bounds: moved), t.app], time: 0.2)
        var early: [CoverPlan] = []
        let plan = p.process(t.touched(2, t: 0.2), snapshot: snap, now: 0.2) { early.append($0) }
        #expect(!early.isEmpty, "the move hands out an early plan")
        for e in early {
            #expect(e.promptHoles.isEmpty, "no hole in an early plan, before the prompt is judged again where it is: \(e.promptHoles)")
            #expect(t.fullyCovered(e, moved), "the prompt's new place is covered")
        }
        // The look judges it again where it is (the judge here finds it clean): the final plan may open its hole there.
        #expect(plan.promptHoles.allSatisfy { moved.contains($0) }, "a hole only where the prompt is now: \(plan.promptHoles)")
    }
}
