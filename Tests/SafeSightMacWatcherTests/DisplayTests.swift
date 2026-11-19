// SPDX-License-Identifier: Apache-2.0
// Every display, one rule: however a display is attached, it is covered whole until a judged frame from a current
// stream lowers its cover. The OS's display lists are faked; frames are synthetic; the real detector runs on fake
// marker models. No screen is captured and no display is touched.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

/// The OS's display lists, as a test sets them: AppKit's screens, CoreGraphics' active and online lists,
/// ScreenCaptureKit's list, each display's bounds and the display each mirror repeats.
struct FakeDisplays {
    var screens: [UInt32] = []
    var active: [UInt32] = []
    var online: [UInt32] = []
    var capture: [UInt32] = []
    var main: UInt32 = 1
    var bounds: [UInt32: CGRect] = [:]
    /// Screen frames (Cocoa points) for displays CoreGraphics gives no bounds for.
    var screenFrames: [UInt32: CGRect] = [:]
    var mirrors: [UInt32: UInt32] = [:]

    var list: DisplayList {
        let primaryHeight = bounds[main]?.height ?? 900
        let s = screens.map { id in
            DisplayList.Screen(id: id, frame: screenFrames[id] ?? CoordinateSpace.toCocoa(bounds[id] ?? .zero, primaryHeight: primaryHeight))
        }
        return DisplayList.make(screens: s, active: active, online: online, capture: capture, main: main, primaryHeight: primaryHeight,
                                bounds: { self.bounds[$0] ?? .zero }, mirrorOf: { self.mirrors[$0] })
    }

    /// A built-in display (1, main) and an external one (2) to its right, both listed everywhere.
    static var two: FakeDisplays {
        FakeDisplays(screens: [1, 2], active: [1, 2], online: [1, 2], capture: [1, 2], main: 1,
                     bounds: [1: CGRect(x: 0, y: 0, width: 300, height: 200), 2: CGRect(x: 300, y: 0, width: 300, height: 200)])
    }
}

/// A judge that runs `during` once, in the middle of a judging call, then judges as the real detector does: the main
/// thread handling a display change while the judging queue is busy.
final class MidJudgementJudge: Judging {
    let inner: Judging
    var during: (() -> Void)?
    init(_ inner: Judging) { self.inner = inner }
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        let d = during
        during = nil
        d?()
        return inner.judgeArea(frame, context: context, within: area, budget: budget, progress: progress)
    }
    func setRule(_ rule: DetectorRule) { inner.setRule(rule) }
}

extension DisplayCoverage {
    func shownPlan(_ id: UInt32, stalled: Set<UInt32> = []) -> CoverPlan? { shown(stalled: stalled).first { $0.display.id == id } }
}

@Suite struct DisplayChangeTests {
    @Test func theBeginCallMeansEveryDisplayIsAboutToChange() {
        #expect(DisplayChange(flags: [.beginConfigurationFlag]) == .willChange)
        #expect(DisplayChange(flags: [.beginConfigurationFlag, .addFlag]) == .willChange)
        let after: [CGDisplayChangeSummaryFlags] = [.addFlag, .removeFlag, .movedFlag, .setMainFlag, .setModeFlag, .enabledFlag,
                                                    .disabledFlag, .mirrorFlag, .unMirrorFlag, .desktopShapeChangedFlag, []]
        for f in after { #expect(DisplayChange(flags: f) == .didChange, "flags \(f.rawValue)") }
    }
}

@Suite struct DisplayListTests {
    @Test func everyDisplayTheOSListsGetsACanvasMainDisplayFirst() {
        var f = FakeDisplays.two
        f.active = [2, 1]; f.main = 2
        #expect(f.list.ids == [2, 1])
        #expect(f.list.descriptor(1)?.bounds == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func aScreenAndAnActiveDisplayMissingFromEachOthersListAreBothCovered() {
        // AppKit lists 2 but CoreGraphics does not (yet); CoreGraphics lists 3 but AppKit does not (yet); the capture
        // layer sees 1 and 3 only. All three get a canvas.
        var f = FakeDisplays.two
        f.screens = [1, 2]; f.active = [1, 3]; f.online = [1, 2, 3]; f.capture = [1, 3]
        f.bounds[3] = CGRect(x: -300, y: 0, width: 300, height: 200)
        #expect(f.list.ids == [1, 2, 3])
    }

