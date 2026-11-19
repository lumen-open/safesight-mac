// SPDX-License-Identifier: Apache-2.0
// Drawing the covers (chapter 05, section 5.4). Two forms share one geometry (CoverLayout):
// - the cover canvas (default): one transparent, click-through, always-on-top panel per display that
//   holds every cover on it, all changed in one transaction;
// - per-window overlays (the written pivot of ST-032): one click-through panel per cover.
// Covers are plain: no logo, no product name, no word about what is under them. Whole-window and
// whole-display covers carry one line, the way out (WayOutArt.swift). Covers never take the keyboard or a
// click, never become key or main, stay out of window cycling and are hidden from assistive tools, so
// ⌘W, ⌘[ and clicks always reach the app underneath.
import AppKit
import SafeSightMacWatcher
import QuartzCore

public enum CoverLevels {
    /// The canvas sits above full-screen apps, the menu bar, menus, the Dock and notifications.
    /// Not specified in the register; ST-032 finds the lowest level that works per surface. Working value.
    public static let canvas = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    /// The app's own windows and the repair card sit one level above the canvas (SD-229).
    public static let appAbove = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
}

public enum CoverForm: String, Sendable {
    case canvas, overlays
    /// `SAFESIGHTMAC_COVER_FORM=overlays` selects the pivot form; the canvas is the default.
    public static var current: CoverForm {
        ProcessInfo.processInfo.environment["SAFESIGHTMAC_COVER_FORM"] == "overlays" ? .overlays : .canvas
    }
}

@MainActor
public protocol CoverPresenter: AnyObject {
    /// Applies one plan per display. Displays without a plan lose their covers.
    func apply(_ plans: [CoverPlan])
    func removeAll()
}

/// A panel that can never take focus.
final class CoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make(frame: CGRect) -> CoverPanel {
        let p = CoverPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = CoverLevels.canvas
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isExcludedFromWindowsMenu = true
        p.title = ""
        p.setAccessibilityElement(false)
        p.setAccessibilityRole(.unknown)
        let v = NSView(frame: CGRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.masksToBounds = true
        v.setAccessibilityElement(false)
        p.contentView = v
        return p
    }
}

/// The canvas's layers for one plan, built without any window. The canvas form uses it, and the lab
/// harness's bench times it on a detached layer (no window, nothing drawn on a screen); the harness also
/// renders it into its frames.
public enum CoverDrawing {
    public static func layers(for plan: CoverPlan, theme: CoverTheme = .light, scale: CGFloat = 2, menuBar: CGFloat = 0) -> [CALayer] {
        layers(for: CoverLayout.layerPieces(plan, menuBar: menuBar), theme: theme, scale: scale)
    }

    /// Every cover, then every way-out line on top (each line lies inside its own cover, with room to spare).
    public static func layers(for pieces: [CoverPiece], theme: CoverTheme, scale: CGFloat) -> [CALayer] {
        let covers: [CALayer] = pieces.map { LayerFactory.layer($0.frame, $0.kind, theme) }
        let lines: [CALayer] = pieces.compactMap { p in
            p.wayOut.flatMap { WayOutArt.layer(on: p.frame, placement: $0, theme: theme, scale: scale) }
        }
        return covers + lines
    }

    /// Replaces a root layer's covers with this plan's, in one transaction with no animation.
    public static func apply(_ plan: CoverPlan, to root: CALayer, theme: CoverTheme = .light, scale: CGFloat = 2) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = layers(for: plan, theme: theme, scale: scale)
        CATransaction.commit()
    }
}

enum LayerFactory {
    /// A plain cover is one opaque, flat, neutral fill: calm, and seamless where covers meet.
    static func layer(_ frame: CGRect, _ kind: CoverKind, _ theme: CoverTheme) -> CALayer {
        let l = CALayer()
        l.frame = frame
        l.isOpaque = true
        l.backgroundColor = theme.cover.cg()
        if case let .blur(tile) = kind, let img = image(tile) {
            l.contents = img
            l.contentsGravity = .resize
            l.magnificationFilter = .linear
            l.minificationFilter = .linear
        }
        return l
    }

