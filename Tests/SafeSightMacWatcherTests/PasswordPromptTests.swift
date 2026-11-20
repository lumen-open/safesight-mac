// SPDX-License-Identifier: Apache-2.0
// macOS's password prompt is left clear (PasswordPrompt.swift): only a window whose owner passes the checks, only its
// own rectangle, only once its own pixels have been judged, and with a plain cover behind it. Everything here uses
// injected facts and made-up windows: no real prompt, no screen.
import CoreGraphics
import Foundation
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher
@testable import Preprocess

/// A judge whose answer depends on the window judged: `unjudged` windows have every entry left unjudged.
final class PerWindowScript: Judging {
    var unjudged: Set<UInt64> = []
    var flagged: Set<UInt64> = []
    /// Windows judged in part: half their area clean, the rest left unjudged.
    var partial: Set<UInt64> = []
    /// Windows whose every call faults (a model failure), spending the budget it is given.
    var faulty: Set<UInt64> = []
    /// The pictures the finder "sees" (none by default; nil: this judge cannot say).
    var pictures: [PixelRect]? = []
    var calls: [UInt64] = []
    var areas: [(id: UInt64, area: PixelRect, budget: Int)] = []
    func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]? {
        pictures.map { $0.filter { $0.intersects(area) } }
    }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        calls.append(context.windowID)
        areas.append((context.windowID, area, budget))
        if faulty.contains(context.windowID) {
            return FrameVerdict(regions: [RegionVerdict(rect: area, display: .contain, reason: .overload, pass: .whole)],
                                coverWindow: false, strike: false, hot: false, judgements: budget, overloaded: 1, modelFaults: 1)
        }
        if unjudged.contains(context.windowID) {
            return FrameVerdict(regions: [RegionVerdict(rect: area, display: .contain, reason: .overload, pass: .whole)],
                                coverWindow: false, strike: false, hot: false, judgements: 0, overloaded: 1)
        }
        if partial.contains(context.windowID) {
            let half = PixelRect(x: area.x, y: area.y, w: area.w / 2, h: area.h)
            let rest = PixelRect(x: area.x + area.w / 2, y: area.y, w: area.w - area.w / 2, h: area.h)
            return FrameVerdict(regions: [RegionVerdict(rect: half, display: .clear, reason: .judgedClean, pass: .region),
                                          RegionVerdict(rect: rest, display: .contain, reason: .overload, pass: .region)],
                                coverWindow: false, strike: false, hot: false, judgements: 1, overloaded: 1)
        }
        if flagged.contains(context.windowID) {
            return FrameVerdict(regions: [RegionVerdict(rect: area, display: .cover, reason: .bothFamilies, pass: .whole)],
                                coverWindow: true, strike: false, hot: false, judgements: 2, overloaded: 0)
        }
        return VerdictScript.clean(area)
    }
    func setRule(_ rule: DetectorRule) {}
}

/// The real detector, counting the judgements made for each window.
final class CountingJudge: Judging {
    let inner = Fixtures.detector()
    var judgements: [UInt64: Int] = [:]
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        let v = inner.judgeArea(frame, context: context, within: area, budget: budget, progress: progress)
        judgements[context.windowID, default: 0] += v.judgements
        return v
    }
    func setRule(_ rule: DetectorRule) {}
    func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]? { inner.pictureRegions(frame, within: area) }
}

