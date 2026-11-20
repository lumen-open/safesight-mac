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
    var calls: [UInt64] = []
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        calls.append(context.windowID)
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

    @Test func aChangeInsideAnOpenHoleClosesItUntilJudgedAgain() {
        let j = PerWindowScript()
        let p = pipeline(j)
        #expect(clear(coveredBehind(p, [prompt(), app]), promptRect))
        // A new request in the same window (its pixels change) that cannot be judged now: closed.
        j.unjudged = [JudgeTarget.window(number: 50, ownerPID: 900).contextID]
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, PixelRect(x: 220, y: 140, w: 60, h: 60), channel: nil, seed: 9)
        let plan = p.process(Fixtures.frame(img, display: d, scale: 1, dirty: [PixelRect(x: 216, y: 136, w: 68, h: 68)], t: 0.2),
                             snapshot: WindowSnapshot(windows: [prompt(), app], time: 0.2), now: 0.2)
        #expect(plan.covers(promptRect) && plan.promptHoles.isEmpty)
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
        for bit: UInt32 in [0x1, 0x2, 0x4, 0x8, 0x20, 0x200, 0x400, 0x800] {
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
