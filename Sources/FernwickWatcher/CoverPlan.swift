// SPDX-License-Identifier: Apache-2.0
// What the cover layer draws (chapter 05, sections 5.2, 5.4 to 5.6). Covers are plain and wordless.
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
    public init(rect: CGRect, kind: CoverKind) { self.rect = rect; self.kind = kind }
}

/// Everything drawn on one display, applied in one step.
public struct CoverPlan: Equatable, Sendable {
    public var display: DisplayDescriptor
    public var items: [CoverItem]
    /// When set, the whole display is covered and `items` is ignored: the display cannot be judged.
    public var wholeDisplay: FaultCause?

    public init(display: DisplayDescriptor, items: [CoverItem], wholeDisplay: FaultCause? = nil) {
        self.display = display; self.items = items; self.wholeDisplay = wholeDisplay
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

    /// Each cover's frame inside the canvas (layer space: display-local, origin bottom-left).
    public static func layerFrames(_ plan: CoverPlan) -> [(CGRect, CoverKind)] {
        let d = plan.display.bounds
        if plan.wholeDisplay != nil { return [(CGRect(origin: .zero, size: d.size), .plain)] }
        return plan.items.compactMap { item in
            let r = item.rect.intersection(d)
            return r.hasArea ? (CoordinateSpace.toCanvasLayer(r, display: d), item.kind) : nil
        }
    }

    /// The per-window overlay form (the written pivot of ST-032): one overlay window per cover, its
    /// frame in Cocoa points, cut to the display.
    public static func overlayFrames(_ plan: CoverPlan, primaryHeight: CGFloat) -> [(CGRect, CoverKind)] {
        let d = plan.display.bounds
        if plan.wholeDisplay != nil { return [(CoordinateSpace.toCocoa(d, primaryHeight: primaryHeight), .plain)] }
        return plan.items.compactMap { item in
            let r = item.rect.intersection(d)
            return r.hasArea ? (CoordinateSpace.toCocoa(r, primaryHeight: primaryHeight), item.kind) : nil
        }
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