    @Test func theCaptureListCanAddADisplayButNeverRemoveOne() {
        var f = FakeDisplays.two
        f.capture = [1]
        #expect(f.list.ids == [1, 2], "a display the capture layer cannot see is still covered")
        f.capture = [1, 2, 5]
        f.bounds[5] = CGRect(x: 0, y: 200, width: 300, height: 200)
        #expect(f.list.ids == [1, 2, 5], "one only the capture layer lists is covered too")
    }

    @Test func aMirrorGetsNoCanvasOfItsOwnAndDoesNotCountTowardTheLimit() {
        // 7 repeats the built-in display (hardware or AirPlay mirroring): online, not drawn on itself.
        var f = FakeDisplays.two
        f.online = [1, 2, 7]; f.mirrors = [7: 1]; f.bounds[7] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(f.list.ids == [1, 2])
        #expect(f.list.mirrors == [7: 1], "it shows display 1's picture, covers included")
        #expect(f.list.judged == [1, 2], "both real displays stay judged")
        f.capture = [1, 2, 7]
        #expect(f.list.ids == [1, 2], "even when the capture layer lists it")
    }

    @Test func aMirrorWhoseSourceIsNotDrawnOnIsCoveredAsItsOwnDisplay() {
        var f = FakeDisplays.two
        f.online = [1, 2, 7]; f.capture = [1, 2, 7]; f.mirrors = [7: 9]; f.bounds[7] = CGRect(x: 0, y: 200, width: 300, height: 200)
        #expect(f.list.ids.contains(7))
        #expect(f.list.mirrors.isEmpty)
    }

    @Test func anActiveDisplayThatRepeatsAnotherIsAMirror() {
        // Software mirroring: CoreGraphics lists every member of the set as active (and AppKit may list it as a
        // screen), and the window system draws the same windows, covers included, into each.
        var f = FakeDisplays.two
        f.mirrors = [2: 1]
        f.bounds[2] = f.bounds[1]
        #expect(f.list.ids == [1], "no canvas of its own, which would sit over the main display's and hide its menu bar")
        #expect(f.list.mirrors == [2: 1])
        #expect(f.list.judged == [1], "and no judged place or stream of its own")
    }

    @Test func aStaleMirrorRelationshipForAnExtendedDisplayStillGetsACanvas() {
        // Around un-mirroring, CoreGraphics may still say display 2 repeats display 1 while it is already extended,
        // to the right of display 1. It must keep its own canvas and its judged place.
        var f = FakeDisplays.two
        f.mirrors = [2: 1]
        #expect(f.list.ids == [1, 2])
        #expect(f.list.mirrors.isEmpty)
        #expect(f.list.judged == [1, 2])
        // Extended above or below, overlapping display 1's edge, or with bounds that cannot be read: a canvas too.
        for b in [CGRect(x: 0, y: -200, width: 300, height: 200), CGRect(x: 150, y: 100, width: 300, height: 200)] {
            f.bounds[2] = b
            #expect(f.list.ids == [1, 2], "placed at \(b)")
        }
        f.bounds[2] = .zero
        f.screenFrames[2] = CGRect(x: 300, y: 0, width: 300, height: 200)
        #expect(f.list.ids == [1, 2], "bounds that cannot be read: any doubt means a canvas")
    }

    @Test func aMirrorInsideItsSourcesBoundsIsAMirror() {
        // A hardware matte: the mirror's bounds lie inside its source's, at another origin.
        var f = FakeDisplays.two
        f.mirrors = [2: 1]
        f.bounds[2] = CGRect(x: 10, y: 10, width: 280, height: 180)
        #expect(f.list.ids == [1])
        #expect(f.list.mirrors == [2: 1])
    }

