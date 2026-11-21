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
// judged clean one time and flagged (or blurred) the next. A clean outcome counts towards the cache only when it
// was clearly clean (`CLEAN_CACHE_MARGIN`) for the cut-off that acts on the entry where it is reused: the cover
// cut-off everywhere, and the containment cut-off too where a blur can apply. A borderline-clean one is judged
// again, with new jitter, every time its pixels come back there, as before the cache. An outcome that covers
// is always kept: reusing it only ever covers.
//
// CLEAN CHECKS. One clearly clean judgement is not enough: jitter can give a borderline picture one lucky low
// score. Until `CLEAN_CHECKS` (3) clearly clean judgements in a row, an entry is only "waiting for clean checks", which
// is never reused: the next time the pixels come back they are judged again, with fresh jitter, as if they were not in
// the cache. A model failure starts the count again. Sticky (`CLEAN_STICKY`): a judgement at or over the margin, or a
// flag, marks the entry as never to be cached clean while it is held, so only a picture's first judgements can cache it.
// Where a blur can apply, all of them must also be clearly clean for the containment cut-off (`settledForBlur`).
import CryptoKit
import Foundation
import Preprocess

struct TileOutcome: Sendable, Equatable {
    var flagA: Bool, flagB: Bool, strikeBoth: Bool, clean: Bool, gridMember: Bool, gridLow: Bool, forced: Bool
    /// One family flagged, the other did not.
    var disputed = false
    /// The referee was asked (only for disputes) and confirmed.
    var refereeRan = false, refereeFlag = false
    /// Whether this judgement counts for the verdict cache, decided where it was judged (`Detector.judgeTask`):
    /// it covers, or every model's score was below `CLEAN_CACHE_MARGIN` (a quarter) of its cover cut-off (the margin rule). A flag, not a
    /// score. False unless set, so an outcome nobody marked is judged again.
    var cacheable = false
    /// Whether this judgement was also clearly clean where a blur can apply (a small picture in a hot window
    /// or a covered-start context): every model's score was also below that share of the entry's containment cut-off
    /// (`VerdictCache.cleanLevel`). An outcome that covers is settled. False unless set: where a blur can
    /// apply, an outcome nobody marked is judged again. On an outcome the cache hands back, it says whether
    /// `CLEAN_CHECKS` judgements in a row were settled.
    var settledForBlur = false
    /// The outcome covers under the rule it was judged by. A covering outcome is kept and reused at once.
    var covering = false
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

    /// The value for `k` without counting it as recent use.
    func peek(_ k: ExactKey) -> Value? { young[k] ?? old[k] }

    mutating func remove(_ k: ExactKey) { young[k] = nil; old[k] = nil }

    mutating func removeAll() { young = [:]; old = [:] }
}

final class VerdictCache {
    /// `CLEAN_CACHE_MARGIN`: a clean judgement counts towards the cache only when every model's highest score for the task was
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
    /// cut-off is judged afresh each time it comes back, and one under it is judged at least twice
    /// (`CLEAN_CHECKS`). Raising the share caches more and protects less.
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
    /// 128+: 19; NSFWJS 64-127: 10). With one clean judgement, such a picture could be cached as clean on its
    /// low score.
    ///
    /// The founder's answer (20 November 2026) is not a stricter share but a second look: a clean verdict is
    /// reused only after `CLEAN_CHECKS` judgements in a row, each with fresh jitter, were all under this share.
    /// The share stays 0.5. One lucky low score is no longer enough; two in a row still can be, so this narrows
    /// the gap rather than closing it. Re-measured (results/jitter-two-checks.json: half the screens, bands 32 px
    /// and up, 20 draws each): of 25 crossings, 10 had two draws in a row under half, so they could still be cached
    /// clean within 20 showings. The chance of a crossing being cached clean on its first showing(s) fell from 4.7
    /// to 1.5 in 25. (docs/STEP-1-STATUS.md, "Two clean checks".)
    ///
    /// The founder's decision of 20 November 2026, after the grid measurement (results/jitter-clean-margin.json, 40 draws
    /// an entry; docs/STEP-1-STATUS.md, "Narrowing the clean-cache gap"): the strictest rule measured that still caches,
    /// a quarter of the cut-off, with three checks and sticky (`CLEAN_CHECKS`, `CLEAN_STICKY`). Of 48 harmless crossings,
    /// 3 had any draw under a quarter, and the expected number cached clean falls from 14.8 (within 20 showings, under
    /// the old rule) to about 0.001 (for good). It costs
    /// about 2.1 times the judging on a reload and about a minute more for a still screen to settle. It does not close
    /// the gap for certain: the lowest draw of a crossing was 0.206 of its cut-off, and a picture whose first three
    /// judgements all land under a quarter is still cached clean.
    static let CLEAN_CACHE_MARGIN: Float = 0.25

