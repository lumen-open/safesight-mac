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
    /// The canvas sits above full-screen apps, the menu bar, menus, the Dock, notifications, screen-saver-level and
    /// assistive-technology windows, and safely below the lock screen (`CoverLevel.canvas`). Not specified in the
    /// register; ST-032 checks it per surface on a test Mac. A window of another app at or above it, over a cover, covers
    /// the display whole (`DisplayPipeline.canvasLevel`).
    public static let canvas = NSWindow.Level(rawValue: CoverLevel.canvas)
    /// The app's own windows, its menu and the repair card sit one level above the canvas (SD-229).
    public static let appAbove = NSWindow.Level(rawValue: CoverLevel.appAbove)
    /// The plain cover behind a password prompt's hole sits one level below the prompt (`CoverLevel.behindPrompt`).
    public static let behindPrompt = NSWindow.Level(rawValue: CoverLevel.behindPrompt)
}

/// The plain covers drawn behind password prompts (`CoverPlan.promptHoles`): one click-through panel per hole, below
/// the prompt's level, so the prompt shows over it and nothing behind the prompt shows through it. Shared by both forms.
@MainActor
final class BehindPrompt {
    private var pool: [CoverPanel] = []

    func apply(_ plans: [CoverPlan], theme: CoverTheme) {
        let frames = plans.flatMap { CoverLayout.behindPromptRects($0).map { CoordinateSpace.toCocoa($0, primaryHeight: CoverCanvas.primaryHeight) } }
        while pool.count < frames.count {
            let p = CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            p.level = CoverLevels.behindPrompt
            pool.append(p)
        }
        for (i, panel) in pool.enumerated() {
            guard i < frames.count else { if panel.isVisible { panel.orderOut(nil) }; continue }
            if panel.frame != frames[i] { panel.setFrame(frames[i], display: false) }
            let root = panel.contentView!.layer!
            root.frame = CGRect(origin: .zero, size: frames[i].size)
            root.sublayers = [LayerFactory.layer(root.frame, .plain, theme)]
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func removeAll() { for p in pool { p.orderOut(nil) } }
}

public enum CoverForm: String, Sendable {
    case canvas, overlays
    /// `SAFESIGHTMAC_COVER_FORM=overlays` selects the pivot form; the canvas is the default.
    public static var current: CoverForm {
        ProcessInfo.processInfo.environment["SAFESIGHTMAC_COVER_FORM"] == "overlays" ? .overlays : .canvas
    }
}

/// What the Testing edition adds to covers: its line (AppText.testingLine), on every cover that carries the way
/// out, on any cover that hides at least half of its display, and, when smaller covers together hide half of it,
/// on the largest of them that has room, so that covers big enough to be in the way never stand without saying
/// how to quit. The release edition adds nothing: its picture covers stay wordless.
public enum CoverNotice: Equatable, Sendable {
    /// `shortcut`: whether ⌃⌥⌘Q is this copy's; without it the line says to quit from the menu bar icon.
    case testing(shortcut: Bool)

    /// A cover hiding at least this share of its display carries the line even over a picture.
    public static let bigShare: CGFloat = 0.5
}

@MainActor
public protocol CoverPresenter: AnyObject {
    /// Applies one plan per display. Displays without a plan lose their covers.
    func apply(_ plans: [CoverPlan])
    func removeAll()
    /// What the covers carry besides the way out (the Testing edition's line), or nil.
    var notice: CoverNotice? { get set }
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
        p.isRestorable = false
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

extension CoverDrawing {
    /// A cover window exactly as the cover layer makes it, for the lab harness's check that a process's covers go
    /// when it ends (`safesightmac-harness vanish`). The harness keeps it invisible and off every display.
    @MainActor public static func coverWindowForLifetimeCheck(frame: CGRect) -> NSPanel { CoverPanel.make(frame: frame) }
}

/// The canvas's layers for one plan, built without any window. The canvas form uses it, and the lab
/// harness's bench times it on a detached layer (no window, nothing drawn on a screen); the harness also
/// renders it into its frames.
public enum CoverDrawing {
    public static func layers(for plan: CoverPlan, theme: CoverTheme = .light, scale: CGFloat = 2, menuBar: CGFloat = 0,
                              notice: CoverNotice? = nil) -> [CALayer] {
        let d = plan.display.bounds
        return layers(for: CoverLayout.layerPieces(plan, menuBar: menuBar), theme: theme, scale: scale, notice: notice,
                      displayArea: d.width * d.height)
    }

    /// Every cover, then every line on top (each line lies inside its own cover, with room to spare): the way out
    /// on whole-window and whole-display covers, and with a `notice`, the Testing line under it, and on any cover
    /// that hides at least `CoverNotice.bigShare` of `displayArea`.
    public static func layers(for pieces: [CoverPiece], theme: CoverTheme, scale: CGFloat, notice: CoverNotice? = nil,
                              displayArea: CGFloat? = nil, testingLineOn: Set<Int>? = nil) -> [CALayer] {
        let covers: [CALayer] = pieces.map { LayerFactory.layer($0.frame, $0.kind, theme) }
        let hosts = testingLineOn ?? testingLineHosts(pieces, notice: notice, displayArea: displayArea, theme: theme, scale: scale)
        var lines: [CALayer] = []
        for (i, p) in pieces.enumerated() {
            let way = p.wayOut.flatMap { WayOutArt.layer(on: p.frame, placement: $0, theme: theme, scale: scale) }
            if let way { lines.append(way) }
            guard case let .testing(shortcut)? = notice, hosts.contains(i) else { continue }
            if let t = WayOutArt.testingLayer(on: p.frame, placement: p.wayOut ?? .centre, under: way, shortcut: shortcut,
                                              theme: theme, scale: scale) {
                lines.append(t)
            }
        }
        return covers + lines
    }

    /// Which of a display's cover pieces carries the Testing line (see `CoverNotice`): one piece per display at most, so
    /// lines never stack (several overlapping covers each hiding half a display drew two to four pills on top of one
    /// another on a real screen). The whole-display cover when there is one; otherwise the largest piece with the way out
    /// or hiding `CoverNotice.bigShare` of the display that has room for the line; otherwise, when the pieces together
    /// hide that much, the largest piece that has room. None without a notice.
    public static func testingLineHosts(_ pieces: [CoverPiece], notice: CoverNotice?, displayArea: CGFloat?,
                                        theme: CoverTheme, scale: CGFloat) -> Set<Int> {
        guard case let .testing(shortcut)? = notice else { return [] }
        if let whole = pieces.indices.first(where: { pieces[$0].wayOut == .belowCard }) { return [whole] }
        let areas = pieces.map { $0.frame.width * $0.frame.height }
        let big = displayArea.map { $0 > 0 ? CoverNotice.bigShare * $0 : .infinity } ?? .infinity
        let compact = WayOutArt.pillSize(.compact, theme, .testing(shortcut: shortcut))
        func roomy(_ i: Int) -> Bool {
            WayOutArt.testingPillFrame(in: pieces[i].frame, placement: .centre, under: nil, size: compact, scale: scale) != nil
        }
        // Pieces with the way out are tried with their way-out line in place (the Testing line goes under it).
        func fits(_ i: Int) -> Bool {
            guard let place = pieces[i].wayOut else { return roomy(i) }
            let way = WayOutArt.layer(on: pieces[i].frame, placement: place, theme: theme, scale: scale)
            return WayOutArt.testingLayer(on: pieces[i].frame, placement: place, under: way, shortcut: shortcut, theme: theme, scale: scale) != nil
        }
        let wanted = pieces.indices.filter { pieces[$0].wayOut != nil || areas[$0] >= big }
        if let best = wanted.filter(fits).max(by: { areas[$0] < areas[$1] }) { return [best] }
        if areas.reduce(0, +) >= big, let largest = pieces.indices.filter(roomy).max(by: { areas[$0] < areas[$1] }) {
            return [largest]
        }
        return []
    }

    /// Replaces a root layer's covers with this plan's, in one transaction with no animation.
    public static func apply(_ plan: CoverPlan, to root: CALayer, theme: CoverTheme = .light, scale: CGFloat = 2,
                             notice: CoverNotice? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = layers(for: plan, theme: theme, scale: scale, notice: notice)
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
    /// What each canvas holds now, so an update that draws exactly the same is not drawn again (each drawing is work for
    /// the window server, and the covers' own drawing must never be what keeps the screen busy).
    private var drawn: [UInt32: Drawn] = [:]
    private struct Drawn: Equatable { var plan: CoverPlan; var theme: CoverTheme; var notice: CoverNotice?; var menuBar: CGFloat; var scale: CGFloat; var frame: CGRect }
    /// When each canvas was last brought to the front of its level.
    private var frontedAt: [UInt32: TimeInterval] = [:]
    private let behind = BehindPrompt()
    public var notice: CoverNotice?
    public init(notice: CoverNotice? = nil) { self.notice = notice }

    static var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    /// The screen showing a display, by its identifier.
    static func screen(_ id: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    public func apply(_ plans: [CoverPlan]) {
        let ids = Set(plans.map(\.display.id))
        for (id, p) in panels where !ids.contains(id) { p.orderOut(nil); panels[id] = nil; drawn[id] = nil }
        let now = ProcessInfo.processInfo.systemUptime
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
            let now_ = Drawn(plan: plan, theme: theme, notice: notice, menuBar: menuBar, scale: scale, frame: frame)
            let same = drawn[plan.display.id] == now_ && panel.isVisible
            if !same {
                root.sublayers = CoverDrawing.layers(for: plan, theme: theme, scale: scale, menuBar: menuBar, notice: notice)
                drawn[plan.display.id] = now_
            }
            // Ordered to the front of its level whenever its covers change, and at least four times a second while they
            // stay the same: a window that came up at the same level since never stays over the covers for long.
            if !same || now - (frontedAt[plan.display.id] ?? -.infinity) >= 0.25 {
                panel.orderFrontRegardless()
                frontedAt[plan.display.id] = now
            }
        }
        behind.apply(plans, theme: theme)
        CATransaction.commit()
    }

    public func removeAll() {
        for p in panels.values { p.orderOut(nil) }
        panels = [:]
        drawn = [:]
        behind.removeAll()
    }
}

/// The pivot form: one overlay panel per cover.
@MainActor
public final class OverlayCovers: CoverPresenter {
    private var pool: [CoverPanel] = []
    public var notice: CoverNotice?
    /// When every panel was last brought to the front: at most four times a second, besides each panel newly shown.
    private var frontedAt: TimeInterval = -.infinity
    private let behind = BehindPrompt()
    public init(notice: CoverNotice? = nil) { self.notice = notice }

    public func apply(_ plans: [CoverPlan]) {
        let theme = CoverTheme.current
        let frames = plans.flatMap { plan in
            let screen = CoverCanvas.screen(plan.display.id)
            let menuBar = plan.wholeDisplay == nil ? 0 : MenuBarProbe.height(plan.display, screen: screen)
            let area = plan.display.bounds.width * plan.display.bounds.height
            let scale = screen?.backingScaleFactor ?? 2
            let pieces = CoverLayout.overlayPieces(plan, primaryHeight: CoverCanvas.primaryHeight, menuBar: menuBar)
            // Chosen across the display's pieces, then drawn piece by piece, each in its own window.
            let hosts = CoverDrawing.testingLineHosts(pieces, notice: notice, displayArea: area, theme: theme, scale: scale)
            return pieces.enumerated().map { ($0.element, scale, hosts.contains($0.offset)) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while pool.count < frames.count { pool.append(CoverPanel.make(frame: CGRect(x: 0, y: 0, width: 1, height: 1))) }
        let now = ProcessInfo.processInfo.systemUptime
        let refront = now - frontedAt >= 0.25
        if refront { frontedAt = now }
        for (i, panel) in pool.enumerated() {
            guard i < frames.count else { panel.orderOut(nil); continue }
            var (piece, scale, lined) = frames[i]
            panel.setFrame(piece.frame, display: false)
            let root = panel.contentView!.layer!
            root.frame = CGRect(origin: .zero, size: piece.frame.size)
            piece.frame.origin = .zero
            root.sublayers = CoverDrawing.layers(for: [piece], theme: theme, scale: scale, notice: notice, testingLineOn: lined ? [0] : [])
            if refront || !panel.isVisible { panel.orderFrontRegardless() }
        }
        behind.apply(plans, theme: theme)
        CATransaction.commit()
    }

    public func removeAll() {
        for p in pool { p.orderOut(nil) }
        behind.removeAll()
    }
}

/// The menu bar a whole-display cover leaves in sight: on the main display's mirror set only (`WayOut.leavesMenuBar`),
/// the screen's menu bar height, while the window list shows the menu bar on that display (`WayOut.menuBarHeight`).
/// Window titles are never read.
@MainActor
enum MenuBarProbe {
    static func height(_ display: DisplayDescriptor, screen: NSScreen?) -> CGFloat {
        // A mirror relationship counts only where the display shares its source's place (`MirrorSets.source`).
        let raw: (UInt32) -> UInt32? = { id in
            let m = CGDisplayMirrorsDisplay(id)
            return m == kCGNullDirectDisplay ? nil : m
        }
        guard WayOut.leavesMenuBar(display: display.id, main: CGMainDisplayID(), mirrorOf: { id in
            MirrorSets.source(of: id, mirrorOf: raw, bounds: { CGDisplayBounds($0) })
        }) else { return 0 }
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

/// The presenter the coordinator draws with, watched for the Testing edition's stall watchdog and report: it is told
/// before every drawing whether a cover may be up (so a hang while drawing counts), and after it whether one is; it is
/// disarmed only once no cover is left. `onDrawn` hears every update drawn, and an empty list when every canvas is taken
/// off the screen (the lock screen, a pause), so the report never says a cover is up when none is.
@MainActor
public final class WatchedPresenter: CoverPresenter {
    private let inner: CoverPresenter
    private var showing = false
    public var onCoversShown: ((Bool) -> Void)?
    public var onDrawn: (([CoverPlan]) -> Void)?

    public init(_ inner: CoverPresenter) { self.inner = inner }

    public var notice: CoverNotice? {
        get { inner.notice }
        set { inner.notice = newValue }
    }

    public func apply(_ plans: [CoverPlan]) {
        let now = plans.contains { $0.wholeDisplay != nil || !$0.items.isEmpty || !$0.promptHoles.isEmpty }
        if now || showing { onCoversShown?(true) }
        inner.apply(plans)
        showing = now
        onCoversShown?(now)
        onDrawn?(plans)
    }

    public func removeAll() {
        inner.removeAll()
        showing = false
        onCoversShown?(false)
        onDrawn?([])
    }
}
