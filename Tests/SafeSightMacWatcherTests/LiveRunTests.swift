// SPDX-License-Identifier: Apache-2.0
// What the first live run of the Testing edition found (a slow virtual Mac, 19 November 2026), each as a test that fails
// on the code that ran there: covers that never settled on a still screen, the window server's own indicator taken for
// another app's window over the covers, and plans that alternated between covered whole and not. Synthetic marker
// patterns and fake models only; time is simulated (the judging budget follows `now`).
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

/// A harmless page: neutral textured "photos" (clean), and some "borderline" ones: a fifth of each is the red marker,
/// so family A scores about 0.2, under the cover cut-off (0.3) but over half of it, which the verdict cache never keeps
/// (the margin rule). Every judgement of a borderline picture costs the budget again.
enum LivePage {
    static func page(_ w: Int, _ h: Int, clean: Int, borderline: Int, top: Int = 0, seed: UInt32 = 1) -> (RGBAImage, [PixelRect]) {
        var img = Fixtures.blank(w, h)
        var rects: [PixelRect] = []
        let side = 44, gap = 16, perRow = max(1, (w - gap) / (side + gap))
        for k in 0..<(clean + borderline) {
            let r = PixelRect(x: gap + (k % perRow) * (side + gap), y: top + gap + (k / perRow) * (side + gap), w: side, h: side)
            guard r.maxY <= h else { break }
            Fixtures.paint(&img, r, channel: nil, seed: seed &+ UInt32(k) &* 7)
            if k >= clean { Fixtures.paint(&img, PixelRect(x: r.x, y: r.y, w: r.w, h: r.h / 5), channel: 0, seed: seed &+ 900 &+ UInt32(k)) }
            rects.append(r)
        }
        return (img, rects)
    }
}

@Suite struct StillScreenOnASlowMacTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))

    /// Runs a still screen: one complete frame, then a "nothing changed" frame every quarter second (what the watcher asks
    /// for itself when the capture sends none). Returns the frame from which nothing at all was drawn (final and early
    /// plans), if it stayed so to the end, and the number of frames.
    func settle(_ p: DisplayPipeline, _ img: RGBAImage, _ snap: WindowSnapshot, frames: Int) -> (settledAt: Int?, last: CoverPlan) {
        var settledAt: Int?
        var last = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        for k in 1...frames {
            let t = Double(k) * 0.25
            var early: [CoverPlan] = []
            last = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t) { early.append($0) }
            let calm = last.wholeDisplay == nil && last.items.isEmpty && early.allSatisfy { $0.wholeDisplay == nil && $0.items.isEmpty }
            if calm { if settledAt == nil { settledAt = k } } else { settledAt = nil }
        }
        return (settledAt, last)
    }

    /// A slow Mac, as the first live run met it: each model judgement takes real time (2 ms here, against a 40 ms limit
    /// for a frame's judging, about the virtual Mac's ratio), the register's budget (40 judgements a second), a menu
    /// bar window in front, and a screen whose borderline pictures cost more to judge again than one frame allows. On the
    /// code that ran live, 83 covers stayed for ever. Now the screen settles to nothing drawn, early plans included, and
    /// stays so with nothing left to judge.
    @Test func aStillScreenOnASlowMacSettlesToNoCoverAndStaysSo() {
        let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let (img, _) = LivePage.page(1024, 768, clean: 60, borderline: 24)
        let snap = WindowSnapshot(windows: [WindowInfo(number: 2, ownerPID: 90, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1024, height: 60)),
                                            WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: d.bounds)], time: 0)
        let p = DisplayPipeline(display: d, judger: SleepyJudge(Fixtures.detector(), ms: 2), budgetShare: Register.JUDGEMENT_BUDGET,
                                ignoredPIDs: [], callWallMs: 40)
        var last = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        var settledAt: Int?
        let frames = 600
        for k in 1...frames {
            let t = Double(k) * 0.25
            var early: [CoverPlan] = []
            last = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t) { early.append($0) }
            let calm = last.wholeDisplay == nil && last.items.isEmpty && early.allSatisfy { $0.wholeDisplay == nil && $0.items.isEmpty }
            if calm { if settledAt == nil { settledAt = k } } else { settledAt = nil }
        }
        let at = settledAt ?? frames + 1
        #expect(at <= frames - 240, "settled at frame \(at) (\(Double(at) / 4) s), and stayed so for the last minute; still drawn: \(last.items.count) covers; held \(p.heldLines.prefix(6))")
        #expect(!p.needsAnotherLook, "nothing left to judge: the watcher stops asking for looks, and stays idle")
    }

    /// A flagged picture on the same still screen stays covered for good: settling never lifts anything flagged.
    @Test func aFlaggedPictureStaysCoveredOnAStillScreen() {
        var (img, _) = LivePage.page(600, 400, clean: 12, borderline: 4)
        let flagged = PixelRect(x: 420, y: 250, w: 120, h: 120)
        Fixtures.paintFlagged(&img, flagged)
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 8, ignoredPIDs: [], callWallMs: .infinity)
        let r = settle(p, img, Fixtures.oneWindow(d.bounds), frames: 1200)
        #expect(r.last.covers(CGRect(x: 420, y: 250, width: 120, height: 120), kind: .plain))
    }
}

