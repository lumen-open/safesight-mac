// SPDX-License-Identifier: Apache-2.0
// The repair card repeats the way out, in plain words, and offers Pause only in the practice state.
// Its views are built offscreen; no window is shown.
import AppKit
import Testing
@testable import SafeSightMacCore
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@MainActor @Suite struct RepairCardTests {
    func views(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(views) }

    @Test(arguments: [CoverTheme.light, .dark])
    func theCardRepeatsTheKeyboardHints(_ t: CoverTheme) throws {
        let v = RepairCardView.make(cause: .displayChanging, pause: true, theme: t, target: nil, tryAgain: nil, pause: nil, quit: nil)
        let hint = try #require(views(v).first { $0.accessibilityLabel() == AppText.wayOutLine } as? NSImageView)
        #expect(hint.image != nil)
        #expect(v.bounds.contains(hint.frame))
        let texts = views(v).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts.contains(AppText.repairHeading))
        #expect(texts.contains(FaultCause.displayChanging.plainWords))
        let buttons = views(v).compactMap { ($0 as? NSButton)?.title }
        #expect(buttons == [AppText.repairTryAgain, AppText.repairPause, AppText.repairQuit])
        #expect(views(v).allSatisfy { v.bounds.contains($0.frame) || $0.superview !== v }, "everything fits on the card")
    }

    @Test func pauseIsOfferedOnlyInThePracticeState() {
        let v = RepairCardView.make(cause: .notYetJudged, pause: false, theme: .light, target: nil, tryAgain: nil, pause: nil, quit: nil)
        #expect(views(v).compactMap { ($0 as? NSButton)?.title } == [AppText.repairTryAgain, AppText.repairQuit])
    }
}