    /// The lowest cut-off at which a model's score changes an entry's outcome: the cover cut-off, or the
    /// containment cut-off when a blur can apply to the entry (`containable`) and it is lower.
    static func actionCutoff(_ c: Cutoffs, containable: Bool) -> Float { containable ? min(c.cover, c.clean) : c.cover }

    /// The level a model's top score must be strictly below for a clean outcome to be cached (`margin`: this cache's
    /// `rule.margin`; by default `CLEAN_CACHE_MARGIN`).
    static func cleanLevel(_ c: Cutoffs, containable: Bool, margin: Float = CLEAN_CACHE_MARGIN) -> Float { margin * actionCutoff(c, containable: containable) }

    /// `CLEAN_CHECKS`: how many clearly clean judgements in a row, each with fresh jitter, a picture needs before
    /// its clean verdict is reused. Two was the founder's decision of 20 November 2026; three with `CLEAN_STICKY` is
    /// stricter (docs/STEP-1-STATUS.md, "Narrowing the clean-cache gap"). Until the last, an entry is "waiting for clean checks" and never reused; the
    /// next time the pixels come back they are judged again, and the looks at a still screen give it its checks in the
    /// background (`DisplayPipeline`, step 3c). Where a blur can apply, a reused clean verdict also needs that many in
    /// a row clearly clean for the containment cut-off (`settledForBlur`).
    static let CLEAN_CHECKS = 3

    /// `CLEAN_STICKY`: a judgement at or over the margin (borderline clean), or a cover, marks the entry as never to be
    /// cached clean while the cache holds it, instead of only starting its count again. So a picture is cached clean
    /// only if its first `CLEAN_CHECKS` judgements were all clearly clean; one that has ever been borderline is judged
    /// afresh, with fresh jitter, every time it comes back, and gets no more background checks. A model failure keeps
    /// the mark. Measured (results/jitter-clean-margin.json): of 48 harmless crossings, the expected number cached
    /// clean, at half the cut-off, falls from 14.8 (two checks, restarting, within 20 showings) to 0.87, for good; at a
    /// quarter (the default) to about 0.001.
    ///
    /// The marks are held in their own bounded set (`marks`), which a detector rule change does not empty. When the set
    /// drops a mark (oldest first), or the lab empties it (`removeEverything`), nothing at all is left for those pixels:
    /// they are judged again as if never seen, and need `CLEAN_CHECKS` fresh clearly clean judgements in a row, the
    /// first of them borderline marking them again. Losing a mark can only give a picture fresh first chances, never a
    /// clean verdict.
    static let CLEAN_STICKY = true

    /// The clean-cache rule a cache applies. Every build uses `standard` (`CLEAN_CACHE_MARGIN`, `CLEAN_CHECKS`,
    /// `CLEAN_STICKY`); only a lab build can set another, for measurement (`Detector.labSetCleanRule`), and only a stricter
    /// one: a margin no higher than `CLEAN_CACHE_MARGIN`, no fewer checks than `CLEAN_CHECKS`, and sticky if it is.
    ///
    /// `sticky`: see `CLEAN_STICKY`.
    struct CleanRule: Sendable, Equatable {
        var margin: Float
        var checks: Int
        var sticky: Bool
        static let standard = CleanRule(margin: CLEAN_CACHE_MARGIN, checks: CLEAN_CHECKS, sticky: CLEAN_STICKY)
        /// Whether this rule is at least as strict as `standard` (the only rules a lab build may set).
        var isAtLeastStandard: Bool {
            margin.isFinite && margin >= 0 && margin <= CLEAN_CACHE_MARGIN && checks >= CLEAN_CHECKS && checks <= 8 && (sticky || !CLEAN_STICKY)
        }
    }

    /// One kept entry: the latest outcome, and how many clearly clean judgements in a row it has had, for the
    /// cover cut-off (`cleanChecks`) and for the containment cut-off too (`blurChecks`). Counts, never scores.
    struct Kept {
        var outcome: TileOutcome
        var cleanChecks: UInt8
        var blurChecks: UInt8
    }