/// A judge that takes `ms` of real time per model judgement it makes (a slow Mac).
final class SleepyJudge: Judging {
    let inner: Judging, ms: Double
    init(_ inner: Judging, ms: Double) { self.inner = inner; self.ms = ms }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int, progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        let v = inner.judgeArea(frame, context: context, within: area, budget: budget, progress: progress)
        if v.judgements > 0 { usleep(useconds_t(Double(v.judgements) * ms * 1000)) }
        return v
    }
    func setRule(_ rule: DetectorRule) { inner.setRule(rule) }
    func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]? { inner.pictureRegions(frame, within: area) }
}

@Suite struct GatheredCleanJudgementTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let g = PixelRect(x: 100, y: 100, w: 80, h: 80)

    /// A cover over a picture whose entries no single call can afford: each call judges one of its two entries and leaves
    /// the other. On the code that ran live a clean judgement needed both in one call, so it never lifted. Now a clean
    /// judgement is counted each time both have been judged clean since the last one, and four lift it; a flag in between
    /// starts the count again, and an entry only shown as judged earlier never counts.
    @Test func cleanJudgementsGatherOverCallsAndAFlagStartsThemAgain() {
        var call = 0
        var flagAt: Int?
        var perArea: [PixelRect: Int] = [:]
        let g = self.g
        let judge = VerdictScript { area in
            call += 1
            perArea[area, default: 0] += 1
            // The first call blurs the picture (not yet judged), and leaves the whole pass for later.
            if call == 1 {
                return FrameVerdict(regions: [RegionVerdict(rect: g, display: .contain, reason: .overload, pass: .region),
                                              RegionVerdict(rect: area, display: .clear, reason: .judgedClean, pass: .whole)],
                                    coverWindow: false, strike: false, hot: false, judgements: 2, overloaded: 1)
            }
            if call == flagAt {
                return FrameVerdict(regions: [RegionVerdict(rect: g, display: .cover, reason: .bothFamilies, pass: .region)],
                                    coverWindow: false, strike: false, hot: false, judgements: 2, overloaded: 0)
            }
            // Then the region and the whole pass over it take turns: one judged clean, the other left (or shown as judged
            // earlier).
            let regionNow = perArea[area]! % 2 == 1
            return FrameVerdict(regions: [RegionVerdict(rect: g, display: .clear, reason: regionNow ? .judgedClean : .judgedEarlier, pass: .region),
                                          RegionVerdict(rect: area, display: .clear, reason: regionNow ? .overload : .judgedClean, pass: .whole)],
                                coverWindow: false, strike: false, hot: false, judgements: 1, overloaded: regionNow ? 1 : 0)
        }
        let p = DisplayPipeline(display: d, judger: judge, budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let snap = Fixtures.oneWindow(d.bounds)
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, g, channel: nil, seed: 4)
        _ = p.process(Fixtures.frame(img, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        #expect(!p.held.isEmpty, "blurred until judged")
        func idle(_ k: Int) -> CoverPlan {
            let t = Double(k) * 0.25
            return p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: snap, now: t)
        }
        // Two calls per clean judgement: after 7 more calls (3 gathered), still held; a flag then starts again.
        for k in 1...7 { _ = idle(k) }
        #expect(!p.held.isEmpty && p.held.allSatisfy { $0.clean == 3 }, "\(p.heldLines) calls \(call)")
        flagAt = call + 1
        _ = idle(8)
        #expect(p.held.contains { $0.clean == 0 }, "a flag starts the count again")
        flagAt = nil
        var lifted: Int?
        for k in 9...40 where lifted == nil {
            if idle(k).items.isEmpty && p.held.isEmpty { lifted = k }
        }
        #expect(lifted != nil, "four clean judgements gathered over calls lift it")
        if let lifted { #expect(lifted >= 16, "not before four whole rounds after the flag (\(lifted))") }
    }
}

@Suite struct WindowAboveTheCoversTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let win = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))

    func flagged() -> RGBAImage {
        var img = Fixtures.blank(600, 400)
        Fixtures.paintFlagged(&img, PixelRect(x: 100, y: 100, w: 100, h: 100))
        return img
    }

    /// The window server's screen-recording indicator (and, in a virtual Mac, its pointer) sit at the cursor's level over
    /// everything. On the code that ran live they made every plan "covered whole: another app's window in front".
    @Test func theWindowServersOwnIndicatorDoesNotCoverTheDisplayButAnAppsWindowThereDoes() {
        let indicator = WindowInfo(number: 9, ownerPID: 170, layer: WindowInfo.cursorLevel, bounds: CGRect(x: 120, y: 120, width: 29, height: 28),
                                   systemOverlay: true)
        let appWindow = WindowInfo(number: 9, ownerPID: 700, layer: WindowInfo.cursorLevel, bounds: CGRect(x: 120, y: 120, width: 29, height: 28))
        for (w, expectWhole) in [(indicator, false), (appWindow, true)] {
            let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
            let plan = p.process(Fixtures.frame(flagged(), display: d, scale: 1, t: 0), snapshot: WindowSnapshot(windows: [w, win], time: 0), now: 0)
            if expectWhole {
                #expect(plan.wholeDisplay == .windowAboveCovers, "an app's window over a cover still covers the display")
            } else {
                #expect(plan.wholeDisplay == nil && plan.covers(CGRect(x: 100, y: 100, width: 100, height: 100)))
            }
        }
    }

    @Test func onlyTheWindowServersOwnSmallWindowsAtTheCursorsLevelAreOverlays() {
        let small = CGRect(x: 838, y: 1, width: 29, height: 28)
        #expect(WindowInfo.isSystemOverlay(layer: WindowInfo.cursorLevel, bounds: small, ownerIsWindowServer: true))
        #expect(!WindowInfo.isSystemOverlay(layer: WindowInfo.cursorLevel, bounds: small, ownerIsWindowServer: false), "an app's window")
        #expect(!WindowInfo.isSystemOverlay(layer: WindowInfo.cursorLevel, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), ownerIsWindowServer: true), "too big")
        #expect(!WindowInfo.isSystemOverlay(layer: CoverLevel.canvas + 1, bounds: small, ownerIsWindowServer: true), "another level")
    }

    /// Early plans skipped the check while final plans made it, so the display flipped between blurs and covered whole
    /// many times a second. Every plan drawn now goes through the same check.
    @Test func earlyPlansAreCheckedLikeFinalOnes() {
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [], callWallMs: .infinity)
        let high = WindowInfo(number: 5, ownerPID: 700, layer: CoverLevel.canvas, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        let snap = WindowSnapshot(windows: [high, win], time: 0)
        let blank = Fixtures.blank(600, 400)
        _ = p.process(Fixtures.frame(blank, display: d, scale: 1, t: 0), snapshot: snap, now: 0)
        var early: [CoverPlan] = []
        let final = p.process(Fixtures.frame(flagged(), display: d, scale: 1, dirty: [PixelRect(x: 96, y: 96, w: 112, h: 112)], t: 0.1),
                              snapshot: snap, now: 0.1) { early.append($0) }
        #expect(final.wholeDisplay == .windowAboveCovers)
        #expect(!early.isEmpty, "the fast model's flag is drawn early")
        #expect(early.allSatisfy { $0.wholeDisplay == .windowAboveCovers }, "\(early.map { $0.wholeDisplay as Any })")
    }
}

