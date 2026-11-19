// SPDX-License-Identifier: Apache-2.0
// Writes a frame with its covers drawn on it as a PNG. The covers are the cover layer's own layers
// (CoverDrawing), rendered into the frame offscreen: what the PNG shows is what the canvas draws, way-out
// lines included. Nothing is captured from the screen and no window is shown.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Preprocess
import QuartzCore
import SafeSightMacCover
import SafeSightMacWatcher
import UniformTypeIdentifiers

enum Composite {
    /// The frame (or black, for a frame with no pixels) with the plan's covers over it, at `scale`.
    /// `above` draws on top, in display points (y up): the repair card in the way-out scenes.
    static func render(_ img: RGBAImage?, _ plan: CoverPlan, scale: CGFloat, theme: CoverTheme,
                       above: ((CGContext) -> Void)? = nil) -> CGImage? {
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
        root.sublayers = CoverDrawing.layers(for: plan, theme: theme, scale: scale)
        root.render(in: ctx)
        above?(ctx)
        return ctx.makeImage()
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