    /// The sticky marks (`CLEAN_STICKY`), kept apart from the counts and verdicts: a mark comes from a score against a
    /// cut-off, which neither detector rule (Balanced, Either) changes, so a rule change (`Detector.setRule`, which empties
    /// the cache) keeps them. Bits per key: `coverMark` (never cached clean), `blurMark` (never settled for a blur).
    /// Bounded like the cache (`Generations`, oldest first). Losing a mark, by eviction or by `removeEverything` (lab
    /// benches and lab rule changes only), only gives a picture fresh first chances: nothing is held for its pixels, so it
    /// needs `CLEAN_CHECKS` fresh clearly clean judgements in a row, and the first borderline one marks it again.
    static let coverMark: UInt8 = 1, blurMark: UInt8 = 2
    /// About 64 bytes a key with the dictionaries' spare room (a 32-byte key and a byte): 65,536 marks, about 4 MB at most.
    static let defaultMarkCapacity = 65_536
    private var marks: Generations<UInt8>
    let markCapacity: Int

    /// About 64 bytes an entry with the dictionaries' spare room: 65,536 entries stay under about 4 MB.
    static let bytesPerEntry = 64
    static let defaultCapacity = 65_536
    private var store: Generations<Kept>
    let capacity: Int
    private(set) var hits = 0, misses = 0
    /// The clean-cache rule in force: `CleanRule.standard` except in a lab measurement.
    private(set) var rule = CleanRule.standard
    init(capacity: Int = VerdictCache.defaultCapacity, markCapacity: Int = VerdictCache.defaultMarkCapacity) {
        self.capacity = capacity; store = Generations(capacity: capacity)
        self.markCapacity = markCapacity; marks = Generations(capacity: markCapacity)
    }

    #if KESTREL_LAB
    /// LAB ONLY: sets a stricter clean-cache rule (measurement) and empties the cache and its marks, since what they hold
    /// was counted under the other rule. Refuses (returns false, changes nothing) a rule looser than `standard`.
    @discardableResult
    func setRule(_ r: CleanRule) -> Bool {
        guard r.isAtLeastStandard else { return false }
        rule = r
        removeEverything()
        return true
    }
    #endif

    /// The most memory the cache can hold, roughly (its marks included).
    var maxBytes: Int { (capacity + markCapacity) * Self.bytesPerEntry }
    /// Entries held, whether reusable or waiting for clean checks; never more than `capacity`.
    var count: Int { store.count }
    /// Marks held; never more than `markCapacity`.
    var markCount: Int { marks.count }

    static func passCode(_ pass: String) -> UInt64 { pass == "region" ? 1 : pass == "whole" ? 2 : pass == "slice" ? 3 : 4 }

    static func key(_ img: RGBAImage, _ r: PixelRect, pass: String, version: String, memo: FrameKeys? = nil) -> ExactKey {
        let header = [passCode(pass), UInt64(r.w), UInt64(r.h)]
        if let memo { return memo.key(img, r, header: header, tag: version) }
        return ExactKey.of(img, r, header: header, tag: version)
    }

    private func mark(_ k: ExactKey) -> UInt8 { rule.sticky ? (marks.peek(k) ?? 0) : 0 }
    private func addMark(_ k: ExactKey, _ bits: UInt8) {
        guard rule.sticky else { return }
        marks.put(k, (marks.peek(k) ?? 0) | bits)   // set again, so a mark seen again counts as recent use
    }

    /// The outcome to reuse for `k`, or nil when it must be judged: a covering outcome, or a clean one judged
    /// clearly clean `CLEAN_CHECKS` times in a row and not marked. Its `settledForBlur` says whether that many in a row
    /// were also clearly clean for the containment cut-off. An entry still waiting for clean checks is never handed back.
    func get(_ k: ExactKey) -> TileOutcome? {
        if let e = store.get(k), let o = reusable(k, e) { hits += 1; return o }
        misses += 1
        return nil
    }

    private func reusable(_ k: ExactKey, _ e: Kept) -> TileOutcome? {
        if e.outcome.covering { return e.outcome }
        let m = mark(k)
        guard m & Self.coverMark == 0, Int(e.cleanChecks) >= rule.checks else { return nil }
        var o = e.outcome
        o.settledForBlur = m & Self.blurMark == 0 && Int(e.blurChecks) >= rule.checks
        return o
    }

