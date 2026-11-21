// SPDX-License-Identifier: Apache-2.0
// Sustained change on the virtual Mac's window list: a harmless page scrolled, a harmless video playing. Measured with
// the fake judge of `UsableCoversTests` (the detector's order of work, its costs and its clean-cache rule). Time is
// simulated; synthetic rectangles only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

extension ScreenSim {
    /// The share of the display a plan covers (sampled every 4 points).
    func coveredShare(_ plan: CoverPlan) -> Double {
        if plan.wholeDisplay != nil { return 1 }
        guard !plan.items.isEmpty else { return 0 }
        var hit = 0, all = 0
        var y = d.bounds.minY + 2
        while y < d.bounds.maxY {
            var x = d.bounds.minX + 2
            let row = plan.items.filter { $0.rect.minY <= y && $0.rect.maxY > y }
            while x < d.bounds.maxX {
                all += 1
                if row.contains(where: { $0.rect.minX <= x && $0.rect.maxX > x }) { hit += 1 }
                x += 4
            }
            y += 4
        }
        return Double(hit) / Double(all)
    }

    /// The share of the display covered, averaged over time from `from` to `to` (each plan holds until the next).
    func meanShare(from: Double, to: Double) -> Double {
        var sum = 0.0, span = 0.0
        let ps = plans
        for k in ps.indices where ps[k].t >= from && ps[k].t < to {
            let end = k + 1 < ps.count ? min(ps[k + 1].t, to) : to
            let dt = max(0, end - ps[k].t)
            sum += coveredShare(ps[k].plan) * dt; span += dt
        }
        return span > 0 ? sum / span : 0
    }

    /// The largest area covered by one item, or the display's, in plans from `from` to `to`.
    func largest(from: Double, to: Double) -> CGFloat {
        plans.filter { $0.t >= from && $0.t < to }.map { e in
            e.plan.wholeDisplay != nil ? d.bounds.width * d.bounds.height : (e.plan.items.map { $0.rect.width * $0.rect.height }.max() ?? 0)
        }.max() ?? 0
    }

    /// The share of time from `from` to `to` during which more than `over` of the display was covered.
    func timeOver(_ over: Double, from: Double, to: Double) -> Double {
        var hit = 0.0, span = 0.0
        let ps = plans
        for k in ps.indices where ps[k].t >= from && ps[k].t < to {
            let end = k + 1 < ps.count ? min(ps[k + 1].t, to) : to
            let dt = max(0, end - ps[k].t)
            if coveredShare(ps[k].plan) > over { hit += dt }
            span += dt
        }
        return span > 0 ? hit / span : 0
    }
}

/// What a run of sustained change looked like, in figures (printed by each test).
struct SustainedFigures {
    var largest: CGFloat = 0
    var largestAfter: CGFloat = 0
    var meanShare = 0.0
    var overHalf = 0.0
    var settle: Double?
    var restShare = 0.0
    var wholeDisplayShare = 0.0
    var fullPasses = 0, fullFinished = 0
    var line: String {
        String(format: "largest %.0f%% of the display while it changed, %.0f%% after, mean share %.2f, time over half %.2f, settle %@, rest share %.2f, display-sized %.2f, full passes %d finished %d",
               Double(largest) / (1024 * 768) * 100, Double(largestAfter) / (1024 * 768) * 100, meanShare, overHalf, settle.map { String(format: "%.1f s", $0) } ?? "never", restShare, wholeDisplayShare, fullPasses, fullFinished)
    }
}

@Suite struct SustainedChangeTests {
    let u = UsableCoversTests()
    var d: DisplayDescriptor { u.d }

    /// A busy harmless page in Safari under the Dock's display-sized window, scrolled for a minute, then still.
    func scrollRun(seconds: Double = 60, exact: Bool = true) -> (ScreenSim, SustainedFigures, Double, Double) {
        var sim = u.pageSim()
        sim.judge.exactChanges = exact
        sim.full()
        _ = sim.settle(limit: 400)
        let open = sim.t
        sim.scroll(by: 0)
        var dir = 8
        while sim.t < open + seconds {
            if sim.offset + dir > 3000 - u.pageView.h || sim.offset + dir < 0 { dir = -dir }
            sim.scroll(by: dir)
        }
        let stop = sim.t
        var f = SustainedFigures()
        f.settle = sim.settle(limit: stop + 600).map { $0 - stop }
        f.largest = sim.largest(from: open, to: stop)
        f.largestAfter = sim.largest(from: stop, to: .infinity)
        f.meanShare = sim.meanShare(from: open, to: stop)
        f.overHalf = sim.timeOver(0.5, from: open, to: stop)
        f.wholeDisplayShare = sim.timeOver(0.9, from: open, to: stop)
        return (sim, f, open, stop)
    }

