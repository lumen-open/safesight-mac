// SPDX-License-Identifier: Apache-2.0
// Where the covers sit among the window levels, and the app's own menu under them. Builds windows; shows none.
import AppKit
import Testing
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@MainActor
@Suite struct LevelTests {
    init() { _ = NSApplication.shared }

    @Test func theCanvasIsAboveTheScreenSaverAndTheAppAboveTheCanvas() {
        let saver = Int(CGWindowLevelForKey(.screenSaverWindow))
        #expect(CoverLevels.canvas.rawValue > saver)
        #expect(CoverLevels.canvas.rawValue > Int(CGWindowLevelForKey(.assistiveTechHighWindow)), "above the assistive levels")
        #expect(CoverLevels.canvas.rawValue == 1990 && CoverLevels.appAbove.rawValue == 1991)
        #expect(CoverLevels.canvas.rawValue < 2000 && CoverLevels.appAbove.rawValue < 2000, "below loginwindow (seen at 2001 and 2004)")
        #expect(CoverLevels.appAbove.rawValue < CoverLevel.lockScreenSeen)
        #expect(FaultCause.windowAboveCovers.plainWords.contains("in front of the covers"), "the repair card says why")
        #expect(CoverLevels.appAbove.rawValue > CoverLevels.canvas.rawValue)
        #expect(CoverLevels.canvas.rawValue == CoverLevel.canvas, "the cover layer checks the level the covers use")
        #expect(CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 10, height: 10)).level == CoverLevels.canvas)
    }

    @Test func theAppsOwnMenuIsLiftedAboveTheCovers() {
        let menu = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        menu.level = .popUpMenu
        let other = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        other.level = .normal
        #expect(OwnMenus.lift([menu, other], isMenu: { $0 === menu }) == 1)
        #expect(menu.level.rawValue > CoverLevels.canvas.rawValue)
        #expect(other.level == .normal)
        #expect(!OwnMenus.isMenuWindow(CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 10, height: 10))), "a cover is never lifted")
    }

    @Test func eachOpeningOfTheMenuLetsTheLastOnesHandlersGo() {
        let a = MenuActions()
        for _ in 0..<5 {
            a.begin()
            for t in ["One", "Two", "Three"] { _ = a.item(t) {} }
        }
        #expect(a.count == 3)
    }

    @Test func theCoverLayerKnowsTheCoversOwnColours() {
        for t in [CoverTheme.light, .dark] {
            let hex = UInt32(t.cover.r) << 16 | UInt32(t.cover.g) << 8 | UInt32(t.cover.b)
            #expect(OwnCoverColours.rgb.contains(hex))
        }
    }
}
