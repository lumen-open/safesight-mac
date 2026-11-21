// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Made cheaper for SafeSight Mac (docs/ENERGY.md) with the same output byte for byte: the vendored code is kept in
// the tests as the reference (FastPreprocessTests).
// kestrel-preprocess/1 (spec/preprocess.md), Swift implementation. Integer-exact.
import Accelerate
import Foundation

public enum PreprocessSpec {
    public static let version = "kestrel-preprocess/1"
}

public struct XorShift32: Sendable {
    public private(set) var state: UInt32
    public init(seed: UInt32) { state = seed == 0 ? 0x9E37_79B9 : seed }
    public mutating func next() -> UInt32 {
        var x = state
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        state = x
        return x
    }
}

/// An 8-bit RGBA image, straight alpha, row-major.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 1 && height >= 1 && pixels.count == width * height * 4)
        self.width = width; self.height = height; self.pixels = pixels
    }
    /// From a BGRA capture buffer (opaque premultiplied equals straight).
    /// A display capture's BGRA pixels as RGBA. A display has no see-through parts: alpha is always 255, so a capture
    /// whose alpha bytes are not opaque is never darkened by the alpha step before judging.
    ///
    /// It runs on the capture queue for every frame with new pixels, so it is done with Accelerate's vector routines
    /// (one channel swap, then alpha set to 255): byte for byte what `fromBGRAScalar` gives, several times faster. If
    /// Accelerate refuses the buffer, the plain loop does it.
    public static func fromBGRA(width: Int, height: Int, bytesPerRow: Int, base: UnsafePointer<UInt8>) -> RGBAImage {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let ok = px.withUnsafeMutableBytes { out -> Bool in
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: bytesPerRow)
            var dst = vImage_Buffer(data: out.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            // BGRA (bytes 0, 1, 2, 3) to RGBA: take bytes 2, 1, 0, 3.
            let map: [UInt8] = [2, 1, 0, 3]
            guard vImagePermuteChannels_ARGB8888(&src, &dst, map, vImage_Flags(kvImageDoNotTile)) == kvImageNoError else { return false }
            // The fourth byte of each pixel (mask bit 0x1, the last channel) set to 255.
            return vImageOverwriteChannelsWithScalar_ARGB8888(255, &dst, &dst, 0x1, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
        }
        if !ok { return fromBGRAScalar(width: width, height: height, bytesPerRow: bytesPerRow, base: base) }
        return RGBAImage(width: width, height: height, pixels: px)
    }

    /// The same conversion as `fromBGRA`, one pixel at a time: the reference the tests compare it with.
    public static func fromBGRAScalar(width: Int, height: Int, bytesPerRow: Int, base: UnsafePointer<UInt8>) -> RGBAImage {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        px.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base + y * bytesPerRow
                for x in 0..<width {
                    let s = row + x * 4, d = (y * width + x) * 4
                    out[d] = s[2]; out[d + 1] = s[1]; out[d + 2] = s[0]; out[d + 3] = 255
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: px)
    }
}

public struct PixelRect: Hashable, Sendable, Codable {
    public var x: Int, y: Int, w: Int, h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var shortSide: Int { min(w, h) }
    public var area: Int { w * h }
    public var maxX: Int { x + w }
    public var maxY: Int { y + h }
    public func intersects(_ o: PixelRect) -> Bool { x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY }
    public func intersection(_ o: PixelRect) -> PixelRect? {
        let nx = max(x, o.x), ny = max(y, o.y), mx = min(maxX, o.maxX), my = min(maxY, o.maxY)
        return mx > nx && my > ny ? PixelRect(x: nx, y: ny, w: mx - nx, h: my - ny) : nil
    }
    public func union(_ o: PixelRect) -> PixelRect {
        let nx = min(x, o.x), ny = min(y, o.y)
        return PixelRect(x: nx, y: ny, w: max(maxX, o.maxX) - nx, h: max(maxY, o.maxY) - ny)
    }
    public func clamped(width W: Int, height H: Int) -> PixelRect? {
        intersection(PixelRect(x: 0, y: 0, w: W, h: H))
    }
}

public enum PreprocessError: Error { case rectOutsideImage }

struct AxisTaps {
    let lo: [Int32]
    let k: [Int32]
    let taps: Int
}

@inline(never)
func axisWeights(_ S: Int, _ D: Int) -> AxisTaps {
    let scale = Double(S) / Double(D)
    let fscale = max(scale, 1.0)
    let support = fscale
    var los = [Int32](), rows = [[Int32]]()
    los.reserveCapacity(D); rows.reserveCapacity(D)
    var T = 0
    for i in 0..<D {
        let center = (Double(i) + 0.5) * scale
        let lo = max(0, Int((center - support + 0.5).rounded(.down)))
        let hi = min(S, Int((center + support + 0.5).rounded(.down)))
        var w = [Double]()
        if hi > lo {
            for j in lo..<hi {
                let t = (Double(j) - center + 0.5) / fscale
                w.append(max(0.0, 1.0 - abs(t)))
            }
        }
        var total = 0.0
        for v in w { total += v }
        rows.append(w.map { total != 0.0 ? Int32(($0 / total * 4194304 + 0.5).rounded(.down)) : 0 })
        los.append(Int32(lo))
        T = max(T, w.count)
    }
    var k = [Int32](repeating: 0, count: D * T)
    for (i, r) in rows.enumerated() { for (t, v) in r.enumerated() { k[i * T + t] = v } }
    return AxisTaps(lo: los, k: k, taps: T)
}