    @Test func whenTheMainDisplayIsAMirrorTheDisplayItRepeatsComesFirst() {
        var f = FakeDisplays.two
        f.active = [1, 2, 3]; f.screens = [2, 3]; f.online = [1, 2, 3]
        f.bounds[3] = CGRect(x: 0, y: 0, width: 300, height: 200)
        f.mirrors = [1: 3]
        #expect(f.list.ids == [3, 2])
        #expect(f.list.mirrors == [1: 3])
    }

    @Test func aMirrorLoopIsCoveredAsSeparateDisplays() {
        var f = FakeDisplays.two
        f.mirrors = [1: 2, 2: 1]
        #expect(f.list.ids == [1, 2], "a loop never happens in a real mirror set; covered, never left out")
    }

    @Test func theLimitIsCountedFromTheOSListsNotFromTheCaptureList() {
        var f = FakeDisplays.two
        f.active = [1, 2, 3]; f.screens = [1, 2, 3]; f.capture = [1, 3]
        f.bounds[3] = CGRect(x: 600, y: 0, width: 300, height: 200)
        #expect(f.list.judged == [1, 2])
        #expect(Register.DISPLAYS_MAX == 2)
    }

    @Test func boundsComeFromCoreGraphicsElseFromTheScreenFrame() {
        var f = FakeDisplays.two
        f.bounds[2] = .zero
        f.screenFrames[2] = CGRect(x: 300, y: 0, width: 300, height: 200)   // Cocoa: bottom-left of a 200-point primary
        #expect(f.list.descriptor(2)?.bounds == CGRect(x: 300, y: 0, width: 300, height: 200))
        f.screenFrames[2] = .zero
        #expect(f.list.ids == [1])
        #expect(f.list.unplaced == [2], "a display with no bounds anywhere is reported, not silently dropped")
    }
}

@Suite struct DisplayCoverageTests {
    let a = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
    let b = DisplayDescriptor(id: 2, bounds: CGRect(x: 300, y: 0, width: 300, height: 200))

    /// Coverage of the two fake displays, both judged clean from a first stream.
    func judgedTwo() -> (DisplayCoverage, Int) {
        let c = DisplayCoverage()
        c.reset(FakeDisplays.two.list)
        let g = c.generations.next()
        #expect(c.accept(.clear(a), generation: g))
        #expect(c.accept(.clear(b), generation: g))
        return (c, g)
    }

    @Test func everyListedDisplayStartsCoveredWholeBeforeAnyStreamExists() {
        let c = DisplayCoverage()
        c.reset(FakeDisplays.two.list)
        let shown = c.shown()
        #expect(shown.map(\.display.id) == [1, 2])
        #expect(shown.allSatisfy { $0.wholeDisplay == .notYetJudged })
        #expect(c.required == [1: 1, 2: 1], "only streams started from now on count")
        #expect(!c.accept(.clear(a), generation: 0), "a frame from no current stream lowers nothing")
    }

    @Test func theBeginCallCoversEveryDisplayAtOnceAndNoPlanLowersACoverUntilTheChangeIsDone() {
        let (c, g) = judgedTwo()
        #expect(c.shown().allSatisfy { $0.wholeDisplay == nil })
        c.hold(.change)
        #expect(c.shown().allSatisfy { $0.wholeDisplay == .displayChanging }, "every display, at once")
        #expect(!c.accept(.clear(a), generation: g))
        #expect(!c.accept(.clear(a), generation: c.generations.next()), "not even from a new stream, while the change lasts")
        c.release(.change, FakeDisplays.two.list)
        #expect(c.shown().allSatisfy { $0.wholeDisplay == .displayChanging }, "still covered after the change, until judged")
        let g2 = c.generations.next()
        #expect(c.accept(.clear(a), generation: g2))
        #expect(c.shownPlan(1)?.wholeDisplay == nil)
        #expect(c.shownPlan(2)?.wholeDisplay == .displayChanging)
    }

