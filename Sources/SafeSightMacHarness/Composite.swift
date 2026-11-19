// SPDX-License-Identifier: Apache-2.0
// Writes a frame with its covers drawn on it as a PNG. The covers are the cover layer's own layers
// (CoverDrawing), rendered into the frame offscreen: what the PNG shows is what the canvas draws, way-out
// lines included. Nothing is captured from the screen and no window is shown.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Preprocess
import QuartzCore
import SafeSightMacCore
import SafeSightMacCover
import SafeSightMacWatcher
import UniformTypeIdentifiers

enum Composite {
    /// What this build's covers and card carry besides the way out: the Testing edition's line in a Testing build.
    static var notice: CoverNotice? { BuildInfo.edition == .testing ? .testing(shortcut: true) : nil }

    /// The frame (or black, for a frame with no pixels) with the plan's covers over it, at `scale`.
    /// `above` draws on top, in display points (y up): the repair card in the way-out scenes.
    static func render(_ img: RGBAImage?, _ plan: CoverPlan, scale: CGFloat, theme: CoverTheme, menuBar: CGFloat = 0,
                       notice: CoverNotice? = Composite.notice, above: ((CGContext) -> Void)? = nil) -> CGImage? {
        let size = plan.display.bounds.size
        let w = img?.width ?? Int(size.width * scale), h = img?.height ?? Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let img, let cg = cgImage(img) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.sublayers = CoverDrawing.layers(for: plan, theme: theme, scale: scale, menuBar: menuBar, notice: notice)
        root.render(in: ctx)
        above?(ctx)
        return ctx.makeImage()
    }

    /// The repair card, drawn offscreen from its views (no window is shown), with its size in points.
    @MainActor static func card(_ cause: FaultCause, pause: Bool, theme t: CoverTheme, scale: CGFloat,
                                notice: CoverNotice? = Composite.notice) -> (CGImage, CGSize)? {
        snapshot(RepairCardView.make(cause: cause, pause: pause, theme: t, target: nil, tryAgain: nil, pause: nil, quit: nil, notice: notice),
                 theme: t, scale: scale)
    }

    /// A view drawn offscreen in the theme's appearance (no window is shown), with its size in points.
    @MainActor static func snapshot(_ v: NSView, theme t: CoverTheme, scale: CGFloat) -> (CGImage, CGSize)? {
        let look = NSAppearance(named: t.isDark ? .darkAqua : .aqua)!
        v.appearance = look
        let size = v.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        look.performAsCurrentDrawingAppearance { v.cacheDisplay(in: v.bounds, to: rep) }
        return rep.cgImage.map { ($0, size) }
    }

    /// Draws the card as its panel shows it: rounded, with a hairline edge and a soft shadow. `at` is its frame
    /// in display points, y up.
    static func drawCard(_ ctx: CGContext, _ card: (CGImage, CGSize), at r: CGRect, theme t: CoverTheme) {
        let rc = RepairCardView.panelCorner, shape = CGPath(roundedRect: r, cornerWidth: rc, cornerHeight: rc, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: CGColor(gray: 0, alpha: t.isDark ? 0.6 : 0.22))
        ctx.setFillColor(t.card.cg()); ctx.addPath(shape); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.draw(card.0, in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(t.isDark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(0.5)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerWidth: rc, cornerHeight: rc, transform: nil)); ctx.strokePath()
    }

    /// Draws a window of the app as the system shows it, sketched: the theme's ground under a transparent title bar
    /// (window buttons and the title), the page below it, rounded, with a hairline edge and a soft shadow. `at` is
    /// the window's frame in display points, y up; the title bar is its top `titleBar` points.
    static func drawWindow(_ ctx: CGContext, _ page: (CGImage, CGSize), title: String, at r: CGRect, titleBar: CGFloat, theme t: CoverTheme) {
        let rc = RepairCardView.panelCorner, shape = CGPath(roundedRect: r, cornerWidth: rc, cornerHeight: rc, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: CGColor(gray: 0, alpha: t.isDark ? 0.6 : 0.22))
        ctx.setFillColor(t.background.cg()); ctx.addPath(shape); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.draw(page.0, in: CGRect(x: r.minX, y: r.maxY - titleBar - page.1.height, width: page.1.width, height: page.1.height))
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(CoverTheme.RGB(UInt32(c)).cg())
            ctx.fillEllipse(in: CGRect(x: r.minX + 14 + CGFloat(i) * 20, y: r.maxY - titleBar / 2 - 6, width: 12, height: 12))
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
            .font: NSFont.titleBarFont(ofSize: NSFont.systemFontSize), .foregroundColor: t.text.ns(0.85)]))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: r.midX - CGFloat(w) / 2, y: r.maxY - titleBar / 2 - 4.5)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        ctx.setStrokeColor(t.isDark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(0.5)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerWidth: rc, cornerHeight: rc, transform: nil)); ctx.strokePath()
    }

    static func cgImage(_ img: RGBAImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func writePNG(_ cg: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
