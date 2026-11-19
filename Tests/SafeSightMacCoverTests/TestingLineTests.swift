// SPDX-License-Identifier: Apache-2.0
// The Testing edition's line on what it draws: under the way out on whole-window and whole-display covers, on any
// cover that hides half a display, and on the repair card, which sits on a covered display. The release edition
// draws none of it. Layers and views are built offscreen; no window is shown, nothing is captured.
import AppKit
import QuartzCore
import Testing
@testable import SafeSightMacCore
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@Suite struct TestingLineTests {
    let display = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1280, height: 800))
    let testing = CoverNotice.testing(shortcut: true)

    func layers(_ plan: CoverPlan, _ notice: CoverNotice?, _ theme: CoverTheme = .light) -> [CALayer] {
        CoverDrawing.layers(for: plan, theme: theme, scale: 2, notice: notice)
    }
    func pill(_ l: CALayer) -> CGRect { l.frame.insetBy(dx: WayOutArt.shadowRoom, dy: WayOutArt.shadowRoom) }

    @Test(arguments: [CoverTheme.light, .dark])
    func aWholeDisplayCoverSaysItIsATestAndHowToQuit(_ theme: CoverTheme) throws {
        let plan = CoverPlan.covered(display, because: .displayChanging)
        let all = layers(plan, testing, theme)
        let way = try #require(all.compactMap { $0 as? WayOutLayer }.first)
        let line = try #require(all.compactMap { $0 as? TestingLineLayer }.first)
        #expect(all.compactMap { $0 as? TestingLineLayer }.count == 1)
        #expect(line.text == "Testing edition: no lock. Quit any time with ⌃⌥⌘Q.")
        #expect(line.contents != nil, "drawn as an image, never a control")
        // On the display, under the way out, not touching it.
        #expect(CGRect(origin: .zero, size: display.bounds.size).contains(line.frame))
        #expect(pill(line).maxY + WayOutArt.lineGap <= pill(way).minY + 0.5)
        #expect(!pill(line).intersects(pill(way)))
        // Drawn over the cover.
        #expect(all.firstIndex { $0 === line }! > all.firstIndex { !($0 is WayOutLayer) && !($0 is TestingLineLayer) }!)
    }

    @Test func aWholeWindowCoverSaysItToo() throws {
        let piece = CGRect(x: 140, y: 148, width: 1000, height: 548)
        let plan = CoverPlan(display: display, items: [CoverItem(rect: piece, kind: .plain, wayOut: true)])
        let all = layers(plan, testing)
        let way = try #require(all.compactMap { $0 as? WayOutLayer }.first)
        let line = try #require(all.compactMap { $0 as? TestingLineLayer }.first)
        let cover = CoordinateSpace.toCanvasLayer(piece, display: display.bounds)
        #expect(cover.insetBy(dx: WayOutArt.margin - WayOutArt.shadowRoom, dy: WayOutArt.margin - WayOutArt.shadowRoom).contains(line.frame))
        #expect(!pill(line).intersects(pill(way)))
    }

    @Test func aCoverHidingHalfTheDisplayCarriesTheLineEvenOverAPicture() throws {
        let big = CoverPlan(display: display, items: [CoverItem(rect: CGRect(x: 0, y: 0, width: 1000, height: 700), kind: .plain)])
        let small = CoverPlan(display: display, items: [CoverItem(rect: CGRect(x: 100, y: 100, width: 600, height: 400), kind: .plain)])
        let line = try #require(layers(big, testing).compactMap { $0 as? TestingLineLayer }.first)
        #expect(CoordinateSpace.toCanvasLayer(CGRect(x: 0, y: 0, width: 1000, height: 700), display: display.bounds).contains(line.frame))
        #expect(layers(big, testing).compactMap { $0 as? WayOutLayer }.isEmpty, "a picture cover gets no way-out line")
        #expect(layers(small, testing).compactMap { $0 as? TestingLineLayer }.isEmpty, "a picture cover under half the display stays wordless")
    }

    @Test func withoutTheShortcutTheLineNamesNoShortcut() throws {
        let plan = CoverPlan.covered(display, because: .judgingBehind)
        let line = try #require(layers(plan, .testing(shortcut: false)).compactMap { $0 as? TestingLineLayer }.first)
        #expect(line.text == AppText.testingLineNoShortcut)
        #expect(!line.text.contains("⌃⌥⌘Q"))
    }

    @Test func theReleaseEditionDrawsNoTestingLine() {
        for plan in [CoverPlan.covered(display, because: .displayChanging),
                     CoverPlan(display: display, items: [CoverItem(rect: CGRect(x: 0, y: 0, width: 1280, height: 800), kind: .plain, wayOut: true)])] {
            #expect(layers(plan, nil).allSatisfy { !($0 is TestingLineLayer) })
            #expect(!layers(plan, nil).isEmpty)
        }
    }

    @Test func theOverlayFormDrawsTheLineInsideItsOwnWindow() throws {
        let plan = CoverPlan.covered(display, because: .notYetJudged)
        var p = try #require(CoverLayout.overlayPieces(plan, primaryHeight: 800).first)
        p.frame.origin = .zero
        let all = CoverDrawing.layers(for: [p], theme: .light, scale: 2, notice: testing, displayArea: 1280 * 800)
        let line = try #require(all.compactMap { $0 as? TestingLineLayer }.first)
        #expect(p.frame.contains(line.frame))
    }

    @Test func aNarrowCoverGetsTheCompactLineOrNone() throws {
        let compact = WayOutArt.pillSize(.compact, .light, .testing(shortcut: true))
        #expect(compact.width < WayOutArt.pillSize(.regular, .light, .testing(shortcut: true)).width)
        let narrow = CGRect(x: 0, y: 0, width: compact.width + 2 * WayOutArt.margin + 4, height: 400)
        let n = try #require(layers(CoverPlan(display: display, items: [CoverItem(rect: narrow, kind: .plain, wayOut: true)]), testing)
            .compactMap { $0 as? TestingLineLayer }.first)
        #expect(n.size == .compact)
        let tiny = CGRect(x: 0, y: 0, width: compact.width, height: 400)
        #expect(layers(CoverPlan(display: display, items: [CoverItem(rect: tiny, kind: .plain, wayOut: true)]), testing)
            .allSatisfy { !($0 is TestingLineLayer) })
    }

    @Test func theLineIsCutIntoWordsAndOneShortcut() {
        let pieces = AppText.testingPieces()
        #expect(pieces.map(\.text).joined() == AppText.testingLine)
        #expect(pieces.filter(\.isKey).map(\.text) == ["⌃⌥⌘Q"])
        #expect(WayOutArt.Line.testing(shortcut: true).text == AppText.testingLine)
    }
}

