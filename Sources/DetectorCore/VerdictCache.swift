// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0; key, bound and
// eviction rewritten for SafeSight Mac.
//
// Verdict cache keyed by an exact hash of a tile's pixels, its pass, its size and the model bundle version,
// so a scrolled, reloaded or moved picture is not judged twice. It stores outcome flags, never scores.
//
// SECURITY RULE. A cached outcome, and above all a clean one, is reused only on an exact match: the key is
// the full SHA-256 over every byte of the tile's pixels (all four channels) and its size. Preprocessing is a
// fixed function of exactly those bytes (spec section 5; jitter is drawn fresh per judgement), so an exact
// pixel match is an exact match of the preprocessed input. No perceptual or approximate hash is ever used to
// reuse a verdict: a near-collision would let an explicit picture inherit a clean verdict. Collisions of
// SHA-256 are not known to be findable. Anything approximate may only ever add covering, never clear.
//
// MARGIN RULE. Jitter is drawn fresh for every judgement, so a picture that scores near a cut-off can be
// judged clean one time and flagged the next. A clean outcome is therefore kept only when it was clearly
// clean (`CLEAN_CACHE_MARGIN`); a borderline-clean one is judged again, with new jitter, every time its
// pixels come back, as before the cache. An outcome that covers is always kept: reusing it only ever covers.
import CryptoKit
import Foundation
import Preprocess

struct TileOutcome: Sendable, Equatable {
    var flagA: Bool, flagB: Bool, strikeBoth: Bool, clean: Bool, gridMember: Bool, gridLow: Bool, forced: Bool
    /// One family flagged, the other did not.
    var disputed = false
    /// The referee was asked (only for disputes) and confirmed.
    var refereeRan = false, refereeFlag = false
    /// Whether the verdict cache may keep this outcome, decided where it was judged (`Detector.judgeTask`):
    /// it covers, or every model's score was below `CLEAN_CACHE_MARGIN` of its cover cut-off. A flag, not a
    /// score. False unless set, so an outcome nobody marked is judged again.
    var cacheable = false
    /// The covering decision: both families agree, or a dispute the referee confirmed (or the lab stand-in).
    var confirmed: Bool { forced || (flagA && flagB) || (disputed && refereeFlag) }
}

/// The full 256-bit SHA-256 digest, held inline (no allocation per key).
struct ExactKey: Hashable, Sendable {
    let a: UInt64, b: UInt64, c: UInt64, d: UInt64

    init(_ digest: SHA256.Digest) { self.init(bytes: Array(digest)) }

    /// From the 32 bytes of a digest.
    init(bytes: [UInt8]) {
        precondition(bytes.count == 32)
        var w: [UInt64] = [0, 0, 0, 0]
        bytes.withUnsafeBytes { raw in
            for i in 0..<4 { w[i] = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) }
        }
        a = w[0]; b = w[1]; c = w[2]; d = w[3]
    }

    /// Hashes a header of fixed-width fields (so no two different headers can run together), then every
    /// byte of `r`'s rows.
    static func of(_ img: RGBAImage, _ r: PixelRect, header: [UInt64], tag: String) -> ExactKey {
        var h = SHA256()
        let t = Array(tag.utf8)
        let fields = [UInt64(t.count)] + header
        fields.withUnsafeBytes { h.update(bufferPointer: $0) }
        h.update(data: t)
        img.pixels.withUnsafeBytes { buf in
            for y in r.y..<r.maxY {
                let start = (y * img.width + r.x) * 4
                h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buf[start..<(start + r.w * 4)]))
            }
        }
        return ExactKey(h.finalize())
    }
}

/// A bounded store with two generations, close to least-recently-used: new entries and hits live in the
/// young generation; when it is full, the old generation is dropped and the young one becomes old. Every
/// operation is O(1) amortised, and the store never holds more than `capacity` entries.
struct Generations<Value> {
    private var young: [ExactKey: Value] = [:]
    private var old: [ExactKey: Value] = [:]
    let capacity: Int
    init(capacity: Int) { self.capacity = max(0, capacity) }

    var count: Int { young.count + old.count }

    mutating func get(_ k: ExactKey) -> Value? {
        if let v = young[k] { return v }
        guard let v = old.removeValue(forKey: k) else { return nil }
        put(k, v)   // a hit is recent use
        return v
    }

    mutating func put(_ k: ExactKey, _ v: Value) {
        guard capacity > 0 else { return }
        old[k] = nil
        young[k] = v
        if young.count >= max(1, capacity / 2) { old = young; young = [:] }
    }

    mutating func removeAll() { young = [:]; old = [:] }
}

final class VerdictCache {
    /// `CLEAN_CACHE_MARGIN`: a clean outcome is cached only when every model's highest score for the task was
    /// below this share of that model's cover cut-off for the task's size band (strictly below; a score that
    /// is not a number never counts as below). With the sealed table that means below 0.38 to 0.45 for Marqo
    /// and 0.47 to 0.50 for NSFWJS.
    ///
    /// Why: a cached clean verdict holds for as long as the pixels stay the same, so a picture that jitter
    /// once pushed just under a cut-off would never be judged again. Half the cut-off is a wide working
    /// margin, not a measured bound on how far jitter moves a score (that is not measured on this build):
    /// pictures the models score far below their cut-offs, as they score most harmless pictures, are still
    /// cached, and any picture within a factor of two of a cut-off is judged afresh each time it comes back.
    /// Raising it caches more and protects less. Its speed cost is in docs/STEP-1-STATUS.md.
    static let CLEAN_CACHE_MARGIN: Float = 0.5

    /// About 64 bytes an entry with the dictionaries' spare room: 65,536 entries stay under about 4 MB.
    static let bytesPerEntry = 64
    static let defaultCapacity = 65_536
    private var store: Generations<TileOutcome>
    let capacity: Int
    private(set) var hits = 0, misses = 0
    init(capacity: Int = VerdictCache.defaultCapacity) { self.capacity = capacity; store = Generations(capacity: capacity) }

    /// The most memory the cache can hold, roughly.
    var maxBytes: Int { capacity * Self.bytesPerEntry }
    var count: Int { store.count }

    static func passCode(_ pass: String) -> UInt64 { pass == "region" ? 1 : pass == "whole" ? 2 : pass == "slice" ? 3 : 4 }

    static func key(_ img: RGBAImage, _ r: PixelRect, pass: String, version: String) -> ExactKey {
        ExactKey.of(img, r, header: [passCode(pass), UInt64(r.w), UInt64(r.h)], tag: version)
    }

    func get(_ k: ExactKey) -> TileOutcome? {
        if let v = store.get(k) { hits += 1; return v }
        misses += 1
        return nil
    }

    func removeAll() { store.removeAll() }

    /// Keeps `v` only if it is marked cacheable (the margin rule); anything else is judged again next time.
    func put(_ k: ExactKey, _ v: TileOutcome) {
        guard v.cacheable else { return }
        store.put(k, v)
    }
}