    /// A harmless video playing in a page for a minute (a new picture every frame at 30 frames a second, 640 by 360
    /// points), then stopped.
    let video = PixelRect(x: 192, y: 200, w: 640, h: 360)

    func videoRun(seconds: Double = 60, exact: Bool = true) -> (ScreenSim, SustainedFigures) {
        var sim = u.pageSim()
        sim.judge.exactChanges = exact
        sim.full()
        _ = sim.settle(limit: 400)
        sim.scroll(by: 0)
        let first = sim.settle(limit: sim.t + 400)
        #expect(first != nil, "the page settles before the video starts")
        // The video: one picture the size of its area, new in every frame; the page's pictures it hides are gone.
        let vid = video
        let shown = sim.judge.pictures.filter { !$0.rect.intersects(vid) }
        sim.judge.pictures = shown + [RuleJudge.Picture(rect: vid, cost: 2 * Detector.pieces(vid).count, borderline: false, id: 9000)]
        let start = sim.t
        var f = SustainedFigures()
        var lastFull = sim.p.lastFullPass
        var fullOpen = false
        let vg = CGRect(x: vid.x, y: vid.y, width: vid.w, height: vid.h).insetBy(dx: -4, dy: -4)
        var frame = 0
        while sim.t < start + seconds {
            frame += 1
            sim.change(vid, value: UInt8(frame % 200 + 20))
            if sim.p.lastFullPass != lastFull { lastFull = sim.p.lastFullPass; f.fullPasses += 1; fullOpen = true }
            // The full re-judge has finished once nothing outside the video is left for later.
            let videoArea = CGFloat(vid.w * vid.h) * 1.1
            if fullOpen, sim.p.pending.allSatisfy({ vg.contains($0) }),
               !sim.p.held.contains(where: { $0.whole || $0.rel.width * $0.rel.height > videoArea }) {
                f.fullFinished += 1; fullOpen = false
            }
        }
        let stop = sim.t
        f.largest = sim.largest(from: start, to: stop)
        f.meanShare = sim.meanShare(from: start, to: stop)
        f.overHalf = sim.timeOver(0.5, from: start, to: stop)
        f.wholeDisplayShare = sim.timeOver(0.9, from: start, to: stop)
        // Outside the video: the share of the rest of the display covered, on average.
        var sum = 0.0, span = 0.0
        for k in sim.plans.indices where sim.plans[k].t >= start && sim.plans[k].t < stop {
            let end = k + 1 < sim.plans.count ? min(sim.plans[k + 1].t, stop) : stop
            let pl = sim.plans[k].plan
            let rest: Double
            if pl.wholeDisplay != nil { rest = 1 } else {
                var hit = 0, all = 0
                var y = 2.0
                while y < 768 {
                    var x = 2.0
                    while x < 1024 {
                        if !vg.contains(CGPoint(x: x, y: y)) {
                            all += 1
                            if pl.items.contains(where: { $0.rect.contains(CGPoint(x: x, y: y)) }) { hit += 1 }
                        }
                        x += 8
                    }
                    y += 8
                }
                rest = Double(hit) / Double(max(1, all))
            }
            sum += rest * (end - sim.plans[k].t); span += end - sim.plans[k].t
        }
        f.restShare = span > 0 ? sum / span : 0
        // Stopped: the video's last frame stays.
        f.settle = sim.settle(limit: stop + 600).map { $0 - stop }
        f.largestAfter = sim.largest(from: stop, to: .infinity)
        return (sim, f)
    }