@Suite struct PasswordPromptTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    /// An app's window filling the display, held covered whole.
    let app = WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
    let promptRect = CGRect(x: 200, y: 120, width: 200, height: 160)
    func prompt(verified: Bool = true, bounds: CGRect? = nil, number: UInt32 = 50, alpha: Double = 1) -> WindowInfo {
        WindowInfo(number: number, ownerPID: 900, layer: PasswordPrompt.level, bounds: bounds ?? promptRect, alpha: alpha, passwordPrompt: verified)
    }
    var appTarget: JudgeTarget { .window(number: app.number, ownerPID: app.ownerPID) }

    func pipeline(_ j: Judging = PerWindowScript()) -> DisplayPipeline {
        DisplayPipeline(display: d, judger: j, budgetShare: 1e6, ignoredPIDs: [42], callWallMs: .infinity)
    }

    /// A frame that changed one pixel in the far corner (so it is judged, but nothing of the prompt changed).
    func touched(_ k: Int, t: TimeInterval) -> CapturedFrame {
        var img = Fixtures.blank(600, 400)
        img.pixels[(399 * 600 + 599) * 4] = UInt8(k & 0xFF)
        return Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 592, y: 392, w: 8, h: 8)], t: t)
    }

    /// The app's window held covered whole (as after a flag), the prompt shown over it.
    func coveredBehind(_ p: DisplayPipeline, _ windows: [WindowInfo]) -> CoverPlan {
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: WindowSnapshot(windows: windows, time: 0), now: 0)
        p.held.append(DisplayPipeline.Held(target: appTarget, rel: .null, whole: true, kind: .plain, clean: 0))
        return p.process(touched(1, t: 0.1), snapshot: WindowSnapshot(windows: windows, time: 0.1), now: 0.1)
    }

    /// Every point of `r` is under a cover as drawn (whole-display covers by their pieces, holes left out).
    func fullyCovered(_ plan: CoverPlan, _ r: CGRect) -> Bool {
        guard plan.wholeDisplay != nil else { return plan.covers(r) }
        let layer = CoordinateSpace.toCanvasLayer(r.insetBy(dx: 1, dy: 1), display: d.bounds)
        return CoverLayout.layerPieces(plan).map(\.frame).reduce([layer]) { $0.subtracting($1) }.isEmpty
    }

    /// No cover item reaches into `r` (beyond a point of snapping).
    func clear(_ plan: CoverPlan, _ r: CGRect) -> Bool {
        plan.wholeDisplay == nil ? !plan.items.contains { $0.rect.intersection(r.insetBy(dx: 1, dy: 1)).hasArea }
            : CoverLayout.layerPieces(plan).allSatisfy { !$0.frame.intersection(CoordinateSpace.toCanvasLayer(r.insetBy(dx: 1, dy: 1), display: d.bounds)).hasArea }
    }

    // MARK: The hole

    @Test func aVerifiedPromptsRectangleIsClearAndEverythingElseStaysCovered() {
        let p = pipeline()
        let plan = coveredBehind(p, [prompt(), app])
        #expect(clear(plan, promptRect), "\(plan.items.map(\.rect))")
        #expect(plan.promptHoles == [promptRect], "a plain cover is drawn behind it: \(plan.promptHoles)")
        // Everything around it is still covered.
        for r in [CGRect(x: 0, y: 0, width: 600, height: 120), CGRect(x: 0, y: 280, width: 600, height: 120),
                  CGRect(x: 0, y: 120, width: 200, height: 160), CGRect(x: 400, y: 120, width: 200, height: 160)] {
            #expect(plan.covers(r), "\(r)")
        }
        // The way-out line stays on the cover, on its largest piece.
        #expect(plan.items.filter(\.wayOut).count == 1)
    }

    @Test func theSameWindowFromAnUncheckedOwnerIsCovered() {
        // Same level, size and place; the window list did not mark it as the prompt (its owner failed the checks).
        let plan = coveredBehind(pipeline(), [prompt(verified: false), app])
        #expect(plan.covers(promptRect))
        #expect(plan.promptHoles.isEmpty)
    }

    @Test func anOversizedOrSeeThroughOrMisplacedPromptIsCovered() {
        let big = CGRect(x: 0, y: 0, width: 600, height: 400)        // the whole display
        let wide = CGRect(x: 0, y: 50, width: 590, height: 300)      // within the size limits, more than a quarter
        let off = CGRect(x: 500, y: 120, width: 200, height: 160)    // partly off the display
        for w in [prompt(bounds: big), prompt(bounds: wide), prompt(bounds: off), prompt(alpha: 0.9),
                  WindowInfo(number: 50, ownerPID: 900, layer: PasswordPrompt.level + 1, bounds: promptRect, passwordPrompt: true)] {
            let plan = coveredBehind(pipeline(), [w, app])
            #expect(plan.covers(w.bounds.intersection(d.bounds)) && plan.promptHoles.isEmpty, "\(w)")
        }
        #expect(!PasswordPrompt.shapeQualifies(layer: 1000, bounds: CGRect(x: 0, y: 0, width: 800, height: 300), alpha: 1))
        #expect(!PasswordPrompt.shapeQualifies(layer: 1000, bounds: CGRect(x: 0, y: 0, width: 300, height: 800), alpha: 1))
        #expect(PasswordPrompt.shapeQualifies(layer: 1000, bounds: CGRect(x: 0, y: 0, width: 260, height: 400), alpha: 1))
        #expect(!PasswordPrompt.fits(CGRect(x: 0, y: 0, width: 640, height: 320), display: CGRect(x: 0, y: 0, width: 1024, height: 768)))
    }

    @Test func aWindowInFrontOfThePromptIsStillCovered() {
        let front = WindowInfo(number: 7, ownerPID: 600, layer: 1500, bounds: CGRect(x: 300, y: 100, width: 200, height: 100))
        let plan = coveredBehind(pipeline(), [front, prompt(), app])
        #expect(plan.covers(CGRect(x: 300, y: 120, width: 100, height: 80)), "the part of the prompt under another window")
        #expect(clear(plan, CGRect(x: 200, y: 200, width: 200, height: 80)))
        #expect(clear(plan, CGRect(x: 200, y: 120, width: 100, height: 80)))
    }

    @Test func aWindowBehindThePromptAtTheBackingsLevelKeepsItCovered() {
        // It would sit over the plain cover drawn behind the prompt, and show through a see-through part of it.
        let high = WindowInfo(number: 8, ownerPID: 600, layer: CoverLevel.behindPrompt, bounds: CGRect(x: 150, y: 100, width: 300, height: 200))
        let plan = coveredBehind(pipeline(), [prompt(), high, app])
        #expect(plan.covers(promptRect) && plan.promptHoles.isEmpty)
    }

    @Test func thePromptsOwnFlaggedContentStaysCoveredInsideItsHole() {
        let j = PerWindowScript()
        j.flagged = [JudgeTarget.window(number: 50, ownerPID: 900).contextID]
        let plan = coveredBehind(pipeline(j), [prompt(), app])
        #expect(plan.covers(promptRect), "a flagged picture in the prompt (its icon) is covered like any window's")
    }

    @Test func thePromptIsJudgedFirstAndItsHoleWaitsForItsJudgement() {
        let j = PerWindowScript()
        let promptID = JudgeTarget.window(number: 50, ownerPID: 900).contextID
        j.unjudged = [promptID]
        let p = pipeline(j)
        let plan = coveredBehind(p, [prompt(), app])
        #expect(plan.covers(promptRect), "not judged yet: covered as today")
        #expect(j.calls.first == promptID, "judged before anything else")
        j.unjudged = []
        let next = p.process(touched(2, t: 0.2), snapshot: WindowSnapshot(windows: [prompt(), app], time: 0.2), now: 0.2)
        #expect(next.promptHoles == [promptRect], "judged: its hole opens")
        #expect(next.covers(promptRect), "what was left unjudged in it stays blurred until it earns its clean judgements")
        // Like any window's blur, it lifts after its clean judgements; the app's cover around it stays.
        var lifted: Int?
        for k in 3...12 where lifted == nil {
            let t = Double(k) / 10
            let plan = p.process(touched(k, t: t), snapshot: WindowSnapshot(windows: [prompt(), app], time: t), now: t)
            if clear(plan, promptRect) { lifted = k; #expect(plan.covers(CGRect(x: 0, y: 0, width: 600, height: 120))) }
        }
        #expect(lifted != nil)
    }

    @Test func aPromptThatGoesIsCoveredAgainAtOnceAndJudgedAgainWhenItComesBack() {
        let j = PerWindowScript()
        let p = pipeline(j)
        #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
        // It goes: its place is covered in the very next plan.
        let gone = p.process(touched(2, t: 0.2), snapshot: WindowSnapshot(windows: [app], time: 0.2), now: 0.2)
        #expect(gone.covers(promptRect) && gone.promptHoles.isEmpty)
        // A look with nothing to judge, after it went, never brings an old hole back.
        p.held = [DisplayPipeline.Held(target: appTarget, rel: .null, whole: true, kind: .plain, clean: 0)]
        // It comes back (same window), and this time its pixels cannot be judged: it stays covered.
        j.unjudged = [JudgeTarget.window(number: 50, ownerPID: 900).contextID]
        var early: [CoverPlan] = []
        let back = p.process(touched(3, t: 0.3), snapshot: WindowSnapshot(windows: [prompt(), app], time: 0.3), now: 0.3) { early.append($0) }
        #expect(back.covers(promptRect))
        #expect(early.allSatisfy { $0.covers(promptRect) })
    }

    @Test func aHoleNeverOutlivesItsPromptOnALookWithNothingToJudge() {
        let p = pipeline()
        _ = coveredBehind(p, [prompt(), app])
        // Make the last plan one with a hole, then a "started" frame with the prompt gone.
        let started = CapturedFrame(display: d, status: .started, image: nil, map: nil, dirty: nil, time: 0.3)
        let plan = p.process(started, snapshot: WindowSnapshot(windows: [app], time: 0.3), now: 0.3)
        #expect(plan.covers(promptRect) && plan.promptHoles.isEmpty)
    }

    @Test func aWholeDisplayCoverLeavesAJudgedPromptClear() {
        // Another app's window above the covers makes the plan whole; the prompt (judged) keeps its hole.
        let above = WindowInfo(number: 9, ownerPID: 700, layer: CoverLevel.canvas, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let plan = coveredBehind(pipeline(), [above, prompt(), app])
        #expect(plan.wholeDisplay == .windowAboveCovers)
        #expect(plan.promptHoles == [promptRect])
        #expect(clear(plan, promptRect))
        let pieces = CoverLayout.layerPieces(plan)
        #expect(pieces.filter { $0.wayOut == .belowCard }.count == 1, "the way out, once, on the largest piece")
        // A display that cannot be judged has no hole at all.
        let p = pipeline()
        _ = coveredBehind(p, [prompt(), app])
        #expect(p.cover(because: .streamStopped).promptHoles.isEmpty)
    }

    /// Flagged content appearing inside an open hole closes it at once and is covered, normal and whole-display mode.
    @Test func flaggedContentAppearingInsideAnOpenHoleIsCovered() {
        let above = WindowInfo(number: 9, ownerPID: 700, layer: CoverLevel.canvas, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        for windows in [[prompt(), app], [above, prompt(), app]] {
            let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [42], callWallMs: .infinity)
            let open = coveredBehind(p, windows)
            #expect(clear(open, promptRect), "open first")
            var img = Fixtures.blank(600, 400)
            Fixtures.paintFlagged(&img, PixelRect(x: 240, y: 150, w: 100, h: 100))
            var early: [CoverPlan] = []
            let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 232, y: 142, w: 116, h: 116)], t: 0.2),
                                 snapshot: WindowSnapshot(windows: windows, time: 0.2), now: 0.2) { early.append($0) }
            let pic = CGRect(x: 240, y: 150, width: 100, height: 100)
            #expect(fullyCovered(plan, pic), "\(windows.count) windows: the flagged picture in the hole is covered")
            #expect(early.allSatisfy { fullyCovered($0, pic) }, "never shown before it is judged")
        }
    }

    @Test func aSmallChangeLeftUnjudgedStaysCoveredWhileTheHoleStaysOpen() {
        let j = PerWindowScript()
        let p = pipeline(j)
        #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
        // A change of about a tenth of the prompt, away from any picture, that cannot be judged now.
        j.unjudged = [JudgeTarget.window(number: 50, ownerPID: 900).contextID]
        // 40 by 40 points across four of its 32-pixel blocks (4096 of 32000 square points: 12.8%).
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, PixelRect(x: 240, y: 160, w: 40, h: 40), channel: nil, seed: 9)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 236, y: 156, w: 48, h: 48)], t: 0.2),
                             snapshot: WindowSnapshot(windows: [prompt(), app], time: 0.2), now: 0.2)
        #expect(plan.promptHoles == [promptRect], "the hole stays")
        #expect(fullyCovered(plan, CGRect(x: 240, y: 160, width: 40, height: 40)), "the change stays covered until judged")
        // (A change that could hold a picture is judged over the whole prompt; left unjudged, that is blurred too.)
    }

    /// Blocks of the prompt's 32-pixel grid (from its corner), painted with texture: `n` of them, row by row.
    func paintBlocks(_ n: Int, seed: UInt32 = 4) -> RGBAImage {
        var img = Fixtures.blank(600, 400)
        for k in 0..<n {
            let x = 200 + 32 * (k % 6), y = 120 + 32 * (k / 6)
            Fixtures.paint(&img, PixelRect(x: x, y: y, w: 32, h: 32), channel: nil, seed: seed + UInt32(k))
        }
        return img
    }

    /// 25% of the prompt (200 by 160 points) is 8000 square points: 7 blocks (7168) stay under, 8 (8192) go over.
    @Test func theQuarterBoundaryDecidesBetweenCoveringBlocksAndClosingTheHole() {
        for (n, closes) in [(7, false), (8, true)] {
            let j = PerWindowScript()
            let p = pipeline(j)
            #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
            j.unjudged = [JudgeTarget.window(number: 50, ownerPID: 900).contextID]
            let plan = p.process(Fixtures.frame(paintBlocks(n), display: d, scale: 1, dirty: [PixelRect(x: 200, y: 120, w: 200, h: 64)], t: 0.2),
                                 snapshot: WindowSnapshot(windows: [prompt(), app], time: 0.2), now: 0.2)
            #expect(plan.promptHoles.isEmpty == closes, "\(n) blocks")
            #expect(fullyCovered(plan, CGRect(x: 200, y: 120, width: 192, height: 32)), "\(n) blocks: the change is covered either way")
        }
    }

    @Test func aPictureAppearingInAPromptWithNoneKeepsTheHoleAndIsCovered() {
        // A blank prompt (the finder sees no picture), then a 64 by 64 flagged picture appears in it: 12.8% of it.
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [42], callWallMs: .infinity)
        #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
        #expect(p.promptPictures[.window(number: 50, ownerPID: 900)] == [], "no picture seen in the blank prompt")
        var img = Fixtures.blank(600, 400)
        Fixtures.paintFlagged(&img, PixelRect(x: 260, y: 160, w: 64, h: 64))
        let pic = CGRect(x: 260, y: 160, width: 64, height: 64)
        var early: [CoverPlan] = []
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 256, y: 152, w: 72, h: 80)], t: 0.2),
                             snapshot: WindowSnapshot(windows: [prompt(), app], time: 0.2), now: 0.2) { early.append($0) }
        #expect(plan.promptHoles == [promptRect], "the hole stays open")
        #expect(fullyCovered(plan, pic), "the flagged picture is covered")
        #expect(early.allSatisfy { fullyCovered($0, pic) }, "and never shown before")
    }

    @Test func aPromptReplacedPieceByPieceIsJudgedWholeAgain() {
        let j = PerWindowScript()
        let p = pipeline(j)
        #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
        let whole = PixelRect(x: 200, y: 120, w: 200, h: 160)
        let id = JudgeTarget.window(number: 50, ownerPID: 900).contextID
        var img = Fixtures.blank(600, 400)
        var closedAt: Int?
        // Four thin strips, one block row each (each a fifth of the prompt): small one by one, not added up.
        for k in 0..<4 {
            j.areas = []
            Fixtures.paint(&img, PixelRect(x: 200, y: 120 + 40 * k, w: 200, h: 6), channel: nil, seed: 20 + UInt32(k))
            let t = 0.2 + 0.1 * Double(k)
            _ = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 200, y: 120 + 40 * k, w: 200, h: 8)], t: t),
                          snapshot: WindowSnapshot(windows: [prompt(), app], time: t), now: t)
            if closedAt == nil, j.areas.contains(where: { $0.id == id && $0.area == whole }) { closedAt = k }
        }
        #expect(closedAt == 1, "the second strip takes the changes past a quarter: judged whole again (\(String(describing: closedAt)))")
    }

    /// A prompt whose every judgement faults is retried within the budget: no extra looks, the floor at most once a
    /// second, the other windows still judged, the prompt still covered.
    @Test func aPromptThatAlwaysFaultsTakesNoMoreThanItsShare() {
        let j = PerWindowScript()
        let promptID = JudgeTarget.window(number: 50, ownerPID: 900).contextID
        j.faulty = [promptID]
        let p = DisplayPipeline(display: d, judger: j, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [42], callWallMs: .infinity)
        let windows = [prompt(), app]
        _ = p.process(Fixtures.frame(Fixtures.blank(600, 400), display: d, scale: 1, t: 0), snapshot: WindowSnapshot(windows: windows, time: 0), now: 0)
        // The first look after the display was covered whole is not held to the budget (by design): counted from here.
        j.areas = []
        var appCalls = 0, plan = CoverPlan.clear(d)
        // Four seconds: something changes in the app every quarter of a second, and idle looks between when asked for.
        for k in 1...32 {
            let t = Double(k) / 8
            let before = j.calls.count
            if k % 2 == 0 {
                plan = p.process(touched(k, t: t), snapshot: WindowSnapshot(windows: windows, time: t), now: t)
            } else if p.needsAnotherLook {
                plan = p.process(CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t), snapshot: WindowSnapshot(windows: windows, time: t), now: t)
            }
            appCalls += j.calls[before...].filter { $0 == JudgeTarget.window(number: 1, ownerPID: 500).contextID }.count
            #expect(fullyCovered(plan, promptRect) || plan.wholeDisplay != nil, "look \(k): covered")
        }
        let spent = j.areas.filter { $0.id == promptID }.reduce(0) { $0 + $1.budget }
        #expect(Double(spent) <= Register.JUDGEMENT_BURST + 4 * Register.JUDGEMENT_BUDGET + 5 * Double(DisplayPipeline.promptFloor), "\(spent) judgements")
        #expect(appCalls >= 10, "the app's window is still judged (\(appCalls) calls)")
        #expect(!p.promptLookDue, "a faulting prompt asks for no extra looks")
    }

    @Test func aMovedPromptClosesItsHoleOnALookAndOnALookWithNothingToJudge() {
        let j = PerWindowScript()
        j.unjudged = []
        let p = pipeline(j)
        #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
        let shifted = promptRect.offsetBy(dx: 40, dy: 0)
        // A "started" frame (no look) with the prompt moved: its hole is not carried to the new place.
        let started = CapturedFrame(display: d, status: .started, image: nil, map: nil, dirty: nil, time: 0.2)
        let s1 = p.process(started, snapshot: WindowSnapshot(windows: [prompt(bounds: shifted), app], time: 0.2), now: 0.2)
        #expect(s1.covers(shifted) && s1.promptHoles.isEmpty)
        // A look with the prompt moved, its new place left unjudged: closed.
        let q = pipeline(j)
        #expect(clear(coveredBehind(q, [prompt(), app]), promptRect))
        j.unjudged = [JudgeTarget.window(number: 50, ownerPID: 900).contextID]
        let s2 = q.process(touched(5, t: 0.3), snapshot: WindowSnapshot(windows: [prompt(bounds: shifted), app], time: 0.3), now: 0.3)
        #expect(s2.covers(shifted) && s2.promptHoles.isEmpty)
    }

    @Test func aPartialJudgementThenOverloadKeepsTheHoleClosed() {
        // The prompt judged in part (half clean, the rest left unjudged), then left unjudged: the hole never opens.
        let j = PerWindowScript()
        let p = pipeline(j)
        let promptID = JudgeTarget.window(number: 50, ownerPID: 900).contextID
        j.partial = [promptID]
        let first = coveredBehind(p, [prompt(), app])
        #expect(fullyCovered(first, promptRect) && first.promptHoles.isEmpty)
        #expect(!p.promptJudged.contains(.window(number: 50, ownerPID: 900)))
        j.partial = []; j.unjudged = [promptID]
        for k in 2...4 {
            let t = Double(k) / 10
            let plan = p.process(touched(k, t: t), snapshot: WindowSnapshot(windows: [prompt(), app], time: t), now: t)
            #expect(plan.covers(promptRect) && plan.promptHoles.isEmpty, "look \(k)")
        }
    }

    @Test func aWindowAtThePromptsLevelThatIsNotThePromptStaysUnderAWholeDisplayCover() {
        let above = WindowInfo(number: 9, ownerPID: 700, layer: CoverLevel.canvas, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let lookalike = WindowInfo(number: 51, ownerPID: 901, layer: PasswordPrompt.level, bounds: promptRect)
        let plan = coveredBehind(pipeline(), [above, lookalike, app])
        #expect(plan.wholeDisplay == .windowAboveCovers && plan.promptHoles.isEmpty)
        #expect(fullyCovered(plan, promptRect))
    }

    // MARK: Changes inside an open hole

    /// A frame with a small block inside the prompt (a caret, a password dot) drawn or not.
    func caret(_ on: Bool, at x: Int = 260, t: TimeInterval, extra: ((inout RGBAImage) -> Void)? = nil) -> CapturedFrame {
        var img = Fixtures.blank(600, 400)
        if on { for y in 200..<214 { for xx in x..<(x + 2) { let p = (y * 600 + xx) * 4; img.pixels[p] = 20; img.pixels[p + 1] = 20; img.pixels[p + 2] = 20 } } }
        extra?(&img)
        return Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: x - 8, y: 192, w: 24, h: 32)], t: t)
    }
    let caretRect = CGRect(x: 260, y: 200, width: 2, height: 14)

    @Test func aBlinkingCaretKeepsTheHoleOpenAndIsJudgedWithinTheBudget() {
        let above = WindowInfo(number: 9, ownerPID: 700, layer: CoverLevel.canvas, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        for windows in [[prompt(), app], [above, prompt(), app]] {
            let j = CountingJudge()
            let p = DisplayPipeline(display: d, judger: j, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [42], callWallMs: .infinity)
            #expect(clear(coveredBehind(p, windows), promptRect), "open first")
            let promptID = JudgeTarget.window(number: 50, ownerPID: 900).contextID
            let before = j.judgements[promptID] ?? 0
            var judgements = 0, closed = 0
            // Two seconds at 30 frames a second, the caret on and off every frame.
            for k in 0..<60 {
                let t = 0.2 + Double(k) / 30
                let plan = p.process(caret(k % 2 == 0, t: t), snapshot: WindowSnapshot(windows: windows, time: t), now: t)
                judgements += p.lastTimings.judgements
                if plan.promptHoles.isEmpty { closed += 1 }
                // The rest of the prompt, the field typed into included, stays in sight.
                #expect(clear(plan, CGRect(x: 200, y: 120, width: 50, height: 160)) && clear(plan, CGRect(x: 280, y: 120, width: 120, height: 160)),
                        "\(windows.count) windows, frame \(k)")
                // Nothing of the prompt's asks for another look between blinks (the app's own cover may).
                #expect(!p.promptLookDue && p.promptCoverFirst.isEmpty, "frame \(k): the caret was judged in its own look")
            }
            #expect(closed == 0, "the hole never closes for a caret")
            let forCaret = (j.judgements[promptID] ?? 0) - before
            // A caret holds no picture: the 60 frames cost a handful of judgements in all (the regular re-judges and the
            // clean checks of its two states, `VerdictCache.CLEAN_CHECKS` each), not some every frame. (10 with two checks.)
            #expect(forCaret <= 5 * VerdictCache.CLEAN_CHECKS, "a caret, no picture: about nothing to judge (\(forCaret) in 60 frames)")
            #expect(Double(judgements) <= Register.JUDGEMENT_BURST + 2 * Register.JUDGEMENT_BUDGET + 1, "\(judgements) judgements in 2 s: within the budget")
        }
    }

    @Test func aPreviewPlanCoversOnlyTheChangedBlocksInsideTheHole() {
        let above = WindowInfo(number: 9, ownerPID: 700, layer: CoverLevel.canvas, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        for top in [[WindowInfo](), [above]] {
            let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 1e6, ignoredPIDs: [42], callWallMs: .infinity)
            let other = WindowInfo(number: 3, ownerPID: 600, layer: 0, bounds: CGRect(x: 450, y: 300, width: 100, height: 80))
            #expect(clear(coveredBehind(p, top + [prompt(), other, app]), promptRect))
            // Another window moves (an early plan is drawn for it) while the caret appears in the prompt.
            let moved = WindowInfo(number: 3, ownerPID: 600, layer: 0, bounds: CGRect(x: 460, y: 300, width: 100, height: 80))
            var early: [CoverPlan] = []
            let final = p.process(caret(true, t: 0.3), snapshot: WindowSnapshot(windows: top + [prompt(), moved, app], time: 0.3), now: 0.3) { early.append($0) }
            #expect(!early.isEmpty, "an early plan was drawn")
            for e in early {
                #expect(fullyCovered(e, caretRect), "the changed block is covered until judged")
                #expect(e.promptHoles == [promptRect] && clear(e, CGRect(x: 200, y: 120, width: 30, height: 160)) && clear(e, CGRect(x: 300, y: 120, width: 100, height: 160)), "and only it (its 32-pixel block)")
            }
            #expect(clear(final, promptRect), "judged: its cover goes")
        }
    }

    @Test func aLargeChangeClosesTheWholeHole() {
        let j = PerWindowScript()
        let p = pipeline(j)
        #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
        j.unjudged = [JudgeTarget.window(number: 50, ownerPID: 900).contextID]
        // Most of the prompt changes (another request in the same window): closed, judged whole again.
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, PixelRect(x: 200, y: 120, w: 200, h: 120), channel: nil, seed: 3)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 200, y: 120, w: 200, h: 120)], t: 0.2),
                             snapshot: WindowSnapshot(windows: [prompt(), app], time: 0.2), now: 0.2)
        #expect(fullyCovered(plan, promptRect) && plan.promptHoles.isEmpty)
    }

    @Test func aPromptDroppedOnALookWithNothingToJudgeAsksForALook() {
        let p = pipeline()
        #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
        p.held = []
        let shifted = promptRect.offsetBy(dx: 40, dy: 0)
        let snap = WindowSnapshot(windows: [prompt(bounds: shifted), app], time: 0.3)
        let started = CapturedFrame(display: d, status: .started, image: nil, map: nil, dirty: nil, time: 0.3)
        _ = p.process(started, snapshot: snap, now: 0.3)
        #expect(p.needsAnotherLook, "a look is asked for")
        let idle = CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: 0.4)
        _ = p.process(idle, snapshot: snap, now: 0.4)
        #expect(p.promptJudged.contains(.window(number: 50, ownerPID: 900)), "judged at its new place on that look")
        #expect(!p.needsAnotherLook)
    }

    @Test func coversLeftOverByTheWatcherAreNeverCut() {
        // A cover added after the pipeline (no source) is drawn whole, over the hole too.
        var plan = coveredBehind(pipeline(), [prompt(), app])
        plan.items.append(CoverItem(rect: promptRect, kind: .plain))
        #expect(plan.covers(promptRect))
    }
}

