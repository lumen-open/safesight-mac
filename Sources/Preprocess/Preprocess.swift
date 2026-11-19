// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// kestrel-preprocess/1 (spec/preprocess.md), Swift implementation. Integer-exact.
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
    public static func fromBGRA(width: Int, height: Int, bytesPerRow: Int, base: UnsafePointer<UInt8>) -> RGBAImage {
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