    /// The blur tile as a tiny image, enlarged smoothly by the layer: soft colour only, no detail.
    static func image(_ t: BlurTile) -> CGImage? {
        guard t.columns > 0, t.rows > 0, t.rgba.count == t.columns * t.rows * 4,
              let provider = CGDataProvider(data: Data(t.rgba) as CFData) else { return nil }
        return CGImage(width: t.columns, height: t.rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: t.columns * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The default form: one canvas per display.
@MainActor
public final class CoverCanvas: CoverPresenter {
    private var panels: [UInt32: CoverPanel] = [:]
    public init() {}

    static var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    /// The screen showing a display, by its identifier.
    static func screen(_ id: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    public func apply(_ plans: [CoverPlan]) {
        let ids = Set(plans.map(\.display.id))
        for (id, p) in panels where !ids.contains(id) { p.orderOut(nil); panels[id] = nil }
        let theme = CoverTheme.current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for plan in plans {
            let frame = CoverLayout.canvasFrame(display: plan.display.bounds, primaryHeight: Self.primaryHeight)
            let panel = panels[plan.display.id] ?? CoverPanel.make(frame: frame)
            panels[plan.display.id] = panel
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            let root = panel.contentView!.layer!
            root.frame = CGRect(origin: .zero, size: frame.size)
            let screen = Self.screen(plan.display.id)
            let scale = screen?.backingScaleFactor ?? 2
            let menuBar = plan.wholeDisplay == nil ? 0 : MenuBarProbe.height(plan.display, screen: screen)
            root.sublayers = CoverDrawing.layers(for: plan, theme: theme, scale: scale, menuBar: menuBar)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        CATransaction.commit()
    }

    public func removeAll() {
        for p in panels.values { p.orderOut(nil) }
        panels = [:]
    }
}

/// The pivot form: one overlay panel per cover.
@MainActor
public final class OverlayCovers: CoverPresenter {
    private var pool: [CoverPanel] = []
    public init() {}

    public func apply(_ plans: [CoverPlan]) {
        let frames = plans.flatMap { plan in
            let screen = CoverCanvas.screen(plan.display.id)
            let menuBar = plan.wholeDisplay == nil ? 0 : MenuBarProbe.height(plan.display, screen: screen)
            return CoverLayout.overlayPieces(plan, primaryHeight: CoverCanvas.primaryHeight, menuBar: menuBar)
                .map { ($0, screen?.backingScaleFactor ?? 2) }
        }
        let theme = CoverTheme.current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while pool.count < frames.count { pool.append(CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 1, height: 1))) }
        for (i, panel) in pool.enumerated() {
            guard i < frames.count else { panel.orderOut(nil); continue }
            var (piece, scale) = frames[i]
            panel.setFrame(piece.frame, display: false)
            let root = panel.contentView!.layer!
            root.frame = CGRect(origin: .zero, size: piece.frame.size)
            piece.frame.origin = .zero
            root.sublayers = CoverDrawing.layers(for: [piece], theme: theme, scale: scale)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        CATransaction.commit()
    }

    public func removeAll() {
        for p in pool { p.orderOut(nil) }
    }
}

/// The menu bar a whole-display cover leaves in sight: the screen's menu bar height, while the window list
/// shows the menu bar on that display (`WayOut.menuBarHeight`). Window titles are never read.
@MainActor
enum MenuBarProbe {
    static func height(_ display: DisplayDescriptor, screen: NSScreen?) -> CGFloat {
        guard let screen else { return 0 }
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        guard inset > 0, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        let bars: [WindowInfo] = list.compactMap { d in
            guard let layer = d[kCGWindowLayer as String] as? Int, WayOut.menuBarLayers.contains(layer),
                  let b = d[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b as CFDictionary)
            else { return nil }
            return WindowInfo(number: 0, ownerPID: 0, layer: layer, bounds: bounds)
        }
        return WayOut.menuBarHeight(display: display.bounds, topInset: inset, windows: bars)
    }
}
