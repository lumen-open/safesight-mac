// SPDX-License-Identifier: Apache-2.0
// The desert theme: words that read clearly in both appearances, colours that follow the appearance in the
// app's windows, headings in the system serif, and the "How it works" page built offscreen. No window is shown.
import AppKit
import Testing
@testable import SafeSightMacCore
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@MainActor @Suite struct ThemeTests {
    func views(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(views) }

    @Test(arguments: [CoverTheme.light, .dark])
    func wordsReadClearly(_ t: CoverTheme) {
        for ground in [t.card, t.background] {
            #expect(t.text.contrast(ground) >= 7, "words: at least 7 to 1")
            #expect(t.muted.contrast(ground) >= 7, "quieter words: at least 7 to 1")
        }
        #expect(t.onAccent.contrast(t.accent) >= 4.5, "the words on Try again: at least 4.5 to 1")
        #expect(t.accentText.contrast(t.softAccent) >= 4.5, "the mark on its wash: at least 4.5 to 1")
    }

    @Test func colourFollowsTheAppearance() throws {
        let c = CoverTheme.dynamic(\.background)
        for (name, theme) in [(NSAppearance.Name.aqua, CoverTheme.light), (.darkAqua, .dark)] {
            var seen: NSColor?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { seen = c.usingColorSpace(.sRGB) }
            let rgb = try #require(seen)
            #expect(Int((rgb.redComponent * 255).rounded()) == Int(theme.background.r))
            #expect(Int((rgb.greenComponent * 255).rounded()) == Int(theme.background.g))
            #expect(Int((rgb.blueComponent * 255).rounded()) == Int(theme.background.b))
        }
    }

    @Test func headingsAreSerifAndTheRestStaysSans() {
        let serif = CoverTheme.heading(18), sans = CoverTheme.body(13)
        #expect(serif.familyName != sans.familyName)
        #expect(serif.familyName == CoverTheme.heading(13).familyName)
        #expect(sans.familyName == NSFont.systemFont(ofSize: 13).familyName)
    }

    @Test(arguments: [CoverTheme.light, .dark])
    func theRepairCardHeadingIsSerifAndItsWordsUseTheTheme(_ t: CoverTheme) throws {
        let v = RepairCardView.make(cause: .displayChanging, pause: false, theme: t, target: nil, tryAgain: nil, pause: nil, quit: nil)
        let fields = views(v).compactMap { $0 as? NSTextField }
        let heading = try #require(fields.first { $0.stringValue == AppText.repairHeading })
        #expect(heading.font?.familyName == CoverTheme.heading(18).familyName)
        let words = try #require(fields.first { $0.stringValue == AppText.repairDetail })
        #expect(words.font?.familyName == NSFont.systemFont(ofSize: 12).familyName)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theHowItWorksPageHoldsEveryWordAndFits(_ look: NSAppearance.Name) {
        let page = HowItWorksView.make()
        page.appearance = NSAppearance(named: look)
        let texts = views(page).compactMap { ($0 as? NSTextField)?.stringValue }
        for p in AppText.howItWorksBody { #expect(texts.contains(p)) }
        #expect(texts.contains(AppText.honestPromise), "the honest promise, word for word")
        #expect(views(page).allSatisfy { v in v.superview.map { $0.bounds.contains(v.frame) } ?? false }, "everything fits on the page")
    }
}