@MainActor @Suite struct TestingCardTests {
    func views(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(views) }

    @Test(arguments: [CoverTheme.light, .dark])
    func theRepairCardCarriesTheLineUnderTheWayOut(_ t: CoverTheme) throws {
        let v = RepairCardView.make(cause: .detectorUnavailable, pause: true, theme: t, target: nil, tryAgain: nil, pause: nil, quit: nil,
                                    notice: .testing(shortcut: true))
        let way = try #require(views(v).first { $0.accessibilityLabel() == AppText.wayOutLine })
        let line = try #require(views(v).first { $0.accessibilityLabel() == AppText.testingLine } as? NSImageView)
        #expect(line.image != nil)
        #expect(v.bounds.contains(line.frame))
        #expect(line.frame.minY >= way.frame.maxY, "under the way out (the card is drawn top-down)")
        let buttons = views(v).compactMap { $0 as? NSButton }
        #expect(buttons.allSatisfy { $0.frame.minY >= line.frame.maxY }, "above the buttons")
        #expect(buttons.map(\.title) == [AppText.repairTryAgain, AppText.repairPause, AppText.repairQuit])
    }

    @Test func theReleaseCardHasNoTestingLine() {
        let v = RepairCardView.make(cause: .detectorUnavailable, pause: true, theme: .light, target: nil, tryAgain: nil, pause: nil, quit: nil)
        #expect(!views(v).contains { ($0.accessibilityLabel() ?? "").hasPrefix("Testing edition") })
    }

    @Test func theCardSitsOnACoveredDisplayNeverOnOneInUse() {
        // A third display covered for good (more than DISPLAYS_MAX): the card goes there, not over the main display.
        #expect(RepairCard.display(covered: [3], main: 1) == 3)
        #expect(RepairCard.display(covered: [2, 3], main: 1) == 2)
        // The main display covered whole: the card goes there.
        #expect(RepairCard.display(covered: [1, 3], main: 1) == 1)
        #expect(RepairCard.display(covered: [], main: 1) == nil)
    }
}

@MainActor @Suite struct HowItWorksPageTests {
    func labels(_ v: NSView) -> [NSTextField] { v.subviews.compactMap { $0 as? NSTextField } + v.subviews.flatMap(labels) }

    @Test func theTestingPageOpensWithTheLineAndTheReleasePageDoesNot() {
        let testing = labels(HowItWorksView.make(edition: .testing)).map(\.stringValue)
        #expect(testing.first == AppText.testingLine)
        #expect(testing.contains { $0.contains("Remove SafeSight Mac Testing") })
        #expect(!testing.contains { $0.contains("comes in a later version") })
        let release = labels(HowItWorksView.make(edition: .standard)).map(\.stringValue)
        #expect(!release.contains { $0.contains("Testing edition") })
        #expect(labels(HowItWorksView.make(edition: .testing, shortcut: false)).map(\.stringValue).prefix(2)
                == [AppText.testingLineNoShortcut, AppText.testingShortcutTaken])
    }

    /// Every paragraph has room for its last line even if, drawn on a Retina display, it wraps a little earlier than
    /// measured (the Testing edition's second paragraph lost its last word that way).
    @Test(arguments: Edition.allCases)
    func everyParagraphIsShownWhole(_ edition: Edition) {
        for l in labels(HowItWorksView.make(edition: edition)) {
            let storage = NSTextStorage(attributedString: l.attributedStringValue)
            // 8 points narrower than drawn: as much as a Retina rendering was seen to lose.
            let box = NSTextContainer(containerSize: CGSize(width: l.frame.width - 4 - 8, height: 10_000))
            box.lineFragmentPadding = 0
            let layout = NSLayoutManager()
            layout.addTextContainer(box)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: box)
            // A point or two between text systems is not a line; a missing line is about 18 points.
            #expect(layout.usedRect(for: box).height <= l.frame.height + 3, "\(l.stringValue.prefix(40))")
        }
    }
}