@inline(__always) private func clamp255(_ acc: Int64) -> UInt8 {
    let v = (acc + 2_097_152) >> 22
    return UInt8(truncatingIfNeeded: v < 0 ? 0 : (v > 255 ? 255 : v))
}

public enum Preprocessor {
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
                let plane = w * h
                for yy in 0..<h {
                    var p = ((r.y + yy) * W + r.x) * 4
                    let o = yy * w
                    for xx in 0..<w {
                        let a = Int(px[p + 3])
                        if a == 255 {
                            // Opaque (every display capture): (v * 255 + 127) / 255 is v.
                            s[o + xx] = px[p]; s[plane + o + xx] = px[p + 1]; s[2 * plane + o + xx] = px[p + 2]
                        } else {
                            for c in 0..<3 { s[c * plane + o + xx] = UInt8((Int(px[p + c]) * a + 127) / 255) }
                        }
                        p += 4
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
                        // The taps of each output column that fall inside the row (t with l + t < w): always the first ones.
                        let valid = (0..<N).map { i in max(0, min(T, w - Int(lo[i]))) }
                        // Every plane's rows are independent, so they are taken four at a time: four sums run side by side
                        // instead of one after the other (the same sums, exactly).
                        let rows = 3 * h
                        var yy = 0
                        while yy + 4 <= rows {
                            let r0 = yy * w, o0 = yy * N
                            for i in 0..<N {
                                var a0: Int64 = 0, a1: Int64 = 0, a2: Int64 = 0, a3: Int64 = 0
                                let l = Int(lo[i]), kb = i * T
                                for t in 0..<valid[i] {
                                    let kv = Int64(k[kb + t]), q = r0 + l + t
                                    a0 += kv * Int64(s[q]); a1 += kv * Int64(s[q + w]); a2 += kv * Int64(s[q + 2 * w]); a3 += kv * Int64(s[q + 3 * w])
                                }
                                m[o0 + i] = clamp255(a0); m[o0 + N + i] = clamp255(a1); m[o0 + 2 * N + i] = clamp255(a2); m[o0 + 3 * N + i] = clamp255(a3)
                            }
                            yy += 4
                        }
                        while yy < rows {
                            let row = yy * w, orow = yy * N
                            for i in 0..<N {
                                var acc: Int64 = 0
                                let l = row + Int(lo[i])
                                let kb = i * T
                                for t in 0..<valid[i] { acc += Int64(k[kb + t]) * Int64(s[l + t]) }
                                m[orow + i] = clamp255(acc)
                            }
                            yy += 1
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
                        // Row by row over a whole output row at once (the same integer sums, in another order: exact).
                        var acc = [Int64](repeating: 0, count: N)
                        acc.withUnsafeMutableBufferPointer { a in
                            for c in 0..<3 {
                                let plane = c * h * N
                                for i in 0..<N {
                                    let l = Int(lo[i])
                                    let kb = i * T
                                    let orow = c * N * N + i * N
                                    for xx in 0..<N { a[xx] = 0 }
                                    for t in 0..<max(0, min(T, h - l)) {
                                        let kv = Int64(k[kb + t])
                                        let src = plane + (l + t) * N
                                        for xx in 0..<N { a[xx] += kv * Int64(m[src + xx]) }
                                    }
                                    for xx in 0..<N { o[orow + xx] = clamp255(a[xx]) }
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

    public static func generateInput(kind: String, width W: Int, height H: Int, seed: UInt32) -> RGBAImage {
        var b = [UInt8](repeating: 0, count: W * H * 4)
        if kind == "noise" || kind == "noise-opaque" {
            var g = XorShift32(seed: seed)
            for i in 0..<b.count { b[i] = UInt8(truncatingIfNeeded: g.next() & 255) }
            if kind == "noise-opaque" { for i in stride(from: 3, to: b.count, by: 4) { b[i] = 255 } }
        } else {
            for y in 0..<H {
                for x in 0..<W {
                    let p = (y * W + x) * 4
                    if kind == "gradient" {
                        b[p] = UInt8(255 * x / max(W - 1, 1)); b[p + 1] = UInt8(255 * y / max(H - 1, 1))
                        b[p + 2] = UInt8((x * 7 + y * 13) & 255)
                    } else {
                        let on = ((x / 8) + (y / 8)) % 2 == 0
                        b[p] = on ? 250 : 5; b[p + 1] = b[p]; b[p + 2] = b[p]
                    }
                    b[p + 3] = 255
                }
            }
        }
        return RGBAImage(width: W, height: H, pixels: b)
    }
}
