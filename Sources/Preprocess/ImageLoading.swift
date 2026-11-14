// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
import CoreGraphics
import Foundation
import ImageIO

public enum ImageLoading {
    /// Decodes any ImageIO image to straight-alpha RGBA8, applying no colour management beyond sRGB drawing.
    public static func load(_ url: URL) -> RGBAImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return fromCGImage(cg)
    }

    public static func fromCGImage(_ cg: CGImage) -> RGBAImage? {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // Un-premultiply so the spec's alpha step sees straight alpha.
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i + 3])
            if a != 0 && a != 255 { for c in 0..<3 { px[i + c] = UInt8(min(255, (Int(px[i + c]) * 255 + a / 2) / a)) } }
        }
        return RGBAImage(width: w, height: h, pixels: px)
    }
}
