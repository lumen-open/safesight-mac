// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// LAB ONLY. A synthetic stand-in for an explicit picture: a textured magenta/green checker. It lets the
// pipeline be tested end to end (time to cover, grids, video, overload) without any explicit data.
// It can only FORCE A COVER: it never clears anything and never creates a strike. This target exists
// only when building with KESTREL_LAB=1; release builds contain neither it nor the hook that calls it.
import DetectorCore
import Foundation
import Preprocess

public final class CheckerStandIn: StandInDetector {
    public init() {}

    public func detects(_ img: RGBAImage, _ r: PixelRect) -> Bool {
        var m = 0, g = 0
        let n = r.w * r.h
        img.pixels.withUnsafeBufferPointer { px in
            for y in r.y..<r.maxY {
                for x in r.x..<r.maxX {
                    let p = (y * img.width + x) * 4
                    let R = px[p], G = px[p + 1], B = px[p + 2]
                    if R > 170 && G < 100 && B > 170 { m += 1 } else if G > 170 && R < 100 && B < 100 { g += 1 }
                }
            }
        }
        return m * 5 >= n && g * 5 >= n
    }

    /// Paints the pattern into a rectangle (4 px checker with noise so the picture finder sees it as a picture).
    public static func paint(_ img: inout RGBAImage, _ r: PixelRect, seed: UInt32 = 1) {
        var rng = XorShift32(seed: seed)
        for y in r.y..<r.maxY {
            for x in r.x..<r.maxX {
                let p = (y * img.width + x) * 4
                let magenta = (((x - r.x) / 4) + ((y - r.y) / 4)) % 2 == 0
                let n = Int(rng.next() % 50)
                img.pixels[p] = UInt8(magenta ? 200 + n : 20 + n)
                img.pixels[p + 1] = UInt8(magenta ? 20 + n : 200 + n)
                img.pixels[p + 2] = UInt8(magenta ? 200 + n : 20 + n)
                img.pixels[p + 3] = 255
            }
        }
    }
}
