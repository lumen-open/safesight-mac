// SPDX-License-Identifier: Apache-2.0
// Coordinate maps for the watcher (chapter 05, sections 5.1 and 5.4).
//
// Three spaces are used, and every conversion between them is one function here:
// - detail pixels: the capture buffer of one display stream, origin top-left, y down;
// - global points: the Quartz display space shared by CGDisplayBounds and CGWindowList,
//   origin at the top-left of the primary display, y down;
// - Cocoa points: the AppKit window space, origin at the bottom-left of the primary display, y up.
import CoreGraphics
import Foundation
import Preprocess

/// The map from one frame's capture pixels to global screen points. It is rebuilt from every frame's
/// own metadata and never cached (SD-113): rotation, mixed 1x and 2x displays and scaled modes all change it.
public struct CaptureMap: Equatable, Sendable {
    /// The display's bounds in global points (CGDisplayBounds).
    public let displayBounds: CGRect
    /// Where the captured content sits inside the frame, in frame points (SCStreamFrameInfo.contentRect).
    public let contentRect: CGRect
    /// The content's scale relative to the frame (SCStreamFrameInfo.contentScale). 1 when not letterboxed.
    public let contentScale: CGFloat
    /// Frame pixels per frame point (SCStreamFrameInfo.scaleFactor). Read, never assumed to be 2.
    public let scaleFactor: CGFloat
    /// The frame buffer's size in pixels.
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// Returns nil when the metadata cannot give a trustworthy map. The caller treats that display as
    /// not judged, which means a whole-display cover (faults lead to more covering).
    public init?(displayBounds: CGRect, contentRect: CGRect, contentScale: CGFloat, scaleFactor: CGFloat,
                 pixelWidth: Int, pixelHeight: Int) {
        let finite = [displayBounds.minX, displayBounds.minY, displayBounds.width, displayBounds.height,
                      contentRect.minX, contentRect.minY, contentRect.width, contentRect.height,
                      contentScale, scaleFactor].allSatisfy(\.isFinite)
        guard finite, scaleFactor > 0, contentScale > 0, pixelWidth > 0, pixelHeight > 0,
              displayBounds.width > 0, displayBounds.height > 0, contentRect.width > 0, contentRect.height > 0
        else { return nil }
        self.displayBounds = displayBounds; self.contentRect = contentRect
        self.contentScale = contentScale; self.scaleFactor = scaleFactor
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    /// One frame pixel coordinate to global points.
    public func globalPoint(px x: CGFloat, _ y: CGFloat) -> CGPoint {
        let fx = x / scaleFactor, fy = y / scaleFactor
        return CGPoint(x: displayBounds.minX + (fx - contentRect.minX) / contentScale,
                       y: displayBounds.minY + (fy - contentRect.minY) / contentScale)
    }

    /// Global points to frame pixels (fractional).
    public func pixelPoint(global p: CGPoint) -> CGPoint {
        CGPoint(x: ((p.x - displayBounds.minX) * contentScale + contentRect.minX) * scaleFactor,
                y: ((p.y - displayBounds.minY) * contentScale + contentRect.minY) * scaleFactor)
    }

    /// Global points per frame pixel, for snapping covers outward to the pixel grid.
    public var pointsPerPixel: CGFloat { 1 / (scaleFactor * contentScale) }

    /// A rectangle in frame pixels to global points. Exact (no rounding is needed in this direction).
    public func toGlobal(_ r: PixelRect) -> CGRect {
        let a = globalPoint(px: CGFloat(r.x), CGFloat(r.y)), b = globalPoint(px: CGFloat(r.maxX), CGFloat(r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// A rectangle in global points to frame pixels, grown outward to whole pixels and clamped to the frame.
    /// Growing outward means a cover or a judged area is never smaller than its target.
    public func toPixels(_ g: CGRect) -> PixelRect? {
        let a = pixelPoint(global: CGPoint(x: g.minX, y: g.minY)), b = pixelPoint(global: CGPoint(x: g.maxX, y: g.maxY))
        let eps: CGFloat = 1e-6
        let x0 = max(0, Int((a.x + eps).rounded(.down))), y0 = max(0, Int((a.y + eps).rounded(.down)))
        let x1 = min(pixelWidth, Int((b.x - eps).rounded(.up))), y1 = min(pixelHeight, Int((b.y - eps).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// The whole frame, in pixels.
    public var fullFrame: PixelRect { PixelRect(x: 0, y: 0, w: pixelWidth, h: pixelHeight) }
}

public enum CoordinateSpace {
    /// Global points (top-left origin, y down) to Cocoa points (bottom-left origin, y up).
    /// `primaryHeight` is the height of the primary display in points (CGDisplayBounds(CGMainDisplayID())).
    public static func toCocoa(_ g: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: g.minX, y: primaryHeight - g.maxY, width: g.width, height: g.height)
    }

    /// Cocoa points to global points. The same flip, so it is its own inverse.
    public static func toGlobal(cocoa c: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: c.minX, y: primaryHeight - c.maxY, width: c.width, height: c.height)
    }

    /// A global rectangle in the layer space of a canvas that fills `display` (global bounds):
    /// origin at the canvas's bottom-left, y up, in points.
    public static func toCanvasLayer(_ g: CGRect, display: CGRect) -> CGRect {
        CGRect(x: g.minX - display.minX, y: display.maxY - g.maxY, width: g.width, height: g.height)
    }

    /// Grows a global rectangle outward to the display's pixel grid, so a cover never stops short of its target.
    public static func snapOutward(_ g: CGRect, pointsPerPixel p: CGFloat) -> CGRect {
        guard p > 0, p.isFinite else { return g.integral }
        let eps: CGFloat = 1e-6
        let x0 = ((g.minX + eps) / p).rounded(.down) * p, y0 = ((g.minY + eps) / p).rounded(.down) * p
        let x1 = ((g.maxX - eps) / p).rounded(.up) * p, y1 = ((g.maxY - eps) / p).rounded(.up) * p
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension CGRect {
    /// This rectangle minus another: up to four pieces that together cover exactly `self \ other`.
    public func subtracting(_ o: CGRect) -> [CGRect] {
        let i = intersection(o)
        guard !i.isNull, i.width > 0, i.height > 0 else { return isEmpty ? [] : [self] }
        var out: [CGRect] = []
        if i.minY > minY { out.append(CGRect(x: minX, y: minY, width: width, height: i.minY - minY)) }
        if maxY > i.maxY { out.append(CGRect(x: minX, y: i.maxY, width: width, height: maxY - i.maxY)) }
        if i.minX > minX { out.append(CGRect(x: minX, y: i.minY, width: i.minX - minX, height: i.height)) }
        if maxX > i.maxX { out.append(CGRect(x: i.maxX, y: i.minY, width: maxX - i.maxX, height: i.height)) }
        return out
    }

    /// True when the rectangle has a positive area.
    public var hasArea: Bool { !isNull && width > 0 && height > 0 }
}

extension Array where Element == CGRect {
    /// Every rectangle minus `o`.
    public func subtracting(_ o: CGRect) -> [CGRect] { flatMap { $0.subtracting(o) } }
    /// Every rectangle cut to `o`, dropping empty results.
    public func clipped(to o: CGRect) -> [CGRect] { map { $0.intersection(o) }.filter(\.hasArea) }
    /// The bounding box, or nil if empty.
    public var boundingBox: CGRect? {
        guard var b = first else { return nil }
        for r in dropFirst() { b = b.union(r) }
        return b
    }
}