@Suite struct JudgedInTurnTests {
    /// The detector on its own: with a budget too small for every borderline picture, entries never judged come first,
    /// and the ones judged before take turns, so every entry is judged; a picture judged clear earlier on exactly these
    /// pixels is shown as such meanwhile, never as unjudged, but never where a blur rule or a covered start applies.
    @Test func everyEntryIsJudgedInTurnAndJudgedEarlierIsShownNotCovered() {
        let det = Fixtures.detector()
        let (img, rects) = LivePage.page(600, 400, clean: 10, borderline: 10)
        let ctx = JudgeContext(windowID: 1, startsCovered: false)
        var everJudged = Set<PixelRect>()
        var last: FrameVerdict?
        for _ in 0..<80 {
            let v = det.judge(img, context: ctx, budget: 6)
            for r in v.regions where r.pass == .region && ![.overload, .judgedEarlier, .rejudgeDue].contains(r.reason) { everJudged.insert(r.rect) }
            last = v
        }
        let found = Set(last!.regions.filter { $0.pass == .region }.map(\.rect))
        #expect(!found.isEmpty)
        #expect(found.isSubset(of: everJudged), "every picture was judged at least once: \(found.subtracting(everJudged).count) never")
        #expect(last!.overloaded == 0, "nothing is left unjudged for ever")
        #expect(last!.regions.contains { $0.reason == .judgedEarlier }, "borderline pictures not reached are shown as judged earlier")
        #expect(last!.regions.allSatisfy { $0.display == .clear })
        _ = rects
        // Where the window starts covered, nothing judged earlier is shown: it is unjudged.
        let covered = det.judge(img, context: JudgeContext(windowID: 2, startsCovered: true), budget: 0)
        #expect(!covered.regions.contains { [.judgedEarlier, .rejudgeDue].contains($0.reason) })
        #expect(covered.overloaded > 0)
    }

    @Test func aJudgementTooOldIsDueAgain() {
        let det = Fixtures.detector()
        let (img, _) = LivePage.page(600, 400, clean: 0, borderline: 4)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = det.judge(img, context: JudgeContext(windowID: 1, startsCovered: false, now: t0))
        let soon = det.judge(img, context: JudgeContext(windowID: 1, startsCovered: false, now: t0.addingTimeInterval(5)), budget: 0)
        #expect(soon.regions.contains { $0.reason == .judgedEarlier })
        let late = det.judge(img, context: JudgeContext(windowID: 1, startsCovered: false, now: t0.addingTimeInterval(31)), budget: 0)
        #expect(late.regions.contains { $0.reason == .rejudgeDue })
        #expect(!late.regions.contains { $0.reason == .judgedEarlier })
    }
}