    @Test(arguments: [true, false]) func aBusyPageScrolled(exact: Bool) {
        let (_, f, _, _) = scrollRun(exact: exact)
        print("SCROLL \(exact ? "exact" : "as written") \(f.line)")
        #expect(f.settle != nil, "settles once the scrolling stops")
        // With exact entries the page settles in about 380 s (about 525 s before covers over the same place were one).
        if exact { #expect(f.settle.map { $0 <= 450 } ?? false, "settles within 450 s: \(f.line)") }
    }

    @Test(arguments: [true, false]) func aVideoPlaying(exact: Bool) {
        let (_, f) = videoRun(exact: exact)
        print("VIDEO \(exact ? "exact" : "as written") \(f.line)")
        #expect(f.settle != nil, "settles once the video stops")
        // With exact entries no cover is larger than a quarter of the display while it plays (the display was covered
        // whole after the first full re-judge before only what a call left unjudged was left for later).
        if exact { #expect(f.largest < 1024 * 768 / 4, "no cover near the display's size: \(f.line)") }
    }

    /// Draws a second: every plan handed to the drawing during the scroll, against those the drawing would draw.
    @Test func drawsWhileScrolling() {
        let (sim, _, open, stop) = scrollRun(seconds: 20)
        let during = sim.delivered.filter { $0.t >= open && $0.t < stop }
        var gate = DrawGate()
        let drawn = during.filter { gate.shouldDraw([$0.plan], now: $0.t, urgent: false) }.count
        let after = sim.delivered.filter { $0.t >= stop }
        var gate2 = DrawGate()
        let drawnAfter = after.filter { gate2.shouldDraw([$0.plan], now: $0.t, urgent: false) }.count
        let span = max(0.001, (after.last?.t ?? stop) - stop)
        print(String(format: "DRAWS scroll: %.1f handed a second, %.1f drawn; settling: %.1f handed, %.1f drawn", Double(during.count) / (stop - open), Double(drawn) / (stop - open),
                     Double(after.count) / span, Double(drawnAfter) / span))
    }

    /// The menu bar's clock ticking on a settled desktop, with the looks at a still screen at the app's pace (as the app
    /// runs) and at every "nothing changed" frame (as before pull request 37).
    @Test func theClockTick() {
        for paced in [true, false] {
            var sim = ScreenSim(display: d, judge: RuleJudge(pictures: u.desktopPictures(), blindCalls: 0, msPerJudgement: 15, msPerCall: 4), windows: u.vmWindows)
            if !paced { sim.p.stillLookPace = nil }
            sim.clock = u.clock
            sim.full()
            _ = sim.settle(limit: 600)
            sim.clockEvery = nil
            sim.still(until: sim.t + 5)
            let at = sim.t, cpu0 = sim.cpuMs, looks0 = sim.looks, frames0 = sim.plans.count, j0 = sim.judge.judgements
            sim.change(u.clock)
            let settled = sim.settle(limit: at + 120)
            print(String(format: "CLOCK %@: settled after %@, %d frames judged of %d, %d judgements, cpu %.0f ms", paced ? "paced" : "every frame",
                         settled.map { String(format: "%.1f s", $0 - at) } ?? "never", sim.looks - looks0, sim.plans.count - frames0, sim.judge.judgements - j0, sim.cpuMs - cpu0))
            if paced { #expect(sim.cpuMs - cpu0 <= 1500) }
        }
    }

    /// Draws a second on a settled screen, with the capture sending "nothing changed" frames 30 times a second.
    @Test func drawsAtRest() {
        var sim = ScreenSim(display: d, judge: RuleJudge(pictures: u.desktopPictures(), blindCalls: 0, msPerJudgement: 15, msPerCall: 4), windows: u.vmWindows)
        sim.clockEvery = nil
        sim.full()
        #expect(sim.settle(limit: 600) != nil)
        let at = sim.t
        sim.still(until: at + 10)
        let handed = sim.delivered.filter { $0.t >= at }
        var gate = DrawGate()
        _ = gate.shouldDraw([sim.plans.last!.plan], now: at - 0.01, urgent: false)
        let drawn = handed.filter { gate.shouldDraw([$0.plan], now: $0.t, urgent: false) }.count
        print(String(format: "DRAWS at rest: %.1f handed a second, %.1f drawn", Double(handed.count) / 10, Double(drawn) / 10))
        #expect(drawn == 0, "nothing new to draw on a settled screen: \(drawn)")
    }
}
