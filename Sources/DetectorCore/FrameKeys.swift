// SPDX-License-Identifier: Apache-2.0
// The exact keys (`ExactKey`, full SHA-256) already worked out for the frames being judged. While covers wait to lift on
// a still screen, the watcher looks at the same last frame again and again (several looks a second, a few dozen judge
// calls each), and every call hashed the same pixels again for the finder cache and the verdict cache. Here each key is
// worked out once per frame and handed back for the same frame. A key is never shared between two frames: a frame is
// the same only when it is the very same pixel storage, which this memo keeps alive so it can be neither freed (and its
// address reused) nor changed in place (Swift arrays copy on write once shared). The keys, and so every cache decision,
// are exactly what hashing the pixels again would give.
//
// One frame per display (`slots`, the watcher's display limit): a new frame takes the place of the one of the same size,
// so the memo holds no frame its display's pipeline has let go of, beyond the one it is judging now.
import Foundation
import Preprocess

final class FrameKeys {
    struct Entry: Hashable { var rect: PixelRect; var header: [UInt64]; var tag: String }
    final class Slot {
        /// The frame's pixel storage, held so it stays alive and shared while its keys are kept.
        let pixels: [UInt8]
        let base: UnsafeRawPointer
        let width: Int, height: Int
        var keys: [Entry: ExactKey] = [:]
        var used = 0
        init(_ img: RGBAImage, base: UnsafeRawPointer) { pixels = img.pixels; self.base = base; width = img.width; height = img.height }
    }
    private var slots: [Slot] = []
    static let slotCount = 2
    /// At most this many keys for one frame (a busy display's whole look holds a few thousand).
    static let capacity = 50_000
    private var clock = 0
    private(set) var hits = 0, misses = 0

    /// `ExactKey.of(img, r, header:, tag:)`, from the memo when this very frame's key was worked out before.
    func key(_ img: RGBAImage, _ r: PixelRect, header: [UInt64], tag: String) -> ExactKey {
        guard let slot = slot(img) else { misses += 1; return ExactKey.of(img, r, header: header, tag: tag) }
        clock += 1; slot.used = clock
        let e = Entry(rect: r, header: header, tag: tag)
        if let k = slot.keys[e] { hits += 1; return k }
        misses += 1
        let k = ExactKey.of(img, r, header: header, tag: tag)
        if slot.keys.count >= Self.capacity { slot.keys = [:] }
        slot.keys[e] = k
        return k
    }

    private func slot(_ img: RGBAImage) -> Slot? {
        guard let b = img.pixels.withUnsafeBytes({ $0.baseAddress.map(UnsafeRawPointer.init) }) else { return nil }
        if let s = slots.first(where: { $0.base == b && $0.width == img.width && $0.height == img.height && $0.pixels.count == img.pixels.count }) {
            return s
        }
        // Another frame: it takes the place of the last frame of its size (its display's), else of the one used longest ago.
        let s = Slot(img, base: b)
        if let i = slots.firstIndex(where: { $0.width == img.width && $0.height == img.height }) {
            slots[i] = s
        } else if slots.count < Self.slotCount {
            slots.append(s)
        } else if let i = slots.indices.min(by: { slots[$0].used < slots[$1].used }) {
            slots[i] = s
        }
        return s
    }

    /// Lets go of every frame and its keys.
    func removeAll() { slots = [] }
}
