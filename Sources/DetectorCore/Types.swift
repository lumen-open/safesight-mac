// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Public types. The detector's outputs are classes only; no score ever leaves this module.
import Foundation
import Preprocess

/// What the screen shows for a region.
public enum DisplayClass: String, Sendable, Codable, Comparable {
    case clear      // show sharp
    case contain    // soft blur until cleared
    case cover      // opaque cover
    static let order: [DisplayClass] = [.clear, .contain, .cover]
    public static func < (a: DisplayClass, b: DisplayClass) -> Bool { order.firstIndex(of: a)! < order.firstIndex(of: b)! }
}

/// Why a region got its class (for logs and tests; carries no score).
public enum Reason: String, Sendable, Codable {
    /// bothFamilies: the two families agreed. referee: one family flagged and the referee confirmed.
    /// disputed: one family flagged and no referee could settle it, so the picture is covered (SD-125).
    case judgedClean, bothFamilies, referee, disputed, containedSmall, hotContext, overload, cached, videoHold
    /// Exactly these pixels were judged clear before, too near a cut-off for the verdict cache to keep (the margin rule),
    /// and this call's budget did not reach them again. Shown as judged, never counted as a fresh judgement: the caller
    /// lifts no cover on it.
    case judgedEarlier
    /// As `judgedEarlier`, but that judgement is older than `DetectorConfig.rejudgeAfter`: shown as judged, and judged
    /// again first among entries judged before, whenever a call reaches it (a full re-judge, or a cover judged again).
    case rejudgeDue
    /// Only in `JudgeProgress.fastFlag`, never in a verdict: the fastest model flagged, the full rule has not
    /// decided yet.
    case provisional
    #if KESTREL_LAB
    case labForced
    #endif
}

/// Which of the three scales produced an entry (register 8a, verdict record).
public enum JudgePass: String, Sendable, Codable { case whole, slice, region }

/// The detector rule (register SD-125). Balanced: cover when both families agree, or when exactly one
/// flags and the tie-breaker confirms. Either: cover when either family flags; the tie-breaker is not asked.
public enum DetectorRule: String, Sendable, Codable, CaseIterable { case balanced, either }

public struct RegionVerdict: Sendable, Equatable {
    public var rect: PixelRect
    public var display: DisplayClass
    public var reason: Reason
    /// The scale that produced this entry.
    public var pass: JudgePass = .region
    /// The outcome was handed back by the verdict cache in this call, not judged by the models in it. Read only when a
    /// cover counts fresh judgements alone towards lifting (`DisplayPipeline.freshVotesOnly`, off by default).
    public var fromCache = false
}

public struct FrameVerdict: Sendable {
    /// Regions to cover or blur, and judged-clean regions.
    public var regions: [RegionVerdict]
    /// True when the whole window must be covered (whole pass flagged, or edges unclear).
    public var coverWindow: Bool
    /// True only when both model families flagged the same picture at strike strength (never for
    /// small pictures, group evidence or containment).
    public var strike: Bool
    /// The window became (or stays) a hot context.
    public var hot: Bool
    /// Model calls made and regions left for the cover-by-default path because the budget ran out (or because
    /// a model failed on them; those are judged again too).
    public var judgements: Int
    public var overloaded: Int
    /// Model failures in this call (a model threw or gave a score that is not usable). Never clear: an entry a
    /// family model failed on is in `overloaded`, and a dispute the tie-breaker failed on is unanswered, so it
    /// is covered. A count only.
    public var modelFaults = 0
    /// What the first entry the budget did not reach would have cost (model judgements), in the order this call judges,
    /// whether it was left unjudged or shown as judged earlier; 0 when the budget reached every entry it had to judge. A
    /// caller whose calls keep leaving such an entry can save its budget up for it.
    public var nextCost = 0
    /// Entries of this call seen clean once (`VerdictCache.CLEAN_CHECKS`), still waiting for their second clean
    /// check. A count only; the cover layer may give them that check in the background (`Detector.secondChecks`).
    public var secondChecksLeft = 0
}

/// Size bands in detail pixels (short side), as in the small-picture policy.
public enum Band: String, CaseIterable, Sendable, Codable {
    case under16 = "under16", b16 = "16-31", b32 = "32-63", b64 = "64-127", b128 = "128+"
    public init(shortSide s: Int) {
        self = s < 16 ? .under16 : s < 32 ? .b16 : s < 64 ? .b32 : s < 128 ? .b64 : .b128
    }
}

public enum DisplayTrust: String, Sendable, Codable { case trusted, untrusted, magnified }

/// A point the slice grid passes through, in frame pixels. The cover layer moves it with the content when
/// a window scrolls or moves, so slices over content seen before have exactly the same pixels and come from
/// the verdict cache. The grid still covers the whole area with the same slice size and overlap.
public struct SliceAnchor: Sendable, Equatable {
    public var x: Int, y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// Where the frame came from.
public struct JudgeContext: Sendable {
    public var windowID: UInt64
    /// Apps that start covered (unknown apps, Apple image surfaces, system surfaces, messaging...).
    public var startsCovered: Bool
    public var display: DisplayTrust
    public var isVideo: Bool
    public var now: Date
    /// Where the slice grid is anchored (nil: at the area's top-left corner, as the lab build did).
    public var sliceAnchor: SliceAnchor?
    /// Where the owner is looking (the pointer), in frame pixels: pictures nearest it are judged first.
    public var focus: PixelRect?
    /// Measurement switch (off by default): a clean outcome is never taken from the verdict cache in this call, so every
    /// clean entry is judged afresh, with fresh jitter. A cached covering outcome is still reused (it only covers). Set by
    /// the cover layer for a cover's own calls when `DisplayPipeline.freshVotesOnly` is on.
    public var freshClean = false
    public init(windowID: UInt64, startsCovered: Bool, display: DisplayTrust = .trusted, isVideo: Bool = false, now: Date = Date(),
                sliceAnchor: SliceAnchor? = nil, focus: PixelRect? = nil) {
        self.windowID = windowID; self.startsCovered = startsCovered; self.display = display; self.isVideo = isVideo; self.now = now
        self.sliceAnchor = sliceAnchor; self.focus = focus
    }
}

/// What a `judge` call tells its caller before it returns. Classes and rectangles only, never a score.
public enum JudgeProgress: Sendable {
    /// After the finder and the caches: the picture regions not decided yet (whether or not this call's budget
    /// reaches them), the picture regions the cache already says to cover, and about how long the judging
    /// left in this call will take.
    case found(pending: [PixelRect], coveredByCache: [PixelRect], estimatedMs: Double)
    /// The fastest model flagged this picture; the full rule has not decided yet. Its class is `contain`
    /// under Balanced and `cover` under Either, where that flag alone covers.
    case fastFlag(RegionVerdict)
}