    @Test func aDisplayAppearingMidJudgementNeverShowsThatJudgement() throws {
        // Display 1 is judged; while a frame of it is being judged, display 2 is announced and attached (the main
        // thread handles the change while the judging queue is busy). The plan from that frame comes back afterwards.
        let c = DisplayCoverage()
        var displays = FakeDisplays.two
        displays.screens = [1]; displays.active = [1]; displays.online = [1]; displays.capture = [1]
        c.reset(displays.list)
        let judge = MidJudgementJudge(Fixtures.detector())
        let p = DisplayPipeline(display: a, judger: judge, budgetShare: 40, ignoredPIDs: [])
        let g1 = c.generations.next()
        let window = Fixtures.oneWindow(a.bounds)
        let first = p.process(Fixtures.frame(Fixtures.blank(300, 200), display: a, scale: 1, t: 0, generation: g1), snapshot: window, now: 0)
        #expect(c.accept(first, generation: g1))
        #expect(c.shownPlan(1)?.wholeDisplay == nil)

        var attached = displays
        attached.screens = [1, 2]; attached.active = [1, 2]; attached.online = [1, 2]
        judge.during = {
            c.hold(.change)        // the begin call
            c.release(.change, attached.list)         // the change is applied: display 2 is there
        }
        var next = Fixtures.blank(300, 200)
        Fixtures.paint(&next, PixelRect(x: 40, y: 40, w: 80, h: 80), channel: nil, seed: 3)
        let late = p.process(Fixtures.frame(next, display: a, scale: 1, dirty: [PixelRect(x: 40, y: 40, w: 80, h: 80)], t: 0.1, generation: g1),
                             snapshot: window, now: 0.1)
        #expect(late.wholeDisplay == nil, "the judging call itself finished normally")
        #expect(!c.accept(late, generation: g1), "but its plan, judged on a frame from before the change, is refused")
        #expect(c.shownPlan(1)?.wholeDisplay == .displayChanging)
        #expect(c.shownPlan(2)?.wholeDisplay == .displayChanging, "the new display is covered from the moment it is listed")

        // The judging queue learns the new required generation; a frame still waiting from the old stream is not judged.
        let need: Int? = c.required[1]
        #expect(need != nil)
        p.cover(because: .displayChanging, until: need)
        var stale = Fixtures.blank(300, 200)
        Fixtures.paintFlagged(&stale, PixelRect(x: 100, y: 60, w: 80, h: 80))
        let fromOldStream = p.process(Fixtures.frame(stale, display: a, scale: 1, t: 0.2, generation: g1), snapshot: window, now: 0.2)
        #expect(fromOldStream.wholeDisplay != nil && !p.judged)

        // Capture restarts: display 1 is lowered after its first judged frame; display 2 stays covered until its own.
        let g2 = c.generations.next()
        let again = p.process(Fixtures.frame(next, display: a, scale: 1, t: 0.3, generation: g2), snapshot: window, now: 0.3)
        #expect(c.accept(again, generation: g2))
        #expect(c.shownPlan(1)?.wholeDisplay == nil)
        #expect(c.shownPlan(2)?.wholeDisplay == .displayChanging)

        let pb = DisplayPipeline(display: b, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        var onB = Fixtures.blank(300, 200)
        Fixtures.paintFlagged(&onB, PixelRect(x: 100, y: 50, w: 100, h: 100))
        let firstOnB = pb.process(Fixtures.frame(onB, display: b, scale: 1, t: 0.4, generation: g2),
                                  snapshot: Fixtures.oneWindow(b.bounds, number: 20), now: 0.4)
        #expect(c.accept(firstOnB, generation: g2))
        let shownB = try #require(c.shownPlan(2))
        #expect(shownB.wholeDisplay == nil)
        #expect(shownB.covers(CGRect(x: 400, y: 50, width: 100, height: 100), kind: .plain), "its flagged picture is covered")
    }

    @Test func aDisplayTheCaptureLayerCannotSeeIsCoveredForAsLongAsItExists() {
        let c = DisplayCoverage()
        c.reset(FakeDisplays.two.list)
        c.fault(2, .noStream, generation: c.newRequest())
        for _ in 0..<5 {
            let g = c.generations.next()
            #expect(c.accept(.clear(a), generation: g))
            #expect(c.shownPlan(2)?.wholeDisplay == .noStream)
        }
        #expect(c.shownPlan(1)?.wholeDisplay == nil)
    }

    @Test func aStreamThatNeverDeliversKeepsItsDisplayCovered() {
        let c = DisplayCoverage()
        c.reset(FakeDisplays.two.list)
        let g = c.generations.next()
        // Only "started" and "idle" frames: nothing has been judged.
        let p = DisplayPipeline(display: b, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        for status in [FrameStatus.started, .idle, .started] {
            let plan = p.process(CapturedFrame(display: b, status: status, image: nil, map: nil, dirty: [], time: 0, generation: g), snapshot: .empty, now: 0)
            c.accept(plan, generation: g)
            #expect(c.shownPlan(2)?.wholeDisplay != nil)
        }
    }

    @Test func framesOfAStoppedStreamNeverLowerItsCoverAgain() {
        let (c, g) = judgedTwo()
        c.fault(2, .streamStopped, generation: g)
        #expect(c.shownPlan(2)?.wholeDisplay == .streamStopped)
        #expect(!c.accept(.clear(b), generation: g), "a frame of the stopped stream that was still waiting")
        #expect(c.shownPlan(1)?.wholeDisplay == nil, "the other display is untouched")
        #expect(c.accept(.clear(b), generation: c.generations.next()), "a new stream's frame lowers it")
    }

    @Test func aDisplayLeftWithoutAStreamIsCoveredEvenThoughItShowedAPlan() {
        // The plan came from stream g. A newer request stopped that stream and could not start another (the display
        // was not listed yet): the display must not keep showing the old plan.
        let (c, g) = judgedTwo()
        let restart = c.newRequest()
        c.retire(2, generation: g)
        c.fault(2, .noStream, generation: restart)
        #expect(c.shownPlan(2)?.wholeDisplay == .noStream)
        #expect(!c.accept(.clear(b), generation: g), "frames of the stopped stream never count again")
        // Without the retirement report too: a failed request newer than the plan's stream covers the display.
        let (c2, _) = judgedTwo()
        c2.fault(2, .noStream, generation: c2.newRequest())
        #expect(c2.shownPlan(2)?.wholeDisplay == .noStream)
    }

    @Test func aReportOlderThanTheStreamJudgingTheDisplayChangesNothingShown() {
        let (c, g) = judgedTwo()
        let topUp = c.newRequest()
        #expect(c.accept(.clear(b), generation: topUp), "display 2 is now judged by a newer stream")
        c.fault(2, .noStream, generation: g)
        c.fault(2, .streamStopped, generation: g)
        c.retire(2, generation: g)
        #expect(c.shownPlan(2)?.wholeDisplay == nil, "the newer stream runs, or its own end is reported too")
        #expect(!c.accept(.clear(b), generation: g), "but the older stream's frames never count again")
        c.fault(2, .streamStopped, generation: topUp)
        #expect(c.shownPlan(2)?.wholeDisplay == .streamStopped, "the stream that judged it stopped: covered")
        #expect(!c.accept(.clear(b), generation: topUp))
    }

    @Test func aStreamStoppedOnPurposeTakesItsPlanWithIt() {
        let (c, g) = judgedTwo()
        c.retire(2, generation: g)
        #expect(c.shownPlan(2)?.wholeDisplay == .notYetJudged)
        #expect(c.shownPlan(1)?.wholeDisplay == nil, "the other display is untouched")
        #expect(!c.accept(.clear(b), generation: g), "its frames still on their way never count")
        #expect(c.accept(.clear(b), generation: c.newRequest()))
    }

    @Test func aDisplayRemovedAndAddedBackWithTheSameIDStaysCoveredUntilJudgedAgain() {
        let (c, g) = judgedTwo()
        var one = FakeDisplays.two
        one.screens = [1]; one.active = [1]; one.online = [1]; one.capture = [1]
        c.hold(.change); c.release(.change, one.list)
        #expect(c.shown().map(\.display.id) == [1], "a removed display has no canvas left")
        _ = c.generations.next()
        c.hold(.change); c.release(.change, FakeDisplays.two.list)
        #expect(c.shownPlan(2)?.wholeDisplay == .displayChanging, "same identifier, same place: still a new display")
        #expect(!c.accept(.clear(b), generation: g), "its plan from before it was removed is refused")
        #expect(c.accept(.clear(b), generation: c.generations.next()))
    }

    @Test func aPlanForADisplaysOldBoundsIsRefused() {
        // Rearranged, rotated, a new resolution, or clamshell mode moving the origin: display 2's bounds change.
        let (c, _) = judgedTwo()
        var moved = FakeDisplays.two
        moved.bounds[2] = CGRect(x: -200, y: 0, width: 200, height: 300)
        #expect(c.update(moved.list), "a change nobody announced is still a change")
        #expect(c.shown().allSatisfy { $0.wholeDisplay == .displayChanging })
        let g = c.generations.next()
        #expect(!c.accept(.clear(b), generation: g), "a plan made for the old bounds")
        #expect(c.accept(.clear(DisplayDescriptor(id: 2, bounds: CGRect(x: -200, y: 0, width: 200, height: 300))), generation: g))
    }

    @Test func aMainDisplayChangeIsAChange() {
        let (c, _) = judgedTwo()
        var f = FakeDisplays.two
        f.main = 2
        #expect(c.update(f.list))
        #expect(c.shown().allSatisfy { $0.wholeDisplay != nil })
    }

    @Test func displaysBeyondTheLimitStayCoveredWholeEvenWhenAPlanArrives() {
        var f = FakeDisplays.two
        f.active = [1, 2, 3]; f.screens = [1, 2, 3]; f.capture = [1, 2]   // the capture layer misses the third
        f.bounds[3] = CGRect(x: 600, y: 0, width: 300, height: 200)
        let c = DisplayCoverage()
        c.reset(f.list)
        let g = c.generations.next()
        #expect(c.accept(.clear(a), generation: g))
        #expect(c.accept(.clear(b), generation: g))
        #expect(!c.accept(.clear(DisplayDescriptor(id: 3, bounds: CGRect(x: 600, y: 0, width: 300, height: 200))), generation: g))
        #expect(c.shownPlan(3)?.wholeDisplay == .tooManyDisplays)
        #expect(c.shownPlan(1)?.wholeDisplay == nil && c.shownPlan(2)?.wholeDisplay == nil)
    }

    @Test func aFailedDetectorCoversDisplaysAttachedLaterToo() {
        let c = DisplayCoverage()
        c.reset(FakeDisplays.two.list)
        c.detectorFailed = true
        var three = FakeDisplays.two
        three.active = [1, 2, 3]; three.bounds[3] = CGRect(x: 600, y: 0, width: 300, height: 200)
        c.update(three.list)
        #expect(c.shown().count == 3)
        #expect(c.shown().allSatisfy { $0.wholeDisplay == .detectorUnavailable })
    }

    @Test func aDisplayOnlyTheCaptureLayerListsPastTheLimitIsAddedWithoutTouchingTheOthers() {
        let (c, _) = judgedTwo()
        var f = FakeDisplays.two
        f.capture = [1, 2, 6]; f.bounds[6] = CGRect(x: 0, y: 400, width: 300, height: 200)
        #expect(!c.add(f.list), "the judged displays are as they were: not a change")
        #expect(c.shownPlan(6)?.wholeDisplay == .tooManyDisplays, "covered whole like any third display")
        #expect(c.shownPlan(1)?.wholeDisplay == nil && c.shownPlan(2)?.wholeDisplay == nil, "the others keep their plans")
    }

    @Test func aDisplayOnlyTheCaptureLayerListsThatIsJudgedIsAChange() {
        // It needs a stream, which only a capture restart with it among the judged displays gives it.
        var f = FakeDisplays.two
        f.screens = [1]; f.active = [1]; f.online = [1]; f.capture = [1]
        let c = DisplayCoverage()
        c.reset(f.list)
        #expect(c.accept(.clear(a), generation: c.newRequest()))
        f.capture = [1, 5]; f.bounds[5] = CGRect(x: 0, y: 200, width: 300, height: 200)
        #expect(c.add(f.list))
        #expect(c.list.judged == [1, 5])
        #expect(c.shown().allSatisfy { $0.wholeDisplay != nil }, "covered until judged by restarted streams")
    }

    @Test func aDisplayOnlyTheCaptureLayerListsThatPushesAnotherPastTheLimitIsAChange() {
        var f = FakeDisplays.two
        f.screens = [1, 5]; f.active = [1, 5]; f.online = [1, 5]; f.capture = [1, 5]
        f.bounds[5] = CGRect(x: 0, y: 200, width: 300, height: 200)
        let c = DisplayCoverage()
        c.reset(f.list)
        #expect(c.list.judged == [1, 5])
        f.capture = [1, 3, 5]; f.bounds[3] = CGRect(x: 0, y: 400, width: 300, height: 200)
        #expect(c.add(f.list), "display 5 loses its judged place: its stream must stop")
        #expect(c.list.judged == [1, 3])
        #expect(c.shownPlan(5)?.wholeDisplay == .tooManyDisplays)
    }

    @Test func aStalledDisplayIsCoveredUntilItCatchesUp() {
        let (c, _) = judgedTwo()
        #expect(c.shownPlan(2, stalled: [2])?.wholeDisplay == .judgingBehind)
        #expect(c.shownPlan(1, stalled: [2])?.wholeDisplay == nil)
        #expect(c.shownPlan(2)?.wholeDisplay == nil)
    }
}

@Suite struct PipelineGenerationTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
    var window: WindowSnapshot { Fixtures.oneWindow(d.bounds) }

    @Test func aFrameFromBeforeTheChangeIsNeverJudged() {
        let p = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        _ = p.process(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, t: 0, generation: 1), snapshot: window, now: 0)
        #expect(p.judged)
        p.cover(because: .displayChanging, until: 2)
        let old = p.process(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, t: 1, generation: 1), snapshot: window, now: 1)
        #expect(old.wholeDisplay == .displayChanging)
        #expect(!p.judged, "a frame from the old stream does not count as judging the display")
        let new = p.process(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, t: 2, generation: 2), snapshot: window, now: 2)
        #expect(new.wholeDisplay == nil)
    }

    @Test func aNewStreamsFirstFrameIsJudgedWholeNotJustItsChangedAreas() {
        // The first frame of a new stream says only a small area changed; a flagged picture elsewhere is judged anyway.
        let picture = PixelRect(x: 160, y: 40, w: 100, h: 100)
        var img = Fixtures.blank(300, 200)
        Fixtures.paintFlagged(&img, picture)
        let tiny = [PixelRect(x: 0, y: 0, w: 8, h: 8)]
        let g = CGRect(x: 160, y: 40, width: 100, height: 100)

        let sameStream = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        _ = sameStream.process(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, t: 0, generation: 1), snapshot: window, now: 0)
        // An honest frame first, so the once-a-second check of the reported areas against the pixels is not due next.
        _ = sameStream.process(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, dirty: tiny, t: 0.05, generation: 1), snapshot: window, now: 0.05)
        let same = sameStream.process(Fixtures.frame(img, display: d, scale: 1, dirty: tiny, t: 0.1, generation: 1), snapshot: window, now: 0.1)
        #expect(!same.covers(g), "within one stream only the changed areas are judged (the control case)")

        let newStream = DisplayPipeline(display: d, judger: Fixtures.detector(), budgetShare: 40, ignoredPIDs: [])
        _ = newStream.process(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, t: 0, generation: 1), snapshot: window, now: 0)
        let fresh = newStream.process(Fixtures.frame(img, display: d, scale: 1, dirty: tiny, t: 0.1, generation: 2), snapshot: window, now: 0.1)
        #expect(fresh.covers(g, kind: .plain), "a new stream's first frame is judged whole")
    }

    @Test func aLateFrameFromAnOlderStreamNeverReplacesANewerStreamsFrame() throws {
        var box = FrameMailbox()
        box.offer(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, dirty: nil, t: 1, generation: 2))
        box.offer(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, dirty: [PixelRect(x: 0, y: 0, w: 8, h: 8)], t: 2, generation: 1))
        let taken = box.take()
        let f = try #require(taken)
        #expect(f.generation == 2, "the new stream's first frame is kept: on a still screen no other may come")
        #expect(f.dirty == nil)
    }

    @Test func framesOfDifferentStreamsNeverMergeInTheMailbox() throws {
        var box = FrameMailbox()
        box.offer(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, dirty: [PixelRect(x: 0, y: 0, w: 8, h: 8)], t: 0, generation: 1))
        box.offer(Fixtures.frame(Fixtures.blank(300, 200), display: d, scale: 1, dirty: [PixelRect(x: 64, y: 64, w: 8, h: 8)], t: 1, generation: 2))
        let taken = box.take()
        let f = try #require(taken)
        #expect(f.generation == 2)
        #expect(f.dirty == [PixelRect(x: 64, y: 64, w: 8, h: 8)])
    }
}