@Suite struct PromptOwnerTests {
    let uids: Set<uid_t> = [501, 92]
    func agent(path: String = "/S/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent",
               uid: uid_t = 501, start: UInt64 = 7, sealed: Bool = true, id: String? = "com.apple.SecurityAgent",
               exe: String? = "SecurityAgent") -> PasswordPrompt.OwnerFacts {
        PasswordPrompt.OwnerFacts(executablePath: path, uid: uid, startTime: start, onSealedSystemVolume: sealed, bundleID: id, bundleExecutable: exe)
    }

    @Test func onlyApplesAgentOnTheSealedVolumeQualifies() {
        #expect(PasswordPrompt.ownerQualifies(agent(), allowedUIDs: uids))
        // SecurityAgent's helpers host third-party authorization plug-ins: never the prompt, on the sealed volume or not.
        for arch in ["arm64", "x86_64"] {
            #expect(!PasswordPrompt.ownerQualifies(agent(path: "/x/SecurityAgent.bundle/Contents/XPCServices/SecurityAgentHelper-\(arch).xpc/Contents/MacOS/SecurityAgentHelper-\(arch)",
                                                         id: "com.apple.SecurityAgentHelper.\(arch)", exe: "SecurityAgentHelper-\(arch)"), allowedUIDs: uids))
        }
        #expect(PasswordPrompt.bundleIDs == ["com.apple.SecurityAgent"])
        // A program named SecurityAgent, or an app claiming its bundle identifier, anywhere but the sealed volume.
        #expect(!PasswordPrompt.ownerQualifies(agent(path: "/Users/someone/SecurityAgent.bundle/Contents/MacOS/SecurityAgent", sealed: false), allowedUIDs: uids))
        // Apple's own other programs on the sealed volume.
        #expect(!PasswordPrompt.ownerQualifies(agent(path: "/S/Library/CoreServices/Dock.app/Contents/MacOS/Dock", id: "com.apple.dock", exe: "Dock"), allowedUIDs: uids))
        #expect(!PasswordPrompt.ownerQualifies(agent(id: nil, exe: nil), allowedUIDs: uids), "no bundle")
        #expect(!PasswordPrompt.ownerQualifies(agent(exe: "Other"), allowedUIDs: uids), "not the bundle's own executable")
        #expect(!PasswordPrompt.ownerQualifies(agent(uid: 0), allowedUIDs: uids), "another user")
    }

    @Test func eachWindowIsCheckedOncePerAppearanceAndAnyDoubtIsNo() {
        var facts = agent()
        var start: UInt64? = 7
        var fail = false
        let owners = PromptOwners(facts: { _ in
            if fail { throw SystemProcessFacts.Failure.noPath }
            return facts
        }, startTime: { _ in start }, allowedUIDs: { [501] }, systemIntact: { true })
        #expect(owners.isPrompt(number: 1, pid: 900))
        #expect(owners.isPrompt(number: 1, pid: 900))
        #expect(owners.checks == 1, "checked once while it stays listed")
        // Another window of the same process is checked on its own.
        #expect(owners.isPrompt(number: 2, pid: 900) && owners.checks == 2)
        // The window leaves the list and comes back: checked again, and this time the check throws.
        owners.keep(only: [])
        fail = true
        #expect(!owners.isPrompt(number: 1, pid: 900), "a check that throws covers")
        // The process identifier now belongs to another process (another start time): checked again.
        fail = false
        start = 8
        #expect(!owners.isPrompt(number: 1, pid: 900), "facts read for start 7, process started at 8")
        facts.startTime = 8
        facts.executablePath = "/Applications/Fake.app/Contents/MacOS/SecurityAgent"
        facts.onSealedSystemVolume = false
        #expect(!owners.isPrompt(number: 1, pid: 900), "path off the sealed volume")
        // No start time (the process is gone), or no owner: no.
        start = nil
        #expect(!owners.isPrompt(number: 1, pid: 900))
        #expect(!owners.isPrompt(number: 1, pid: 0))
    }

    @Test func withSystemIntegrityProtectionOrAuthenticatedRootOffNoWindowIsThePrompt() {
        var intact = true
        let owners = PromptOwners(facts: { _ in self.agent() }, startTime: { _ in 7 }, allowedUIDs: { [501] }, systemIntact: { intact })
        #expect(owners.isPrompt(number: 1, pid: 900))
        intact = false
        #expect(!owners.isPrompt(number: 1, pid: 900), "asked every time, even for a window already checked")
        // The configuration as the kernel reports it: unreadable, or any relaxation set, is not intact.
        #expect(SystemIntegrity.intact(read: { $0.pointee = 0; return 0 }))
        #expect(!SystemIntegrity.intact(read: { $0.pointee = 0; return -1 }), "unreadable")
        // Every known relaxation, unrestricted NVRAM (0x40) among them, and a bit unknown today.
        for bit: UInt32 in [0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000, 0x8000_0000] {
            #expect(!SystemIntegrity.intact(read: { $0.pointee = bit; return 0 }), "relaxation \(bit)")
        }
        // The real call can be made here (whatever this Mac's answer).
        _ = SystemIntegrity.intact()
    }

    @Test func theRealFactsRefuseThisTestAndLaunchd() throws {
        // This test process is not on the sealed volume (or has no SecurityAgent bundle); launchd is on it but has no
        // bundle. Neither is the prompt.
        let own = try SystemProcessFacts.read(getpid())
        #expect(!PasswordPrompt.ownerQualifies(own, allowedUIDs: SystemProcessFacts.promptUIDs()))
        #expect(own.startTime == SystemProcessFacts.startTime(getpid()))
        if let root = try? SystemProcessFacts.read(1) {
            #expect(root.bundleID == nil && !PasswordPrompt.ownerQualifies(root, allowedUIDs: [0]))
        }
        #expect(throws: (any Error).self) { try SystemProcessFacts.read(-1) }
        #expect(!SystemProcessFacts.promptUIDs().contains(0))
    }
}
