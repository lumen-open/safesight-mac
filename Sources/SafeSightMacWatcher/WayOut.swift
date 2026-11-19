// SPDX-License-Identifier: Apache-2.0
// The way out (owner, 18 November 2026: "if pages get covered up, user NEEDS TO BE ABLE TO EXIT THE PAGE").
//
// Covers never take the pointer or the keyboard, so clicks, ⌘W and ⌘[ always reach the app underneath.
// What a big cover can hide is the controls for leaving. So:
// - a whole-window cover leaves the window's top control band uncovered (title bar, tab strip, toolbar).
//   Pictures in the band are still judged, and any cover or blur over them is still drawn;
// - a whole-display cover leaves the menu bar uncovered when the menu bar is on screen. The Dock stays
//   covered (its thumbnails of minimised windows can show pictures);
// - whole-window and whole-display covers carry one plain line saying how to leave (drawn by the cover layer).
// Nothing else is judged or covered less.
import CoreGraphics
import Foundation

public enum WayOut {
    /// The control band: the top of a window that a whole-window cover leaves uncovered, in points.
    /// Working value, not measured on real windows (ST-032): Safari, Chrome and Firefox keep their tab strip and
    /// toolbar (close and back buttons, the address field) within about 80 points of the window's top on
    /// macOS 26, and 92 leaves a little margin. A bookmarks bar below that stays covered.
    public static let controlBand: CGFloat = 92
    /// The title bar alone (the close button): a short window keeps at least this much, or half its height.
    public static let titleBar: CGFloat = 28
    /// The band never takes more than this share of a window's height.
    public static let bandShareMax: CGFloat = 1.0 / 3

    /// The band's height for a window of this height.
    public static func bandHeight(windowHeight h: CGFloat) -> CGFloat {
        guard h > 0, h.isFinite else { return 0 }
        return min(controlBand, max(min(titleBar, h / 2), h * bandShareMax))
    }

    /// The control band a whole-window cover leaves, in global points, or nil when it leaves none. Only
    /// ordinary windows (layer 0) have one. A full-screen window has none: its toolbar is hidden, and the
    /// top of the window is content.
    public static func controlBand(of w: WindowInfo, display: CGRect) -> CGRect? {
        guard w.layer == 0, w.bounds.hasArea else { return nil }
        if w.bounds.insetBy(dx: -1, dy: -1).contains(display) { return nil }
        let h = bandHeight(windowHeight: w.bounds.height)
        guard h > 0 else { return nil }
        return CGRect(x: w.bounds.minX, y: w.bounds.minY, width: w.bounds.width, height: h)
    }

    /// Whether a whole cover over this window carries the way-out line: ordinary windows (layer 0) only,
    /// not the Dock, menus, the desktop picture or other system surfaces.
    public static func carriesLine(_ w: WindowInfo) -> Bool { w.layer == 0 }

    /// Whether a whole-display cover on this display may leave its menu bar in sight: only on the main display's mirror
    /// set (the main display, the display it repeats, or a display that repeats it: they all show the main display's
    /// picture). Every other display's menu bar is covered with the rest of it. The macOS 26 menu bar is see-through,
    /// so on a display that is covered for a long time (one past `DISPLAYS_MAX`, one that cannot be captured) the strip
    /// would show unjudged content for as long as the display is attached. The main display's menu bar, the shortcuts
    /// and the repair card remain the way out.
    public static func leavesMenuBar(display id: UInt32, main: UInt32, mirrorOf: (UInt32) -> UInt32? = { _ in nil }) -> Bool {
        if id == main { return true }
        guard let a = MirrorSets.root(of: id, mirrorOf: mirrorOf), let b = MirrorSets.root(of: main, mirrorOf: mirrorOf) else { return false }
        return a == b
    }

    /// The window-list layers of the menu bar (kCGMainMenuWindowLevel 24, kCGStatusWindowLevel 25).
    public static let menuBarLayers: Set<Int> = [24, 25]
    /// No menu bar is taller than this (about 38 points on a display with a camera notch).
    public static let menuBarMax: CGFloat = 44

    /// How much of a display's top a whole-display cover leaves for the menu bar, in points: the display's
    /// menu bar height (`topInset`, its visible frame's top inset), but only while the window list shows a
    /// menu-bar window along the display's top edge. Otherwise 0 and the display is covered whole: the menu
    /// bar is hidden (a full-screen app, or "hide the menu bar"), and the top of the display shows content
    /// nobody has judged. Never more than the menu-bar window's own height or `menuBarMax`.
    public static func menuBarHeight(display d: CGRect, topInset: CGFloat, windows: [WindowInfo]) -> CGFloat {
        guard topInset > 0, topInset.isFinite, d.hasArea else { return 0 }
        let bars = windows.filter { w in
            menuBarLayers.contains(w.layer) && abs(w.bounds.minY - d.minY) <= 1 && w.bounds.height > 0
                && w.bounds.intersection(d).width >= d.width / 2
        }
        guard let tallest = bars.map(\.bounds.height).max() else { return 0 }
        return min(topInset, tallest, menuBarMax)
    }
}