@Suite struct FrameQueueTests {
    func frame(_ id: UInt32, _ t: Double) -> CapturedFrame {
        let d = DisplayDescriptor(id: id, bounds: CGRect(x: Double(id) * 100, y: 0, width: 100, height: 100))
        return CapturedFrame(display: d, status: .idle, image: nil, map: nil, dirty: [], time: t)
    }

    @Test func aDisplayThatNeverStopsChangingCannotKeepAnotherWaiting() {
        let q = FrameQueue()
        q.open()
        #expect(q.offer(frame(1, 0), now: 0), "the first frame schedules a drain")
        #expect(!q.offer(frame(2, 0), now: 0), "one drain at a time")
        var order: [UInt32] = []
        // Display 1 changes again while each frame is judged (a video); display 2 changes now and then.
        for i in 0..<8 {
            guard let f = q.next() else { break }
            order.append(f.display.id)
            _ = q.offer(frame(1, Double(i)), now: Double(i))
            if i == 3 { _ = q.offer(frame(2, Double(i)), now: Double(i)) }
        }
        #expect(order.prefix(2) == [1, 2], "display 2 had its turn right after display 1's frame")
        #expect(order.dropFirst(4).prefix(2).contains(2), "and again after its next change")
    }

    @Test func waitingIsMeasuredFromTheOldestFrameNotYetJudged() {
        let q = FrameQueue()
        q.open()
        _ = q.offer(frame(1, 0), now: 10)
        _ = q.offer(frame(1, 1), now: 11)   // coalesced with the first
        #expect(q.waiting(now: 16)[1] == 6)
        _ = q.next()
        #expect(q.waiting(now: 16)[1] == nil)
    }

    @Test func aClosedQueueTakesNothingAndDropsWhatWaited() {
        let q = FrameQueue()
        #expect(!q.offer(frame(1, 0), now: 0), "not open yet")
        q.open()
        _ = q.offer(frame(1, 0), now: 0)
        q.close()
        #expect(q.next() == nil)
        #expect(q.waiting(now: 1).isEmpty)
    }
}
