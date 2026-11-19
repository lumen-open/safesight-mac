// SPDX-License-Identifier: Apache-2.0
// The way-out line as the cover layer draws it: on whole-window and whole-display covers, in plain words,
// inside its cover, in both appearances. Layers are built offscreen; no window is shown, nothing is captured.
import AppKit
import CoreGraphics
import QuartzCore
import Testing
@testable import SafeSightMacCore
@testable import SafeSightMacCover
@testable import SafeSightMacWatcher

@Suite struct WayOutLineTests {
    let display = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 1280, height: 800))

    func lines(_ plan: CoverPlan, _ theme: CoverTheme = .light) -> [WayOutLayer] {
        CoverDrawing.layers(for: plan, theme: theme, scale: 2).compactMap { $0 as? WayOutLayer }
    }

    @Test(arguments: [CoverTheme.light, .dark])
    func aWholeWindowCoverSaysHowToLeave(_ theme: CoverTheme) throws {
        // The largest piece of a whole-window cover carries the line.
        let piece = CGRect(x: 140, y: 148, width: 1000, height: 548)
        let plan = CoverPlan(display: display, items: [CoverItem(rect: piece, kind: .plain, wayOut: true)])
        let found = lines(plan, theme)
        #expect(found.count == 1)
        let line = try #require(found.first)
        #expect(line.text == AppText.wayOutLine)
        #expect(line.text == "Press ⌘W to close this tab, or ⌘[ to go back.")
        #expect(line.contents != nil, "drawn as an image")
        // Inside its cover, with room to spare (layer space: display-local, y up).
        let cover = CoordinateSpace.toCanvasLayer(piece, display: display.bounds)
        #expect(cover.insetBy(dx: WayOutArt.margin - WayOutArt.shadowRoom, dy: WayOutArt.margin - WayOutArt.shadowRoom).contains(line.frame))
        // Drawn after (over) every cover.
        let all = CoverDrawing.layers(for: plan, theme: theme, scale: 2)
        #expect(all.last === all.first(where: { $0 is WayOutLayer }))
    }

    @Test(arguments: [CoverTheme.light, .dark])
    func aWholeDisplayCoverSaysHowToLeave(_ theme: CoverTheme) throws {
        let plan = CoverPlan.covered(display, because: .displayChanging)
        let line = try #require(lines(plan, theme).first)
        #expect(lines(plan, theme).count == 1)
        #expect(line.text == AppText.wayOutLine)
        #expect(CGRect(origin: .zero, size: display.bounds.size).contains(line.frame))
        // Below the middle, where the repair card is not.
        #expect(line.frame.maxY < display.bounds.height / 2 - 100)
    }

    @Test func pictureCoversStayWordlessHoweverLarge() {
        let plan = CoverPlan(display: display, items: [
            CoverItem(rect: CGRect(x: 100, y: 100, width: 900, height: 600), kind: .plain),
            CoverItem(rect: CGRect(x: 1000, y: 20, width: 40, height: 40), kind: .plain),
        ])
        #expect(lines(plan).isEmpty)
    }

    @Test func aCoverWithNoRoomShowsNoLineAndANarrowOneShowsTheCompactLine() throws {
        let regular = WayOutArt.pillSize(.regular), compact = WayOutArt.pillSize(.compact)
        #expect(compact.width < regular.width)
        let narrow = CGRect(x: 0, y: 0, width: compact.width + 2 * WayOutArt.margin + 4, height: 300)
        let n = try #require(lines(CoverPlan(display: display, items: [CoverItem(rect: narrow, kind: .plain, wayOut: true)])).first)
        #expect(n.size == .compact)
        let tiny = CGRect(x: 0, y: 0, width: compact.width, height: 300)
        #expect(lines(CoverPlan(display: display, items: [CoverItem(rect: tiny, kind: .plain, wayOut: true)])).isEmpty)
        let flat = CGRect(x: 0, y: 0, width: 900, height: compact.height + 2 * WayOutArt.margin - 1)
        #expect(lines(CoverPlan(display: display, items: [CoverItem(rect: flat, kind: .plain, wayOut: true)])).isEmpty)
    }

    @Test func theOverlayFormDrawsTheLineInsideItsOwnWindow() throws {
        let piece = CGRect(x: 140, y: 148, width: 1000, height: 548)
        let plan = CoverPlan(display: display, items: [CoverItem(rect: piece, kind: .plain, wayOut: true)])
        var p = try #require(CoverLayout.overlayPieces(plan, primaryHeight: 800).first)
        #expect(p.wayOut == .centre)
        p.frame.origin = .zero
        let line = try #require(CoverDrawing.layers(for: [p], theme: .light, scale: 2).compactMap { $0 as? WayOutLayer }.first)
        #expect(p.frame.contains(line.frame))
    }

    @Test(arguments: [CoverTheme.light, .dark])
    func theLineReadsClearly(_ t: CoverTheme) {
        #expect(t.text.contrast(t.card) >= 7, "words on the line: at least 7 to 1")
        #expect(t.keyText.contrast(t.keyFill) >= 7, "key cap letters: at least 7 to 1, the most legible thing on a cover")
        #expect(t.card.contrast(t.cover) > 1.05 || t.line.contrast(t.cover) > 1.1, "the line stands off its cover")
        // Plain neutral caps: never the accent, and quieter than it.
        #expect(t.keyFill != t.accent && t.keyText != t.accent && t.keyFill != t.softAccent)
        #expect(t.keyFill.chroma * 2 < t.accent.chroma)
    }

    @Test(arguments: [CoverTheme.light, .dark])
    func coversAreOpaqueAndNeutral(_ t: CoverTheme) throws {
        let plan = CoverPlan(display: display, items: [CoverItem(rect: CGRect(x: 10, y: 10, width: 50, height: 50), kind: .plain)])
        let cover = try #require(CoverDrawing.layers(for: plan, theme: t, scale: 2).first)
        #expect(cover.isOpaque)
        #expect(cover.backgroundColor?.alpha == 1)
        #expect(cover.opacity == 1)
        // Neutral: limestone by day, lapis-black by night. Barely any colour (the night's faint blue is the most,
        // 22 levels), far less than the accent, and never the accent or gold.
        let c = t.cover
        #expect(c.chroma <= 24)
        #expect(c.chroma * 4 < t.accent.chroma)
        #expect(c != t.accent && c != t.softAccent && c != t.gold)
    }

    @Test func theAppearanceChoosesTheTheme() {
        #expect(CoverTheme.forAppearance(NSAppearance(named: .aqua)) == .light)
        #expect(CoverTheme.forAppearance(NSAppearance(named: .darkAqua)) == .dark)
        #expect(CoverTheme.forAppearance(nil) == .light)
    }
}
