// SPDX-License-Identifier: Apache-2.0
// Preprocessing was made cheaper for energy (docs/ENERGY.md): it runs once per model for every judgement. Its output is
// what the models see, so it must be byte for byte what it was. These tests compare it with the vendored original
// (`ReferencePreprocessor`, copied below unchanged) on random frames, rectangles, sides, jitter and see-through pixels,
// besides the spec's own vectors (`VectorTests`). Synthetic patterns only.
import Foundation
import XCTest
@testable import Preprocess

final class FastPreprocessTests: XCTestCase {
    func testTheTensorIsByteForByteTheOriginal() throws {
        var g = XorShift32(seed: 404)
        var compared = 0
        for round in 0..<40 {
            let w = 8 + Int(g.next() % 400), h = 8 + Int(g.next() % 300)
            let seeThrough = round % 4 == 0
            var px = [UInt8](repeating: 0, count: w * h * 4)
            for i in px.indices { px[i] = i % 4 == 3 ? (seeThrough ? UInt8(truncatingIfNeeded: g.next()) : 255) : UInt8(truncatingIfNeeded: g.next()) }
            let img = RGBAImage(width: w, height: h, pixels: px)
            for _ in 0..<3 {
                let rw = 1 + Int(g.next() % UInt32(w)), rh = 1 + Int(g.next() % UInt32(h))
                let r = PixelRect(x: Int(g.next() % UInt32(w - rw + 1)), y: Int(g.next() % UInt32(h - rh + 1)), w: rw, h: rh)
                let side = [32, 224, 256, 384, 480][Int(g.next() % 5)]
                let seed: UInt32? = g.next() % 3 == 0 ? nil : g.next() | 1
                XCTAssertEqual(try Preprocessor.run(img, rect: r, side: side, jitterSeed: seed),
                               try ReferencePreprocessor.run(img, rect: r, side: side, jitterSeed: seed),
                               "round \(round): \(r) in \(w)x\(h) to \(side), seed \(String(describing: seed))")
                compared += 1
            }
        }
        XCTAssertEqual(compared, 120)
    }

    func testARectOutsideTheFrameIsStillRefused() {
        let img = RGBAImage(width: 10, height: 10, pixels: [UInt8](repeating: 255, count: 400))
        XCTAssertThrowsError(try Preprocessor.run(img, rect: PixelRect(x: 5, y: 5, w: 6, h: 2), side: 32, jitterSeed: nil))
    }
}

@inline(__always) private func clamp255(_ acc: Int64) -> UInt8 {
    let v = (acc + 2_097_152) >> 22
    return UInt8(truncatingIfNeeded: v < 0 ? 0 : (v > 255 ? 255 : v))
}

/// `Preprocessor.run` exactly as vendored (v3-detector, commit 49ecdd9), for comparison only.
enum ReferencePreprocessor {
    /// Returns the uint8 tensor [3][N][N], channel-major.
    public static func run(_ img: RGBAImage, rect: PixelRect, side N: Int, jitterSeed: UInt32?) throws -> [UInt8] {
        var r = rect
        guard r.w >= 1, r.h >= 1, r.x >= 0, r.maxX <= img.width, r.y >= 0, r.maxY <= img.height else {
            throw PreprocessError.rectOutsideImage
        }
        var rng: XorShift32? = nil
        if let s = jitterSeed {
            var g = XorShift32(seed: s)
            let m = UInt32((min(r.w, r.h) * 3) / 100)
            if m > 0 {
                let dx0 = Int(g.next() % (m + 1)), dy0 = Int(g.next() % (m + 1))
                let dx1 = Int(g.next() % (m + 1)), dy1 = Int(g.next() % (m + 1))
                r = PixelRect(x: r.x + dx0, y: r.y + dy0, w: r.w - dx0 - dx1, h: r.h - dy0 - dy1)
            }
            rng = g
        }
        let w = r.w, h = r.h, W = img.width
        var src = [UInt8](repeating: 0, count: 3 * w * h)
        img.pixels.withUnsafeBufferPointer { px in
            src.withUnsafeMutableBufferPointer { s in
                for yy in 0..<h {
                    for xx in 0..<w {
                        let p = ((r.y + yy) * W + r.x + xx) * 4
                        let a = Int(px[p + 3])
                        for c in 0..<3 { s[c * w * h + yy * w + xx] = UInt8((Int(px[p + c]) * a + 127) / 255) }
                    }
                }
            }
        }
        let hw = axisWeights(w, N)
        var mid = [UInt8](repeating: 0, count: 3 * h * N)
        src.withUnsafeBufferPointer { s in
            mid.withUnsafeMutableBufferPointer { m in
                hw.lo.withUnsafeBufferPointer { lo in
                    hw.k.withUnsafeBufferPointer { k in
                        let T = hw.taps
                        for c in 0..<3 {
                            for yy in 0..<h {
                                let row = c * w * h + yy * w
                                let orow = c * h * N + yy * N
                                for i in 0..<N {
                                    var acc: Int64 = 0
                                    let l = Int(lo[i])
                                    let kb = i * T
                                    for t in 0..<T where l + t < w { acc += Int64(k[kb + t]) * Int64(s[row + l + t]) }
                                    m[orow + i] = clamp255(acc)
                                }
                            }
                        }
                    }
                }
            }
        }
        let vw = axisWeights(h, N)
        var out = [UInt8](repeating: 0, count: 3 * N * N)
        mid.withUnsafeBufferPointer { m in
            out.withUnsafeMutableBufferPointer { o in
                vw.lo.withUnsafeBufferPointer { lo in
                    vw.k.withUnsafeBufferPointer { k in
                        let T = vw.taps
                        for c in 0..<3 {
                            let plane = c * h * N
                            for i in 0..<N {
                                let l = Int(lo[i])
                                let kb = i * T
                                let orow = c * N * N + i * N
                                for xx in 0..<N {
                                    var acc: Int64 = 0
                                    for t in 0..<T where l + t < h { acc += Int64(k[kb + t]) * Int64(m[plane + (l + t) * N + xx]) }
                                    o[orow + xx] = clamp255(acc)
                                }
                            }
                        }
                    }
                }
            }
        }
        if var g = rng {
            for i in 0..<out.count {
                let v = Int(out[i]) + Int(g.next() % 3) - 1
                out[i] = UInt8(v < 0 ? 0 : (v > 255 ? 255 : v))
            }
        }
        return out
    }
}
