// SPDX-License-Identifier: Apache-2.0
// Drawing the covers (chapter 05, section 5.4). Two forms share one geometry (CoverLayout):
// - the cover canvas (default): one transparent, click-through, always-on-top panel per display that
//   holds every cover on it, all changed in one transaction;
// - per-window overlays (the written pivot of ST-032): one click-through panel per cover.
// Covers are plain and wordless: no text, no logo, no product name. They never take the keyboard,
// never become key or main, stay out of window cycling and are hidden from assistive tools.
import AppKit
import FernwickWatcher
import QuartzCore

public enum CoverLevels {
    /// The canvas sits above full-screen apps, the menu bar, menus, the Dock and notifications.
    /// Not specified in the register; ST-032 finds the lowest level that works per surface. Working value.
    public static let canvas = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    /// The app's own windows and the repair card sit one level above the canvas (SD-229).
    public static let appAbove = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
    /// The plain cover colour. Not specified in the register (5.22, row 5); a neutral grey.
    public static let coverColor = CGColor(srgbRed: 0.40, green: 0.41, blue: 0.43, alpha: 1)
}

public enum CoverForm: String, Sendable {
    case canvas, overlays
    /// `FERNWICK_COVER_FORM=overlays` selects the pivot form; the canvas is the default.
    public static var current: CoverForm {
        ProcessInfo.processInfo.environment["FERNWICK_COVER_FORM"] == "overlays" ? .overlays : .canvas
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

enum LayerFactory {
    static func layer(_ frame: CGRect, _ kind: CoverKind) -> CALayer {
        let l = CALayer()
        l.frame = frame
        l.backgroundColor = CoverLevels.coverColor
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

    public func apply(_ plans: [CoverPlan]) {
        let ids = Set(plans.map(\.display.id))
        for (id, p) in panels where !ids.contains(id) { p.orderOut(nil); panels[id] = nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for plan in plans {
            let frame = CoverLayout.canvasFrame(display: plan.display.bounds, primaryHeight: Self.primaryHeight)
            let panel = panels[plan.display.id] ?? CoverPanel.make(frame: frame)
            panels[plan.display.id] = panel
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            let root = panel.contentView!.layer!
            root.frame = CGRect(origin: .zero, size: frame.size)
            root.sublayers = CoverLayout.layerFrames(plan).map { LayerFactory.layer($0.0, $0.1) }
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
        let frames = plans.flatMap { CoverLayout.overlayFrames($0, primaryHeight: CoverCanvas.primaryHeight) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while pool.count < frames.count { pool.append(CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 1, height: 1))) }
        for (i, panel) in pool.enumerated() {
            guard i < frames.count else { panel.orderOut(nil); continue }
            let (frame, kind) = frames[i]
            panel.setFrame(frame, display: false)
            let root = panel.contentView!.layer!
            root.frame = CGRect(origin: .zero, size: frame.size)
            root.sublayers = [LayerFactory.layer(CGRect(origin: .zero, size: frame.size), kind)]
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        CATransaction.commit()
    }

    public func removeAll() {
        for p in pool { p.orderOut(nil) }
    }
}
