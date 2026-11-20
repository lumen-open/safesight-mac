// SPDX-License-Identifier: Apache-2.0
// What the cover layer draws (chapter 05, sections 5.2, 5.4 to 5.6). Covers are plain and wordless, with
// one exception: whole-window and whole-display covers carry the way-out line (WayOut.swift).
import CoreGraphics
import Foundation
import Preprocess

/// A strongly blurred stand-in for a contained picture: a handful of colour averages, drawn smoothly
/// enlarged. It keeps at most `ContainBlur.maxCells` values along a side, so a picture's subject cannot
/// be made out at its displayed size. Held in memory only.
public struct BlurTile: Equatable, Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    /// RGBA, row-major, `columns * rows * 4` bytes, opaque.
    public let rgba: [UInt8]
}

public enum CoverKind: Equatable, Hashable, Sendable {
    /// An opaque, plain cover.
    case plain
    /// A soft blur over a contained picture (`contain`). If it cannot be drawn, a plain cover is drawn instead.
    case blur(BlurTile)

    /// A plain cover outranks a blur.
    func stronger(_ o: CoverKind) -> CoverKind {
        if case .plain = self { return .plain }
        if case .plain = o { return .plain }
        return self
    }
}

/// One cover, in global points.
public struct CoverItem: Equatable, Sendable {
    public var rect: CGRect
    public var kind: CoverKind
    /// True on the largest visible piece of a whole-window cover: the way-out line is drawn on it.
    public var wayOut: Bool
    /// The window or surface whose content the cover hides, when known: a password prompt's own covers stay inside its
    /// hole, every other cover is cut out of it (`DisplayPipeline.promptHoles`). Nil counts as anyone's: never cut.
    public var source: JudgeTarget?
    public init(rect: CGRect, kind: CoverKind, wayOut: Bool = false, source: JudgeTarget? = nil) {
        self.rect = rect; self.kind = kind; self.wayOut = wayOut; self.source = source
    }
}

/// Where the way-out line sits on a cover.
public enum WayOutPlacement: Equatable, Sendable {
    /// A whole-window cover: in the middle, raised a little.
    case centre
    /// A whole-display cover: below the middle, clear of the repair card, which sits in the middle.
    case belowCard
}

/// One cover as drawn: its frame (canvas layer space, or Cocoa points for an overlay window), its kind and,
/// for whole-window and whole-display covers, where the way-out line goes.
public struct CoverPiece: Equatable, Sendable {
    public var frame: CGRect
    public var kind: CoverKind
    public var wayOut: WayOutPlacement?
    public init(frame: CGRect, kind: CoverKind, wayOut: WayOutPlacement? = nil) { self.frame = frame; self.kind = kind; self.wayOut = wayOut }
}

/// The covers' own plain colours (the light and dark themes' `cover`). Covers are left out of capture, so the watcher
/// should never see them; if it does (capture that failed to leave the app's windows out), a cover would look like a
/// clean picture of itself. A place whose captured pixels are all one of these colours never counts as judged clean.
///
/// A backstop only: a blur cover, and a cover carrying the way-out line or the Testing line, do not match it. The real
/// guard is that no stream starts unless the app's own windows are left out of it (`CaptureExclusion`).
public enum OwnCoverColours {
    public static let rgb: [UInt32] = [0xE5E7E1, 0x121828]

    /// True when every sampled pixel of `r` is within a few levels of one of the covers' colours.
    public static func shown(in img: RGBAImage, _ r: PixelRect) -> Bool {
        guard let c = r.clamped(width: img.width, height: img.height), c.w > 0, c.h > 0 else { return false }
        let n = 12
        return rgb.contains { hex in
            let want = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
            for i in 0..<n { for j in 0..<n {
                let x = c.x + (c.w - 1) * i / (n - 1), y = c.y + (c.h - 1) * j / (n - 1), p = (y * img.width + x) * 4
                for k in 0..<3 where abs(Int(img.pixels[p + k]) - want[k]) > 3 { return false }
            } }
            return true
        }
    }
}

