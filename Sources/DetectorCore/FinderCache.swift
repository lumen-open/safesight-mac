// SPDX-License-Identifier: Apache-2.0
// An exact-match cache for the picture finder (SafeSight Mac). The finder is a fixed function of the pixels
// it reads, so when every one of those pixels is the same as before (a reload, a window moved over the same
// surroundings, a still screen judged again), its proposals are reused, moved to the area's new place.
// Nothing about what is judged changes: the cached proposals are exactly the ones the finder would make.
//
// What the finder reads: the area itself, gutter runs up to 64 pixels beyond it, and growth up to
// max(32, short side / 2) pixels beyond its marked cells (cells may reach 3 pixels past the area). The key
// therefore covers the area grown by `reach` (clamped to the frame), where that grown rectangle sits
// relative to the area, and every byte of its pixels (full SHA-256). If the frame's edge falls inside the
// reach, its position relative to the area is part of the key too.
import Foundation
import Preprocess
import RegionFinder

final class FinderCache {
    /// At most this many finder results are kept (a busy screen's result is a few hundred rectangles, a cover's a handful).
    /// A look at a still screen makes one judge call per window and one per cover waiting to lift, a few dozen on a busy
    /// desktop, all on the same pixels as the last look: the store must hold them all, or every look finds again what the
    /// last one found (with 32, the harness's desktop hit the cache in 2% of its calls while settling).
    static let defaultCapacity = 512
    private var store: Generations<(origin: PixelRect, output: RegionFinder.Output)>
    private(set) var hits = 0, misses = 0
    init(capacity: Int = FinderCache.defaultCapacity) { store = Generations(capacity: capacity) }

    /// How far beyond the area the finder can read.
    static func reach(_ a: PixelRect) -> Int { max(68, (a.shortSide + 3) / 2 + 4) }

    static func key(_ img: RGBAImage, _ a: PixelRect, memo: FrameKeys? = nil) -> ExactKey {
        let r = reach(a)
        let e = PixelRect(x: a.x - r, y: a.y - r, w: a.w + 2 * r, h: a.h + 2 * r).clamped(width: img.width, height: img.height) ?? a
        let header = [UInt64(a.x - e.x), UInt64(a.y - e.y), UInt64(e.maxX - a.maxX), UInt64(e.maxY - a.maxY), UInt64(a.w), UInt64(a.h)]
        if let memo { return memo.key(img, e, header: header, tag: "finder/1") }
        return ExactKey.of(img, e, header: header, tag: "finder/1")
    }

    func get(_ k: ExactKey, for a: PixelRect) -> RegionFinder.Output? {
        guard let hit = store.get(k) else { misses += 1; return nil }
        hits += 1
        let dx = a.x - hit.origin.x, dy = a.y - hit.origin.y
        if dx == 0 && dy == 0 { return hit.output }
        func mv(_ r: PixelRect) -> PixelRect { PixelRect(x: r.x + dx, y: r.y + dy, w: r.w, h: r.h) }
        var o = hit.output
        o.regions = o.regions.map { var r = $0; r.rect = mv(r.rect); return r }
        o.grids = o.grids.map { var g = $0; g.members = g.members.map(mv); g.bounds = mv(g.bounds); return g }
        return o
    }

    func put(_ k: ExactKey, _ a: PixelRect, _ o: RegionFinder.Output) { store.put(k, (a, o)) }
    func removeAll() { store.removeAll() }
}
