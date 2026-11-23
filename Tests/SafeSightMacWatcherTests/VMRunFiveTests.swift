// SPDX-License-Identifier: Apache-2.0
// The virtual Mac's fifth live run, simulated with the costs it showed (`RuleJudge.vm`): about 9 ms a judgement, and a
// call over the whole display costing about 280 ms whatever it judges, the first time on a frame. A still desktop from
// the start; a small plain window opening on a settled desktop just as a full re-judge is due, then closing; the clock's
// tick on a settled desktop. Time and CPU are the fake judge's clock; synthetic rectangles only.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

@Suite struct VMRunFiveTests {
    let u = UsableCoversTests()
    var d: DisplayDescriptor { u.d }

    /// The virtual Mac's desktop as its detector saw it in run 5: its first look over the whole display had about 470
    /// entries (48 judged, 421 left unjudged), so about 440 pictures, most of them small (icons, and words of the Finder
    /// window's lines of text, which cost the small-picture models too). Every third is borderline.
    func desktopPictures() -> [RuleJudge.Picture] {
        var rects: [PixelRect] = []
        for k in 0..<12 { rects.append(PixelRect(x: 200 + 56 * k, y: 706, w: 48, h: 48)) }
        for k in 0..<4 { rects.append(PixelRect(x: 950, y: 40 + 90 * k, w: 64, h: 64)) }
        for k in 0..<8 { rects.append(PixelRect(x: 12 + 60 * k, y: 6, w: 40, h: 18)) }
        rects.append(u.clock)
        // The Finder window: rows of icons, each with a name under it, then lines of words.
        for r in 0..<3 { for c in 0..<12 {
            rects.append(PixelRect(x: 70 + 74 * c, y: 120 + 100 * r, w: 40, h: 40))
            rects.append(PixelRect(x: 64 + 74 * c, y: 166 + 100 * r, w: 52, h: 10))
        } }
        for line in 0..<10 { for w in 0..<30 { rects.append(PixelRect(x: 62 + 30 * w, y: 420 + 10 * line, w: 26, h: 8)) } }
        return rects.enumerated().map { i, r in
            .init(rect: r, cost: (r.shortSide < 64 ? 4 : 2) * Detector.pieces(r).count, borderline: i % 3 == 1)
        }
    }

    func sim() -> ScreenSim {
        var s = ScreenSim(display: d, judge: RuleJudge.vm(pictures: desktopPictures()), windows: u.vmWindows)
        s.clock = u.clock
        return s
    }

    /// The still desktop from the start (the virtual Mac: 381 s to clear, at 130 to 170% of a core; the old cost model
    /// said 44 s).
    @Test func aStillDesktopFromTheStart() {
        var s = sim()
        s.full()
        let settled = s.settle(limit: 1200)
        print(String(format: "RUN5 still desktop (%d pictures): settled %@, cpu %.0f s (%.0f%% of a core), %d judgements, largest after 5 s %.0f%% of the display",
                     s.judge.pictures.count, settled.map { String(format: "%.1f s", $0) } ?? "never", s.cpuMs / 1000, s.cpuMs / 10 / max(1, s.t), s.judge.judgements,
                     Double(s.largestCover(from: 5)) / (1024 * 768) * 100))
        #expect(settled != nil && settled! <= 120, "settles within two minutes: \(settled.map { "\($0) s" } ?? "never"); held \(s.p.heldLines.prefix(6))")
        #expect(s.largestCover(from: 5) < d.bounds.width * d.bounds.height / 4, "nothing near the display's size after the first looks")
    }

    /// A plain 200 by 182 point window opens on a settled desktop after more than 30 s of rest (so a full re-judge is due
    /// with it), stays a minute, and closes (the virtual Mac: covered 78% of the display at 0.36 s and 96.5% at 0.8 s, and
    /// lifted 82 s after the window closed).
    @Test func aSmallWindowOnASettledDesktop() {
        var s = sim()
        s.full()
        #expect(s.settle(limit: 1200) != nil)
        s.clockEvery = nil
        s.still(until: s.t + 35)
        let small = PixelRect(x: 560, y: 352, w: 200, h: 182)
        let win = WindowInfo(number: 80, ownerPID: 900, layer: 3, bounds: CGRect(x: 560, y: 352, width: 200, height: 182))
        let windows = s.snap.windows
        s.snap = WindowSnapshot(windows: windows + [win], time: s.t)
        let open = s.t, cpu0 = s.cpuMs
        s.change(small, value: 200)
        s.still(until: open + 60)
        let shareAt = { (dt: Double) -> Double in
            s.coveredShare(s.plans.last { $0.t <= open + dt }?.plan ?? s.plans.last!.plan)
        }
        let early = [0.36, 0.8, 2, 10].map { shareAt($0) }
        let largestOpen = s.largest(from: open, to: open + 60)
        s.snap = WindowSnapshot(windows: windows, time: s.t)
        let close = s.t
        s.change(small, value: 240)
        let lifted = s.settle(limit: close + 600)
        print(String(format: "RUN5 small window: covered %.3f at 0.36 s, %.3f at 0.8 s, %.3f at 2 s, %.3f at 10 s; largest %.1f%% while open; settled %@ after it closed; cpu %.1f s",
                     early[0], early[1], early[2], early[3], Double(largestOpen) / (1024 * 768) * 100,
                     lifted.map { String(format: "%.1f s", $0 - close) } ?? "never", (s.cpuMs - cpu0) / 1000))
        let area = CGFloat(small.w * small.h)
        #expect(largestOpen <= 2 * area, "covered about the window's size while it is new: largest \(largestOpen) against \(area)")
        #expect(early.allSatisfy { $0 < 0.15 }, "never most of the display: \(early)")
        #expect(lifted != nil && lifted! - close <= 30, "lifts soon after it closes: \(lifted.map { "\($0 - close) s" } ?? "never")")
    }

    /// The clock ticks once on a settled desktop after more than 30 s of rest (a full re-judge is due with it; the
    /// virtual Mac paid 1.8 to 3.8 s of CPU a tick).
    @Test func aClockTickOnASettledDesktop() {
        var s = sim()
        s.full()
        #expect(s.settle(limit: 1200) != nil)
        s.clockEvery = nil
        s.still(until: s.t + 35)
        let at = s.t, cpu0 = s.cpuMs, j0 = s.judge.judgements
        s.change(u.clock)
        let settled = s.settle(limit: at + 120)
        print(String(format: "RUN5 clock tick: settled %@, %d judgements, cpu %.2f s, largest %.1f%%",
                     settled.map { String(format: "%.1f s", $0 - at) } ?? "never", s.judge.judgements - j0, (s.cpuMs - cpu0) / 1000,
                     Double(s.largestCover(from: at)) / (1024 * 768) * 100))
        #expect(settled != nil)
        #expect(s.largestCover(from: at) < d.bounds.width * d.bounds.height / 20, "nothing large covered for a clock tick")
    }
}