/// The window levels the covers use (kCGWindowLayer in the window list is the same number).
public enum CoverLevel {
    /// The cover canvas: above the screen saver's level (1000) and the assistive-technology levels (up to 1500), and
    /// safely below the lock screen. loginwindow's windows were read at levels 2001 and 2004 on a locked Mac, so the lock
    /// screen's password field and the login window stay above every cover: a cover must never be what stops the owner
    /// unlocking their Mac. macOS's authorization prompt does not: it was read at level 1000, under the covers, so its
    /// rectangle is left out of the covers instead (`PasswordPrompt`). An app that raises its own window to this level
    /// or above is not covered itself; over a cover, it covers the display whole (`DisplayPipeline.canvasLevel`). Raising
    /// the canvas above the lock screen is not allowed until a test Mac shows all of those stay usable over a whole-display
    /// cover (`docs/STEP-1-STATUS.md`).
    public static let canvas = 1990
    /// The app's own windows, its menu and the repair card: one level above the canvas, still below the lock screen.
    public static let appAbove = 1991
    /// The lowest level loginwindow's windows were seen at on a locked Mac.
    public static let lockScreenSeen = 2001
    /// The plain cover drawn behind a password prompt's hole: one level below the prompt (`PasswordPrompt.level`), so
    /// the prompt shows over it and nothing behind the prompt shows through a see-through or rounded part of it.
    public static let behindPrompt = PasswordPrompt.level - 1
}

/// Everything drawn on one display, applied in one step.
public struct CoverPlan: Equatable, Sendable {
    public var display: DisplayDescriptor
    public var items: [CoverItem]
    /// When set, the whole display is covered and `items` is ignored: the display cannot be judged.
    public var wholeDisplay: FaultCause?
    /// Where a password prompt is left clear (global points): its own rectangle, less the windows in front of it
    /// (`DisplayPipeline.promptHoles`). Covers of anything else are already cut out of it; a whole-display cover is drawn
    /// around it, with the prompt's own covers (`items`) inside it. A plain cover is drawn behind it, below the prompt
    /// (`CoverLevel.behindPrompt`).
    public var promptHoles: [CGRect]

    public init(display: DisplayDescriptor, items: [CoverItem], wholeDisplay: FaultCause? = nil, promptHoles: [CGRect] = []) {
        self.display = display; self.items = items; self.wholeDisplay = wholeDisplay; self.promptHoles = promptHoles
    }

    public static func covered(_ display: DisplayDescriptor, because cause: FaultCause) -> CoverPlan {
        CoverPlan(display: display, items: [], wholeDisplay: cause)
    }

    public static func clear(_ display: DisplayDescriptor) -> CoverPlan { CoverPlan(display: display, items: []) }

    public var plainCount: Int { items.filter { $0.kind == .plain }.count }
    public var blurCount: Int { items.count - plainCount }
}

/// Where the drawing goes, in window terms (section 5.4). Pure arithmetic, shared by both cover forms.
public enum CoverLayout {
    /// The cover canvas: one click-through window the size of its display, in Cocoa points.
    public static func canvasFrame(display: CGRect, primaryHeight: CGFloat) -> CGRect {
        CoordinateSpace.toCocoa(display, primaryHeight: primaryHeight)
    }

    /// What a plan covers, in global points, cut to its display, with each piece's way-out placement.
    /// A whole-display cover leaves the top `menuBar` points (`WayOut.menuBarHeight`) for the menu bar; the
    /// Dock stays covered.
    static func globalPieces(_ plan: CoverPlan, menuBar: CGFloat) -> [CoverPiece] {
        let d = plan.display.bounds
        if plan.wholeDisplay != nil {
            let mb = min(max(0, menuBar.isFinite ? menuBar : 0), WayOut.menuBarMax)
            let whole = CGRect(x: d.minX, y: d.minY + mb, width: d.width, height: d.height - mb)
            let holes = plan.promptHoles.clipped(to: d)
            guard !holes.isEmpty else { return [CoverPiece(frame: whole, kind: .plain, wayOut: .belowCard)] }
            // Around a password prompt: the whole display less its hole, the way out on the largest piece, and the
            // prompt's own covers inside the hole.
            var pieces = holes.reduce([whole]) { $0.subtracting($1) }.filter(\.hasArea).map { CoverPiece(frame: $0, kind: .plain) }
            if let i = pieces.indices.max(by: { pieces[$0].frame.width * pieces[$0].frame.height < pieces[$1].frame.width * pieces[$1].frame.height }) {
                pieces[i].wayOut = .belowCard
            }
            return pieces + plan.items.compactMap { item in
                let r = item.rect.intersection(d)
                return r.hasArea ? CoverPiece(frame: r, kind: item.kind) : nil
            }
        }
        return plan.items.compactMap { item in
            let r = item.rect.intersection(d)
            return r.hasArea ? CoverPiece(frame: r, kind: item.kind, wayOut: item.wayOut ? .centre : nil) : nil
        }
    }