    /// Whether `k` is waiting for clean checks: clearly clean so far, not yet `CLEAN_CHECKS` in a row, not marked (a
    /// marked picture is never queued for more checks). Not counted as a hit or a miss.
    func seenCleanOnce(_ k: ExactKey) -> Bool {
        guard let e = store.peek(k) else { return false }
        return !e.outcome.covering && mark(k) & Self.coverMark == 0 && Int(e.cleanChecks) < rule.checks
    }

    /// Whether `k` is marked as never to be cached clean (sticky rule). Not counted.
    func isStuck(_ k: ExactKey) -> Bool { mark(k) & Self.coverMark != 0 }

    /// Whether `k` would be handed back by `get` (a cover, or `CLEAN_CHECKS` clean judgements in a row). Not counted.
    func isReusable(_ k: ExactKey) -> Bool { store.peek(k).flatMap { reusable(k, $0) } != nil }

    /// The counts held for `k` (tests).
    func checks(_ k: ExactKey) -> (clean: Int, blur: Int)? { store.peek(k).map { (Int($0.cleanChecks), Int($0.blurChecks)) } }

    /// Empties the counts and verdicts (a detector rule change). The sticky marks stay.
    func removeAll() { store.removeAll() }

    /// Empties the counts, verdicts and marks: lab benches starting from scratch, and a lab rule change, only.
    func removeEverything() { store.removeAll(); marks.removeAll() }

    /// Records one judgement of `k`. A covering outcome is kept as it is (reusing it only covers). A clearly clean
    /// one (`cacheable`) adds one to the count of clean judgements in a row; `rule.checks` of them make it reusable.
    /// Anything else (borderline clean, a dispute the tie-breaker declined) forgets what was held. Under the sticky rule
    /// (the default) a cover or a borderline judgement also marks `k` as never to be cached clean, and a judgement not
    /// clearly clean for the containment cut-off marks it as never settled for a blur.
    func put(_ k: ExactKey, _ v: TileOutcome) {
        if v.covering {
            addMark(k, Self.coverMark | Self.blurMark)
            store.put(k, Kept(outcome: v, cleanChecks: 0, blurChecks: 0)); return
        }
        guard v.cacheable else { addMark(k, Self.coverMark | Self.blurMark); store.remove(k); return }
        if mark(k) & Self.coverMark != 0 { store.remove(k); return }
        if !v.settledForBlur { addMark(k, Self.blurMark) }
        let prev = store.peek(k).flatMap { $0.outcome.covering ? nil : $0 }
        let cap = UInt8(rule.checks)
        let clean = min(cap, (prev?.cleanChecks ?? 0) + 1)
        let blur = v.settledForBlur && mark(k) & Self.blurMark == 0 ? min(cap, (prev?.blurChecks ?? 0) + 1) : 0
        store.put(k, Kept(outcome: v, cleanChecks: clean, blurChecks: blur))
    }

    /// A model failed on `k`: a clean count held for it is forgotten, so it starts again; a mark stays. A covering
    /// outcome stays (it is reused without judging, so a failure never reaches it; keeping it only covers).
    func forget(_ k: ExactKey) {
        if let e = store.peek(k), !e.outcome.covering { store.remove(k) }
    }
}

/// Exact pixels last judged clear but kept out of the verdict cache by the margin rule (`Detector.seenClear`): the key
/// and when it was judged, nothing else (no outcome, no score). Bounded; the oldest go first when it is full.
final class SeenClear {
    struct Entry: Sendable { var serial: UInt64; var at: Date }
    static let capacity = 20_000
    private var store: [ExactKey: Entry] = [:]
    private var next: UInt64 = 0

    func get(_ k: ExactKey) -> Entry? { store[k] }

    func put(_ k: ExactKey, at: Date) {
        next += 1
        store[k] = Entry(serial: next, at: at)
        if store.count > Self.capacity {
            // Drop the older half: rare, and an entry dropped is only judged again sooner.
            let cut = store.values.map(\.serial).sorted()[store.count / 2]
            store = store.filter { $0.value.serial >= cut }
        }
    }

    func remove(_ k: ExactKey) { store[k] = nil }
    func removeAll() { store.removeAll() }
    var count: Int { store.count }
}
