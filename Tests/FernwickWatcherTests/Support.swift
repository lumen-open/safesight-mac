// SPDX-License-Identifier: Apache-2.0
// Test support: fake models that "flag" synthetic marker colours (red for family A, blue for family B),
// so the real detector and the real cover layer can be driven end to end with harmless patterns only.
import CoreGraphics
import Foundation
@testable import DetectorCore
@testable import FernwickWatcher
@testable import Preprocess
@testable import RegionFinder

final class MarkerModel: ScoringModel {
    let id: String, family: Family, side = 32
    let channel: Int
    init(id: String, family: Family, channel: Int) { self.id = id; self.family = family; self.channel = channel }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] {
        let n = side * side
        return tensors.map { t in
            var hit = 0
            for i in 0..<n {
                let c = [Int(t[i]), Int(t[n + i]), Int(t[2 * n + i])]
                if c[channel] > 170 && (0..<3).filter({ $0 != channel }).allSatisfy({ c[$0] < 90 }) { hit += 1 }
            }
            return Float(hit) / Float(n)
        }
    }
}

enum Fixtures {
    static func detector(rule: DetectorRule = .balanced) -> Detector {
        let a = MarkerModel(id: "fa", family: .a, channel: 0), b = MarkerModel(id: "fb", family: .b, channel: 2)
        let c = Cutoffs(cover: 0.3, clean: 0.05, strike: 0.8, gridMember: 0.3, gridLow: 0.3)
        let table = ThresholdTable(schema: "test", models: ["fa": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) }),
                                                            "fb": Dictionary(uniqueKeysWithValues: Band.allCases.map { ($0.rawValue, c) })])
        var cfg = DetectorConfig(); cfg.rule = rule
        return Detector(models: ModelSet(models: [a, b], bundleVersion: "test"), table: table, config: cfg, finder: RegionFinder())
    }

    static func blank(_ w: Int, _ h: Int) -> RGBAImage {
        RGBAImage(width: w, height: h, pixels: (0..<(w * h * 4)).map { $0 % 4 == 3 ? 255 : 240 })
    }

    /// A textured patch. `channel` 0 = red marker, 2 = blue marker, nil = neutral photo-like texture.
    static func paint(_ img: inout RGBAImage, _ r: PixelRect, channel: Int?, seed: UInt32) {
        var g = XorShift32(seed: seed)
        for y in r.y..<r.maxY { for x in r.x..<r.maxX {
            let p = (y * img.width + x) * 4
            for c in 0..<3 {
                let n = Int(g.next() % 60)
                img.pixels[p + c] = UInt8(channel == nil ? 70 + n * 2 : (c == channel ? 195 + n : n))
            }
        } }
    }

    /// A picture both families flag: red left half, blue right half.
    static func paintFlagged(_ img: inout RGBAImage, _ r: PixelRect, seed: UInt32 = 1) {
        paint(&img, PixelRect(x: r.x, y: r.y, w: r.w / 2, h: r.h), channel: 0, seed: seed)
        paint(&img, PixelRect(x: r.x + r.w / 2, y: r.y, w: r.w - r.w / 2, h: r.h), channel: 2, seed: seed + 1)
    }

    static func frame(_ img: RGBAImage, display: DisplayDescriptor, scale: CGFloat, dirty: [PixelRect]? = nil,
                      status: FrameStatus = .complete, t: TimeInterval) -> CapturedFrame {
        let map = CaptureMap(displayBounds: display.bounds, contentRect: CGRect(origin: .zero, size: display.bounds.size),
                             contentScale: 1, scaleFactor: scale, pixelWidth: img.width, pixelHeight: img.height)
        return CapturedFrame(display: display, status: status, image: img, map: map, dirty: dirty, time: t)
    }

    static func oneWindow(_ bounds: CGRect, number: UInt32 = 10, pid: Int32 = 500) -> WindowSnapshot {
        WindowSnapshot(windows: [WindowInfo(number: number, ownerPID: pid, layer: 0, bounds: bounds)], time: 0)
    }
}

extension CoverPlan {
    func covers(_ g: CGRect, kind: CoverKind? = nil) -> Bool {
        if wholeDisplay != nil { return display.bounds.contains(g) }
        // The union of matching items contains g (checked on a 1-point grid inside g).
        let its = items.filter { kind == nil || $0.kind == kind! || (kind! != .plain && $0.kind != .plain) }
        var y = g.minY + 0.5
        while y < g.maxY {
            var x = g.minX + 0.5
            while x < g.maxX {
                if !its.contains(where: { $0.rect.contains(CGPoint(x: x, y: y)) }) { return false }
                x += 1
            }
            y += 1
        }
        return true
    }
}
