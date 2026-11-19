// SPDX-License-Identifier: Apache-2.0
// Covers stay click-through and never take focus, with the way-out line on them: clicks, ⌘W and ⌘[ reach the
// app underneath. Panels are made but never shown; nothing is drawn on the screen or captured.
import AppKit
import QuartzCore
import Testing
@testable import SafeSightMacCore
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@MainActor @Suite struct ClickThroughTests {
    init() { _ = NSApplication.shared }

    func coverPanelWithALine() -> CoverPanel {
        let p = CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 1280, height: 800))
        let plan = CoverPlan(display: DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)),
                             items: [CoverItem(rect: CGRect(x: 140, y: 148, width: 1000, height: 548), kind: .plain, wayOut: true)])
        CoverDrawing.apply(plan, to: p.contentView!.layer!, theme: .light, scale: 2)
        return p
    }

    @Test func coversLetEveryClickThrough() {
        let p = coverPanelWithALine()
        #expect(p.ignoresMouseEvents)
        #expect(p.contentView?.layer?.sublayers?.contains { $0 is WayOutLayer } == true, "the line is on the cover")
        #expect(p.contentView?.subviews.isEmpty == true, "the line is a layer, not a view: there is nothing to click")
        #expect(!p.isOpaque && p.backgroundColor == .clear, "uncovered parts of the canvas show what is under them")
    }

    @Test func coversNeverTakeFocus() {
        let p = coverPanelWithALine()
        #expect(!p.canBecomeKey, "the keyboard stays with the app underneath")
        #expect(!p.canBecomeMain)
        #expect(p.styleMask.contains(.nonactivatingPanel) && p.styleMask.contains(.borderless))
        #expect(p.contentView?.acceptsFirstResponder == false)
        #expect(p.collectionBehavior.contains(.ignoresCycle) && p.isExcludedFromWindowsMenu, "never in ⌘` or the Window menu")
        #expect(!p.hidesOnDeactivate)
        #expect(!p.isAccessibilityElement())
        #expect(p.level == CoverLevels.canvas)
        #expect(!p.isRestorable, "macOS keeps no saved state for it")
    }

    @Test func theRepairCardNeverTakesTheKeyboard() {
        let p = RepairPanel.make()
        p.contentView = RepairCardView.make(cause: .judgingBehind, pause: true, theme: .light, target: nil, tryAgain: nil, pause: nil, quit: nil)
        #expect(p.styleMask.contains(.nonactivatingPanel), "clicking it does not bring SafeSight Mac forward")
        #expect(p.becomesKeyOnlyIfNeeded)
        #expect(!p.canBecomeMain)
        func all(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(all) }
        #expect(all(p.contentView!).allSatisfy { !$0.needsPanelToBecomeKey }, "no view on it needs the keyboard, so it is never key")
        #expect(p.level.rawValue > CoverLevels.canvas.rawValue, "above the covers")
        #expect(!p.isRestorable)
    }
}
