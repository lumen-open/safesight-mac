// SPDX-License-Identifier: Apache-2.0
// Content that moved by a translation between two frames (scrolling), found from the frames' own pixels.
// It lets covers move with the pictures they cover in the same update, before the moved area is judged
// again. A cover is moved only when the pixels at its new place are exactly the pixels it covered; when
// that cannot be shown, the new place is covered as well as the old one. Nothing here clears anything.
import Foundation
import Preprocess

/// Content at (x, y) in the old frame is at (x + dx, y + dy) in the new one, in frame pixels.
public struct Translation: Equatable, Hashable, Sendable {
    public var dx: Int, dy: Int
    public init(dx: Int, dy: Int) { self.dx = dx; self.dy = dy }
    public var isZero: Bool { dx == 0 && dy == 0 }
}

public enum MotionFinder {
    /// Lines (rows or columns) of one colour say nothing about motion and are skipped. A translation needs at
    /// least this many matching lines that say something...
    static let minLines = 8
    /// ...and at least this share of the area's informative lines.
    static let minShare = 0.3

    /// Finds a vertical, else a horizontal, translation of the content of `area` from `old` to `new`.
    /// Returns nil when nothing moved, when the frames differ in size, or when no translation is clear.
    public static func find(old: RGBAImage, new: RGBAImage, area: PixelRect) -> Translation? {
        guard let a = area.clamped(width: new.width, height: new.height) else { return nil }
        return find(old: old, new: new, area: a, oldRows: lines(old, a, rows: true), newRows: lines(new, a, rows: true))
    }

    /// The same, with row hashes already made (the cover layer keeps the last frame's, so each frame's rows
    /// are hashed once). Columns are tried only when the rows show that something changed but no row moved.
    public static func find(old: RGBAImage, new: RGBAImage, area a: PixelRect, oldRows: [UInt64?], newRows: [UInt64?]) -> Translation? {
        guard old.width == new.width, old.height == new.height, a.w >= 16, a.h >= 16,
              oldRows.count == a.h, newRows.count == a.h else { return nil }
        switch shiftOrStill(oldRows, newRows) {
        case let .shift(dy): return Translation(dx: 0, dy: dy)
        case .still: return nil
        case .unclear:
            if let dx = shift(lines(old, a, rows: false), lines(new, a, rows: false)) { return Translation(dx: dx, dy: 0) }
            return nil
        }
    }

    public static func rowLines(_ img: RGBAImage, _ a: PixelRect) -> [UInt64?] { lines(img, a, rows: true) }

    /// A 64-bit hash of every line of `a` (rows, or columns sampled on every other row), nil for a line of
    /// one colour. Only used to find a candidate; covers move only after an exact comparison.
    static func lines(_ img: RGBAImage, _ a: PixelRect, rows: Bool) -> [UInt64?] {
        img.pixels.withUnsafeBufferPointer { px in
            px.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: img.width * img.height) { p32 in
                let W = img.width
                if rows {
                    return (a.y..<a.maxY).map { y -> UInt64? in
                        let row = p32 + y * W + a.x
                        let first = row[0]
                        let pair = UInt64(first) | (UInt64(first) << 32)
                        var h: UInt64 = 0xcbf2_9ce4_8422_2325, same = true
                        // Two pixels at a time.
                        let n = a.w / 2
                        UnsafeRawPointer(row).withMemoryRebound(to: UInt8.self, capacity: a.w * 4) { bytes in
                            for i in 0..<n {
                                let v = UnsafeRawPointer(bytes).loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                                same = same && v == pair
                                h = (h ^ v) &* 0x0000_0100_0000_01b3
                                h ^= h >> 29
                            }
                        }
                        if a.w % 2 == 1 {
                            let v = row[a.w - 1]
                            same = same && v == first
                            h = (h ^ UInt64(v)) &* 0x0000_0100_0000_01b3
                        }
                        return same ? nil : h
                    }
                }
                return (a.x..<a.maxX).map { x -> UInt64? in
                    let first = p32[a.y * W + x]
                    var h: UInt64 = 0xcbf2_9ce4_8422_2325, same = true
                    var y = a.y
                    while y < a.maxY {
                        let v = p32[y * W + x]
                        same = same && v == first
                        h = (h ^ UInt64(v)) &* 0x0000_0100_0000_01b3
                        h ^= h >> 29
                        y += 2
                    }
                    return same ? nil : h
                }
            }
        }
    }

    enum Outcome: Equatable { case shift(Int), still, unclear }

    /// A clear shift; or "still" when most informative lines did not move (nothing scrolled); or unclear.
    static func shiftOrStill(_ old: [UInt64?], _ new: [UInt64?]) -> Outcome {
        if let d = shift(old, new) { return .shift(d) }
        var informative = 0, still = 0
        for (i, h) in new.enumerated() { if let h { informative += 1; if old[i] == h { still += 1 } } }
        return informative > 0 && still * 2 >= informative ? .still : .unclear
    }

    /// The shift d such that new line i shows old line i - d, if one is clearly supported and beats "no shift".
    static func shift(_ old: [UInt64?], _ new: [UInt64?]) -> Int? {
        var at: [UInt64: [Int]] = [:]
        for (i, h) in old.enumerated() { if let h { at[h, default: []].append(i) } }
        var votes: [Int: Int] = [:]
        var informative = 0, still = 0
        for (i, h) in new.enumerated() {
            guard let h else { continue }
            informative += 1
            if old[i] == h { still += 1 }
            guard let js = at[h], js.count <= 4 else { continue }   // a line repeated many times is ambiguous
            for j in js where j != i { votes[i - j, default: 0] += 1 }
        }
        guard let best = votes.max(by: { ($0.value, -abs($0.key)) < ($1.value, -abs($1.key)) }) else { return nil }
        let need = max(minLines, Int((Double(informative) * minShare).rounded(.up)))
        return best.value >= need && best.value > still ? best.key : nil
    }

    /// True when every pixel of `r` (new frame) equals the pixel `t` before it in the old frame.
    public static func matches(old: RGBAImage, new: RGBAImage, r: PixelRect, t: Translation) -> Bool {
        let src = PixelRect(x: r.x - t.dx, y: r.y - t.dy, w: r.w, h: r.h)
        guard r.w > 0, r.h > 0, old.width == new.width, old.height == new.height,
              r.clamped(width: new.width, height: new.height) == r, src.clamped(width: old.width, height: old.height) == src else { return false }
        return old.pixels.withUnsafeBufferPointer { o in
            new.pixels.withUnsafeBufferPointer { n in
                for y in 0..<r.h {
                    let a = ((src.y + y) * old.width + src.x) * 4, b = ((r.y + y) * new.width + r.x) * 4
                    if memcmp(o.baseAddress! + a, n.baseAddress! + b, r.w * 4) != 0 { return false }
                }
                return true
            }
        }
    }
}