    /// Each cover inside the canvas (layer space: display-local, origin bottom-left).
    public static func layerPieces(_ plan: CoverPlan, menuBar: CGFloat = 0) -> [CoverPiece] {
        globalPieces(plan, menuBar: menuBar).map { var p = $0; p.frame = CoordinateSpace.toCanvasLayer(p.frame, display: plan.display.bounds); return p }
    }

    /// Each cover's frame inside the canvas (layer space: display-local, origin bottom-left).
    public static func layerFrames(_ plan: CoverPlan, menuBar: CGFloat = 0) -> [(CGRect, CoverKind)] {
        layerPieces(plan, menuBar: menuBar).map { ($0.frame, $0.kind) }
    }

    /// The plain covers behind password prompts (`CoverPlan.promptHoles`), in global points, cut to the display.
    public static func behindPromptRects(_ plan: CoverPlan) -> [CGRect] { plan.promptHoles.clipped(to: plan.display.bounds) }

    /// The per-window overlay form (the written pivot of ST-032): one overlay window per cover, its
    /// frame in Cocoa points, cut to the display.
    public static func overlayPieces(_ plan: CoverPlan, primaryHeight: CGFloat, menuBar: CGFloat = 0) -> [CoverPiece] {
        globalPieces(plan, menuBar: menuBar).map { var p = $0; p.frame = CoordinateSpace.toCocoa(p.frame, primaryHeight: primaryHeight); return p }
    }

    public static func overlayFrames(_ plan: CoverPlan, primaryHeight: CGFloat, menuBar: CGFloat = 0) -> [(CGRect, CoverKind)] {
        overlayPieces(plan, primaryHeight: primaryHeight, menuBar: menuBar).map { ($0.frame, $0.kind) }
    }
}

public enum ContainBlur {
    /// At most this many colour cells along a tile's side.
    public static let maxCells = 6

    /// Averages the region's pixels into a few cells. Returns nil if the region is outside the frame,
    /// in which case the caller draws a plain cover instead.
    public static func make(_ img: RGBAImage, _ r: PixelRect) -> BlurTile? {
        guard let c = r.clamped(width: img.width, height: img.height), c.w > 0, c.h > 0 else { return nil }
        let short = min(c.w, c.h), long = max(c.w, c.h)
        let shortCells = min(3, max(1, short / 8))
        let longCells = min(maxCells, max(shortCells, (long * shortCells) / max(short, 1)))
        let cols = c.w >= c.h ? longCells : shortCells, rows = c.w >= c.h ? shortCells : longCells
        var out = [UInt8](repeating: 255, count: cols * rows * 4)
        img.pixels.withUnsafeBufferPointer { px in
            for gy in 0..<rows {
                let y0 = c.y + gy * c.h / rows, y1 = c.y + (gy + 1) * c.h / rows
                for gx in 0..<cols {
                    let x0 = c.x + gx * c.w / cols, x1 = c.x + (gx + 1) * c.w / cols
                    var sum = (0, 0, 0), n = 0
                    // Sample every other pixel each way: plenty for an average, a quarter of the reads.
                    var y = y0
                    while y < y1 {
                        var x = x0, p = (y * img.width + x0) * 4
                        while x < x1 { sum.0 += Int(px[p]); sum.1 += Int(px[p + 1]); sum.2 += Int(px[p + 2]); n += 1; x += 2; p += 8 }
                        y += 2
                    }
                    let o = (gy * cols + gx) * 4, d = max(n, 1)
                    out[o] = UInt8(sum.0 / d); out[o + 1] = UInt8(sum.1 / d); out[o + 2] = UInt8(sum.2 / d)
                }
            }
        }
        return BlurTile(columns: cols, rows: rows, rgba: out)
    }
}
