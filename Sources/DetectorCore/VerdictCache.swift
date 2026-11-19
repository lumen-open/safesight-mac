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
// judged clean one time and flagged (or blurred) the next. A clean outcome is therefore kept only when it was
// clearly clean (`CLEAN_CACHE_MARGIN`) for the cut-off that acts on the entry where it is reused: the cover
// cut-off everywhere, and the containment cut-off too where a blur can apply. A borderline-clean one is judged
// again, with new jitter, every time its pixels come back there, as before the cache. An outcome that covers
// is always kept: reusing it only ever covers.
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
    /// it covers, or every model's score was below half its cover cut-off (the margin rule). A flag, not a
    /// score. False unless set, so an outcome nobody marked is judged again.
    var cacheable = false
    /// Whether a kept clean outcome may also be reused where a blur can apply (a small picture in a hot window
    /// or a covered-start context): every model's score was also below half the entry's containment cut-off
    /// (`VerdictCache.cleanLevel`). An outcome that covers is settled. False unless set: where a blur can
    /// apply, an outcome nobody marked is judged again.
    var settledForBlur = false
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
    /// `CLEAN_CACHE_MARGIN`: a clean outcome is reused only when every model's highest score for the task was
    /// below this share of that model's cut-off for the action that can apply where it is reused, for the
    /// task's size band (strictly below). An unusable score never gets here: it is a model failure
    /// (`Detector.usable`).
    ///
    /// - Everywhere, the cover cut-off: the outcome is kept (`cacheable`). With the sealed table, below 0.38 to
    ///   0.45 for Marqo and 0.47 to 0.50 for NSFWJS.
    /// - Where a blur can apply, also the containment cut-off (`clean`) where that is lower (`actionCutoff`): a
    ///   picture region under `max(containBelow, hotBelow)` detail pixels (64 and 128) in a hot window, or under
    ///   `containBelow` in a covered-start context, is blurred when any model scores it above `clean`, and the
    ///   reused outcome's `clean` flag decides that blur (`settledForBlur`). With the sealed table, below 0.14
    ///   (10-31 px), 0.23 (32-63) and 0.23 (64-127) for Marqo, and 0.42, 0.46 and 0.43 for NSFWJS. A kept outcome
    ///   not settled for a blur is judged again there; in a call where the window turns hot, it is blurred.
    ///   (Held to that cut-off everywhere, small harmless photos were judged again on every reload of a busy
    ///   page, in windows where no blur could apply: 485 entries against 133, past the call cap.)
    ///
    /// Why: a cached clean verdict holds for as long as the pixels stay the same, so a picture that jitter
    /// once pushed just under a cut-off would never be judged again: any picture that scores at least half a
    /// cut-off is judged afresh each time it comes back. Raising the share caches more and protects less.
    ///
    /// Derivation (19 November 2026; `safesightmac-harness jitter`, results/jitter-spread.json). Half was a
    /// working guess; how far jitter moves each real model's score is now measured. On the lab's 932 held-out
    /// harmless screens, with the sealed models and cut-offs, every entry of each screen's first call (108,738)
    /// was judged once; 18,195 of them were then judged 20 more times each, with fresh jitter every time (per
    /// model and band up to 2,000 that came within 0.35 of their lowest action cut-off, and 500 at random).
    /// Spread: the 99.9th percentile, over the borderline entries (highest score at least half the entry's lowest
    /// action cut-off; only their caching can change with the share), of an entry's highest minus lowest
    /// score. The level would be the action cut-off less a gap of twice the spread, but never below half the
    /// cut-off (never more protection than before). A level under zero means no score is safely cached:
    ///
    ///     model   band      borderline  spread  gap    action cut-off     half   cut-off less gap
    ///     Marqo   10-15 px     3,549    0.077   0.155  containment 0.278  0.139   0.123
    ///     Marqo   16-31        2,663    0.084   0.167  containment 0.278  0.139   0.110
    ///     Marqo   32-63        1,416    0.432   0.864  containment 0.461  0.231  -0.403
    ///     Marqo   64-127       1,555    0.616   1.231  containment 0.452  0.226  -0.779
    ///     Marqo   128+           372    0.731   1.461  cover       0.758  0.379  -0.703
    ///     NSFWJS  10-15        2,340    0.469   0.938  containment 0.831  0.416  -0.106
    ///     NSFWJS  16-31        2,132    0.514   1.028  containment 0.831  0.416  -0.197
    ///     NSFWJS  32-63        2,323    0.650   1.299  containment 0.926  0.463  -0.373
    ///     NSFWJS  64-127       3,114    0.714   1.427  containment 0.857  0.429  -0.570
    ///     NSFWJS  128+           798    0.817   1.634  cover       0.934  0.467  -0.700
    ///
    /// In every model and band the gap is wider than half the cut-off, so the measurement says half is needed
    /// everywhere, and half is kept: one share, 0.5, for every model and band. (Where no blur can apply, only
    /// the cover cut-off acts on small pictures, and Marqo's gap under 32 px is under half of it; but that
    /// spread was measured near the containment cut-off, not near the cover one, so nothing is loosened.)
    /// By twice the spread even half is short, and in 20 draws it was crossed: 63 harmless borderline entries
    /// had one score under half the action cut-off and another at or over it (Marqo 32-63: 8, 64-127: 26,
    /// 128+: 19; NSFWJS 64-127: 10). Such a picture can still be cached as clean on its low score. Closing
    /// that needs a stricter rule than half, which is the owner's call (docs/STEP-1-STATUS.md, "How far jitter
    /// moves real scores").
    static let CLEAN_CACHE_MARGIN: Float = 0.5

    /// The lowest cut-off at which a model's score changes an entry's outcome: the cover cut-off, or the
    /// containment cut-off when a blur can apply to the entry (`containable`) and it is lower.
    static func actionCutoff(_ c: Cutoffs, containable: Bool) -> Float { containable ? min(c.cover, c.clean) : c.cover }

    /// The level a model's top score must be strictly below for a clean outcome to be cached.
    static func cleanLevel(_ c: Cutoffs, containable: Bool) -> Float { CLEAN_CACHE_MARGIN * actionCutoff(c, containable: containable) }

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
